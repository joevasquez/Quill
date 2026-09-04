//
//  NotesStore.swift
//  Quill (iOS)
//
//  Simple JSON-backed note persistence in the app's Documents directory.
//  Holds the full note list in memory and serializes to disk on every
//  mutation. A "flat list of notes" is small enough that this is fine —
//  no need for SwiftData overhead.
//
//  Also tracks the "active" note ID in UserDefaults. Every recording
//  appends to whichever note is active. If no active note exists, a
//  new one is created on demand.
//

import Combine
import Foundation
import HexCore
import SwiftUI
import UIKit
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Stable per-install device identifier for cloud-sync `sourceDevice`.
/// `UIDevice.current.name` returns "iPhone" generically on iOS 16+ unless
/// the app holds a special entitlement, which Quill doesn't — so it's
/// useless for telling devices apart. Vendor-scoped UUID + a model hint
/// is both stable across launches and human-readable in the cloud.
private enum DeviceIdentity {
  static let id: String = {
    let key = "quill.deviceID"
    if let existing = UserDefaults.standard.string(forKey: key) { return existing }
    let suffix = UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? UUID().uuidString.prefix(8)
    let model = UIDevice.current.model // "iPhone" / "iPad"
    let new = "\(model)-\(suffix)"
    UserDefaults.standard.set(new, forKey: key)
    return new
  }()
}

@MainActor
final class NotesStore: ObservableObject {
  static let shared = NotesStore()

  @Published private(set) var notes: [Note] = []
  @Published private(set) var activeNoteID: UUID?
  /// Note IDs with a title-generation request currently in flight.
  /// Prevents double-dispatch when multiple appends land before the
  /// first AI title request returns.
  @Published private(set) var generatingTitleIDs: Set<UUID> = []
  /// Cached AI analyses keyed by photo UUID. Populated from disk on
  /// launch and updated in-place when a new analysis lands; views bind
  /// to this so they auto-refresh when an async vision call completes.
  @Published private(set) var photoAnalyses: [UUID: PhotoAnalysis] = [:]
  /// Photo UUIDs currently being analyzed — the renderer shows a
  /// spinner next to these until they drop out of the set.
  @Published private(set) var analyzingPhotoIDs: Set<UUID> = []
  /// Last error seen per photo (if analysis failed). Keyed by photo ID
  /// so the UI can surface a localized hint on the offending card.
  @Published private(set) var analysisErrors: [UUID: String] = [:]

  private let fileURL: URL
  private let activeNoteKey = "quill.activeNoteID"
  /// Local-only debounce for live transcript revisions. Cloud uploads, widget
  /// refreshes, and title generation wait for the authoritative final text.
  private var pendingDraftSaves: [UUID: Task<Void, Never>] = [:]

  private init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    self.fileURL = docs.appendingPathComponent("notes.json")
    load()
    restoreActiveNoteID()
    loadAllAnalysesFromDisk()
  }

  // MARK: - Queries

  var activeNote: Note? {
    guard let id = activeNoteID else { return nil }
    return notes.first(where: { $0.id == id })
  }

  /// Pinned notes first, then descending by updatedAt so freshly-touched
  /// notes float to the top — matches the Mac transcription history order.
  var sortedNotes: [Note] {
    notes.sorted {
      if $0.isPinned != $1.isPinned { return $0.isPinned }
      return $0.updatedAt > $1.updatedAt
    }
  }

  // MARK: - Mutations

  /// Append text to the active note. If no active note exists yet, creates
  /// one (capturing location from the optional snapshot) and makes it
  /// active. Returns the note that was written to.
  @discardableResult
  func appendToActiveNote(_ text: String, locationIfCreating: NoteLocation?) -> Note {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return activeNote ?? startNewNote(location: nil) }

    let now = Date()
    if let idx = activeNoteIndex() {
      // Append with a blank line separator so successive recordings read
      // as paragraphs rather than running together.
      var note = notes[idx]
      if note.body.isEmpty {
        note.body = trimmed
      } else {
        note.body += "\n\n" + trimmed
      }
      note.updatedAt = now
      notes[idx] = note
      save(syncNoteID: note.id)
      return note
    } else {
      var note = Note(
        title: "",
        body: trimmed,
        createdAt: now,
        updatedAt: now,
        location: locationIfCreating
      )
      _ = note
      note.updatedAt = now
      notes.append(note)
      setActiveNote(id: note.id)
      save(syncNoteID: note.id)
      return note
    }
  }

  /// Create a brand-new, empty note and make it active. Caller is expected
  /// to pass a location snapshot if one is available.
  @discardableResult
  func startNewNote(location: NoteLocation?) -> Note {
    let note = Note(
      title: "",
      body: "",
      createdAt: Date(),
      location: location
    )
    notes.append(note)
    setActiveNote(id: note.id)
    save(syncNoteID: note.id)
    return note
  }

  /// Starts a session-scoped provisional paragraph in an existing note, or
  /// creates a new local-only note when recording begins from Home.
  ///
  /// The note is deliberately not cloud-synced yet: live recognition is
  /// revisionary and may ultimately be routed to an action instead.
  @discardableResult
  func beginTranscriptionDraft(
    noteID: UUID?,
    sessionID: UUID,
    locationIfCreating: NoteLocation? = nil
  ) -> (note: Note, created: Bool) {
    if let noteID, let idx = notes.firstIndex(where: { $0.id == noteID }) {
      var note = notes[idx]
      note.beginPendingTranscription(id: sessionID)
      notes[idx] = note
      setActiveNote(id: noteID)
      persistNotes()
      return (note, false)
    }

    var note = Note(title: "", body: "", location: locationIfCreating)
    note.beginPendingTranscription(id: sessionID)
    notes.append(note)
    setActiveNote(id: note.id)
    persistNotes()
    return (note, true)
  }

  /// Replaces the current full live-recognition hypothesis. Saving is
  /// debounced to avoid rewriting the JSON file on every individual word.
  func updateTranscriptionDraft(noteID: UUID, sessionID: UUID, text: String) {
    guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
    var note = notes[idx]
    guard note.updatePendingTranscription(id: sessionID, text: text) else { return }
    notes[idx] = note
    scheduleDraftPersistence(noteID: noteID)
  }

  /// Forces any debounced live drafts to disk before iOS suspends the app.
  /// This closes the small debounce window during calls, interruptions, or a
  /// user immediately leaving the app after speaking.
  func flushPendingTranscriptionDrafts() {
    guard !pendingDraftSaves.isEmpty else { return }
    for task in pendingDraftSaves.values { task.cancel() }
    pendingDraftSaves.removeAll()
    persistNotes()
  }

  /// Commits the final Whisper/AI output (or the last partial when final text
  /// is unavailable) as exactly one paragraph.
  @discardableResult
  func finalizeTranscriptionDraft(
    noteID: UUID,
    sessionID: UUID,
    finalText: String
  ) -> (note: Note, appendedText: String)? {
    guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return nil }
    var note = notes[idx]
    guard let appended = note.finalizePendingTranscription(id: sessionID, finalText: finalText) else {
      return nil
    }
    pendingDraftSaves[noteID]?.cancel()
    pendingDraftSaves[noteID] = nil
    notes[idx] = note
    save(syncNoteID: appended.isEmpty ? nil : noteID)
    return (note, appended)
  }

  /// Drops only this recording's provisional paragraph. A newly-created empty
  /// shell can be removed without emitting a cloud tombstone because it was
  /// never uploaded.
  @discardableResult
  func discardTranscriptionDraft(
    noteID: UUID,
    sessionID: UUID,
    deleteEmptyNote: Bool
  ) -> Bool {
    guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return false }
    var note = notes[idx]
    guard note.discardPendingTranscription(id: sessionID) else { return false }
    pendingDraftSaves[noteID]?.cancel()
    pendingDraftSaves[noteID] = nil

    let shouldDelete = deleteEmptyNote
      && note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && note.photoCount == 0
    if shouldDelete {
      notes.remove(at: idx)
      if activeNoteID == noteID {
        setActiveNote(id: sortedNotes.first?.id)
      }
    } else {
      notes[idx] = note
    }
    save()
    return shouldDelete
  }

  func setActiveNote(id: UUID?) {
    activeNoteID = id
    if let id {
      UserDefaults.standard.set(id.uuidString, forKey: activeNoteKey)
    } else {
      UserDefaults.standard.removeObject(forKey: activeNoteKey)
    }
  }

  func renameNote(id: UUID, to title: String) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[idx].title = title
    notes[idx].isAutoTitle = false
    notes[idx].updatedAt = Date()
    save(syncNoteID: id)
  }

  func updateBody(id: UUID, to body: String) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[idx].body = body
    notes[idx].updatedAt = Date()
    save(syncNoteID: id)
  }

  /// Pin/unpin without touching `updatedAt` — pinning is an
  /// organizational act, not an edit, so it shouldn't bump the note in
  /// recency order (or trigger a title regeneration).
  func togglePin(id: UUID) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[idx].isPinned.toggle()
    save(syncNoteID: id)
  }

  /// Append text to a specific (voice-targeted) note — "add milk to my
  /// groceries note". Same paragraph-separator behavior as the active-
  /// note append, but never creates a note and doesn't change which
  /// note is active.
  func appendToNote(id: UUID, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    if notes[idx].body.isEmpty {
      notes[idx].body = trimmed
    } else {
      notes[idx].body += "\n\n" + trimmed
    }
    notes[idx].updatedAt = Date()
    save(syncNoteID: id)
  }

  /// Attaches a location to a note after the fact.
  ///
  /// New notes are created without waiting for a location fix — the lookup
  /// can take many seconds (permission dialog, GPS, reverse geocode) and the
  /// note must not be held hostage to it. This lands the result when it
  /// arrives. No-op if the note is gone by then.
  func setLocation(id: UUID, location: NoteLocation?) {
    guard let location,
          let idx = notes.firstIndex(where: { $0.id == id }),
          notes[idx].location == nil else { return }
    notes[idx].location = location
    // Deliberately does NOT bump `updatedAt`: this is metadata arriving late
    // for a note the user already finished, not an edit they made.
    save(syncNoteID: id)
  }

  /// Undoes an append that `appendToActiveNote` / `appendToNote` just made,
  /// restoring the body to what it was. Used when a dictation is re-routed
  /// to the agent — the words belonged in a command, not in this note.
  ///
  /// Only an exact suffix is stripped. If the user typed, or an AI edit
  /// landed, in the seconds between, the note no longer ends in what we
  /// wrote and it's left alone — better a stray paragraph than eating an
  /// edit we didn't make.
  @discardableResult
  func retractAppend(id: UUID, text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let idx = notes.firstIndex(where: { $0.id == id }) else { return false }

    let body = notes[idx].body
    let restored: String
    if body == trimmed {
      restored = ""
    } else if body.hasSuffix("\n\n" + trimmed) {
      restored = String(body.dropLast(trimmed.count + 2))
    } else {
      return false
    }

    notes[idx].body = restored
    notes[idx].updatedAt = Date()
    save(syncNoteID: id)
    return true
  }

  // MARK: - Edit mode

  /// Apply an Edit-mode revision, stashing the previous body so the user
  /// can Undo. The note shows a diff until they Keep or Undo.
  func applyEdit(id: UUID, newBody: String, label: String) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    // Chained edits keep the ORIGINAL previous body, so Undo always
    // returns to the last state the user actually approved rather than to
    // an intermediate revision they never saw.
    let previous = notes[idx].pendingEdit?.previousBody ?? notes[idx].body
    notes[idx].pendingEdit = NoteEdit(previousBody: previous, label: label)
    notes[idx].body = newBody
    notes[idx].updatedAt = Date()
    save(syncNoteID: id)
  }

  /// Accept the revision — drop the diff, keep the new body.
  func keepEdit(id: UUID) {
    guard let idx = notes.firstIndex(where: { $0.id == id }),
          notes[idx].pendingEdit != nil else { return }
    notes[idx].pendingEdit = nil
    save(syncNoteID: id)
  }

  /// Revert to the body as it was before the revision.
  func undoEdit(id: UUID) {
    guard let idx = notes.firstIndex(where: { $0.id == id }),
          let pending = notes[idx].pendingEdit else { return }
    notes[idx].body = pending.previousBody
    notes[idx].pendingEdit = nil
    notes[idx].updatedAt = Date()
    save(syncNoteID: id)
  }

  func deleteNote(id: UUID) {
    let photoIDs: [UUID]
    if let note = notes.first(where: { $0.id == id }) {
      photoIDs = NoteContent.photoIDs(in: note.body)
    } else {
      photoIDs = []
    }

    notes.removeAll { $0.id == id }
    PhotoStore.shared.deleteAllPhotos(noteID: id)
    if activeNoteID == id {
      setActiveNote(id: sortedNotes.first?.id)
    }
    save()
    deleteNoteFromCloud(id)
    for photoID in photoIDs {
      deletePhotoFromCloud(noteID: id, photoID: photoID)
    }
  }

  /// Save `image` to disk, make sure there's an active note to attach it
  /// to (creating one with the given location if not), and append a
  /// `![photo](<uuid>)` token to the body. Returns the IDs of the note
  /// and photo so the caller can kick off background analysis.
  @discardableResult
  func insertPhotoIntoActiveNote(
    _ image: UIImage,
    locationIfCreating: NoteLocation?
  ) -> (noteID: UUID, photoID: UUID)? {
    let targetID: UUID
    if let id = activeNoteID {
      targetID = id
    } else {
      targetID = startNewNote(location: locationIfCreating).id
    }

    do {
      let photoID = try PhotoStore.shared.savePhoto(image, for: targetID)
      guard let idx = notes.firstIndex(where: { $0.id == targetID }) else { return nil }
      let token = NoteContent.photoToken(for: photoID)
      var note = notes[idx]
      if note.body.isEmpty {
        note.body = token
      } else {
        note.body += "\n\n" + token
      }
      note.updatedAt = Date()
      notes[idx] = note
      save(syncNoteID: targetID)
      uploadPhotoToCloud(noteID: targetID, photoID: photoID)
      return (targetID, photoID)
    } catch {
      print("NotesStore: failed to save photo: \(error)")
      return nil
    }
  }

  // MARK: - Auto titles

  /// If `noteID` still has `isAutoTitle == true` (either a brand-new
  /// note that just got its first append, or one that's never been
  /// renamed/AI-titled), fire an async LLM call to generate a
  /// short, specific title for it. No-op when:
  ///   - the note has already been user-renamed or AI-titled,
  ///   - its body is empty,
  ///   - another title request for the same note is already in flight,
  ///   - the provider has no API key configured (title gen is a
  ///     nice-to-have; we don't surface an error for this).
  func generateTitleIfNeeded(noteID: UUID, provider: AIProvider) {
    guard let note = notes.first(where: { $0.id == noteID }) else { return }
    guard note.isAutoTitle else { return }
    let body = NoteContent.stripPhotos(from: note.body)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    guard !generatingTitleIDs.contains(noteID) else { return }
    generatingTitleIDs.insert(noteID)

    // Cap the input at 800 chars — titles only need the gist, and
    // long inputs slow the LLM down + cost more tokens than this
    // feature warrants.
    let input = body.count > 800 ? String(body.prefix(800)) : body

    Task { @MainActor in
      defer { generatingTitleIDs.remove(noteID) }

      do {
        let title = try await TextAIClient.generateTitle(for: input, provider: provider)
        guard !title.isEmpty else { return }
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        // Re-check: the user may have renamed manually between the
        // request firing and the reply landing. Don't stomp their
        // choice.
        guard notes[idx].isAutoTitle else { return }
        notes[idx].title = title
        notes[idx].isAutoTitle = false
        notes[idx].updatedAt = Date()
        save(syncNoteID: noteID)
      } catch {
        // Best-effort: log and leave the title as the derived
        // fallback. Don't surface to the user — a missing API key
        // shouldn't feel like a failure here.
        print("NotesStore: title generation failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Photo analyses

  /// Walk every note's body on launch and load any `<photo-id>.json`
  /// sidecars into the published map. Keeps analyses visible across
  /// app restarts without re-calling the vision API.
  private func loadAllAnalysesFromDisk() {
    var out: [UUID: PhotoAnalysis] = [:]
    for note in notes {
      for photoID in NoteContent.photoIDs(in: note.body) {
        if let a = PhotoStore.shared.loadAnalysis(noteID: note.id, photoID: photoID) {
          out[photoID] = a
        }
      }
    }
    photoAnalyses = out
  }

  /// Fire-and-forget: ship the photo to the configured vision LLM,
  /// persist the result as a sidecar, and publish it. If the user has
  /// no API key for the chosen provider, record a localized error
  /// instead of blowing up.
  func analyzePhoto(noteID: UUID, photoID: UUID, provider: AIProvider) {
    // Guard against duplicate in-flight requests for the same photo
    // (e.g. user taps Retry twice).
    guard !analyzingPhotoIDs.contains(photoID) else { return }
    analyzingPhotoIDs.insert(photoID)
    analysisErrors[photoID] = nil

    Task { @MainActor in
      defer { analyzingPhotoIDs.remove(photoID) }

      guard let data = PhotoStore.shared.imageData(noteID: noteID, photoID: photoID) else {
        analysisErrors[photoID] = "Photo file not found on disk."
        return
      }

      do {
        let analysis = try await PhotoAnalysisClient.analyze(imageData: data, provider: provider)
        try? PhotoStore.shared.saveAnalysis(analysis, noteID: noteID, photoID: photoID)
        photoAnalyses[photoID] = analysis
      } catch {
        analysisErrors[photoID] = error.localizedDescription
        print("NotesStore: photo analysis failed for \(photoID): \(error)")
      }
    }
  }

  // MARK: - Cloud Sync

  /// Cloud-synced notes from other devices (macOS transcripts, etc.)
  @Published private(set) var cloudNotes: [SyncableNote] = []

  enum SyncStatus: Equatable {
    case idle
    case syncing
    case completed(notesUp: Int, notesDown: Int, at: Date)
    case failed(String)
  }

  @Published private(set) var syncStatus: SyncStatus = .idle

  /// Per-note upload tasks. We coalesce rapid successive saves (typing
  /// in NoteEditSheet, AI title landing right after a record append) by
  /// cancelling any pending upload for the same note ID before scheduling
  /// the new one. Without this, multiple PATCHes for the same doc race —
  /// Firestore takes whichever lands last, not whichever was issued last,
  /// so a stale earlier version can clobber a fresh later one.
  private var pendingUploads: [UUID: Task<Void, Never>] = [:]

  func syncNow() async {
    guard UserDefaults.standard.bool(forKey: CloudSyncConstants.cloudSyncEnabledKey),
          IOSGoogleOAuthClient.isAuthorized()
    else {
      syncStatus = .failed("Cloud sync is off or Google not connected.")
      return
    }

    syncStatus = .syncing

    do {
      let accessToken = try await IOSGoogleOAuthClient.refreshIfNeeded()
      guard let email = UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) else {
        syncStatus = .failed("No Google email cached.")
        return
      }

      let tombstones = await CloudSyncManager.shared.fetchTombstones(accessToken: accessToken, userEmail: email)
      let tombstonedIDs = Set(tombstones.map(\.id))

      for tomb in tombstones {
        if let idx = notes.firstIndex(where: { $0.id == tomb.id }) {
          if notes[idx].updatedAt <= tomb.deletedAt {
            notes.remove(at: idx)
            PhotoStore.shared.deleteAllPhotos(noteID: tomb.id)
          }
        }
      }

      let localSyncables = notes
        .filter { !tombstonedIDs.contains($0.id) }
        .map { noteToSyncable($0) }

      let result = await CloudSyncManager.shared.fullSync(
        localNotes: localSyncables,
        localTranscripts: [],
        accessToken: accessToken,
        userEmail: email
      )

      var notesDown = 0
      for cloudNote in result.notesFromCloud where !tombstonedIDs.contains(cloudNote.id) {
        mergeCloudNote(cloudNote)
        notesDown += 1
      }

      let manifests = await CloudSyncManager.shared.fetchPhotoManifests(accessToken: accessToken, userEmail: email)
      await downloadMissingPhotos(manifests: manifests, tombstonedNoteIds: tombstonedIDs, accessToken: accessToken)

      let remoteTranscripts = await CloudSyncManager.shared.fetchTranscripts(
        accessToken: accessToken,
        userEmail: email
      )
      self.cloudNotes = remoteTranscripts.map { t in
        SyncableNote(
          id: t.id,
          title: t.sourceAppName ?? "Transcription",
          body: t.text,
          createdAt: t.timestamp,
          updatedAt: t.timestamp,
          sourceDevice: t.sourceDevice,
          sourcePlatform: t.sourcePlatform
        )
      }

      syncStatus = .completed(notesUp: result.notesUploaded, notesDown: notesDown, at: Date())

    } catch {
      syncStatus = .failed(error.localizedDescription)
      print("NotesStore: cloud sync failed: \(error.localizedDescription)")
    }
  }

  private func syncNoteToCloud(_ note: Note) {
    guard UserDefaults.standard.bool(forKey: CloudSyncConstants.cloudSyncEnabledKey),
          IOSGoogleOAuthClient.isAuthorized()
    else { return }

    let id = note.id
    pendingUploads[id]?.cancel()
    pendingUploads[id] = Task { [weak self] in
      // 500ms debounce — coalesces typing bursts and back-to-back
      // mutations (e.g. body append + AI title landing within the
      // same second). The latest pending state is read inside the
      // task so we always upload the freshest snapshot.
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled, let self else { return }

      // Re-read the latest version of the note from the store rather
      // than uploading the stale snapshot captured at scheduling time —
      // by the time the debounce elapses there may be even newer edits.
      guard let latest = self.notes.first(where: { $0.id == id }) else {
        self.pendingUploads[id] = nil
        return
      }

      do {
        let accessToken = try await IOSGoogleOAuthClient.refreshIfNeeded()
        guard let email = UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) else {
          self.pendingUploads[id] = nil
          return
        }
        let syncable = self.noteToSyncable(latest)
        await CloudSyncManager.shared.uploadNote(syncable, accessToken: accessToken, userEmail: email)
      } catch {
        print("NotesStore: background sync failed: \(error.localizedDescription)")
      }
      self.pendingUploads[id] = nil
    }
  }

  private func deleteNoteFromCloud(_ id: UUID) {
    guard UserDefaults.standard.bool(forKey: CloudSyncConstants.cloudSyncEnabledKey),
          IOSGoogleOAuthClient.isAuthorized()
    else { return }

    let device = DeviceIdentity.id
    Task {
      do {
        let accessToken = try await IOSGoogleOAuthClient.refreshIfNeeded()
        guard let email = UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) else { return }
        await CloudSyncManager.shared.writeTombstone(id: id, sourceDevice: device, accessToken: accessToken, userEmail: email)
        await CloudSyncManager.shared.deleteNote(id: id, accessToken: accessToken, userEmail: email)
      } catch {
        print("NotesStore: cloud delete failed: \(error.localizedDescription)")
      }
    }
  }

  /// Upload a photo's JPEG bytes to GCS + write its manifest to Firestore.
  /// Best-effort: if cloud sync is off, no Google account, or the network
  /// is down, we silently no-op (the photo still lives locally). When the
  /// user re-enables sync or comes back online, the next `syncNow` won't
  /// re-upload existing photos because the manifest tells us what's
  /// already up — but our current sync pass doesn't push photos for
  /// already-saved notes. For V1 this is fine: photos sync at insert
  /// time. A "Sync all photos" backfill is a follow-up.
  func uploadPhotoToCloud(noteID: UUID, photoID: UUID) {
    guard UserDefaults.standard.bool(forKey: CloudSyncConstants.cloudSyncEnabledKey),
          IOSGoogleOAuthClient.isAuthorized()
    else { return }
    guard let data = PhotoStore.shared.imageData(noteID: noteID, photoID: photoID) else {
      print("NotesStore: photo \(photoID) missing on disk, skipping upload")
      return
    }
    let device = DeviceIdentity.id
    Task {
      do {
        let accessToken = try await IOSGoogleOAuthClient.refreshIfNeeded()
        guard let email = UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) else { return }
        await CloudSyncManager.shared.uploadPhoto(
          noteId: noteID,
          photoId: photoID,
          data: data,
          sourceDevice: device,
          accessToken: accessToken,
          userEmail: email
        )
      } catch {
        print("NotesStore: photo upload failed: \(error.localizedDescription)")
      }
    }
  }

  func deletePhotoFromCloud(noteID: UUID, photoID: UUID) {
    guard UserDefaults.standard.bool(forKey: CloudSyncConstants.cloudSyncEnabledKey),
          IOSGoogleOAuthClient.isAuthorized()
    else { return }
    Task {
      do {
        let accessToken = try await IOSGoogleOAuthClient.refreshIfNeeded()
        guard let email = UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) else { return }
        await CloudSyncManager.shared.deletePhoto(noteId: noteID, photoId: photoID, accessToken: accessToken, userEmail: email)
      } catch {
        print("NotesStore: photo delete failed: \(error.localizedDescription)")
      }
    }
  }

  /// Download any photos referenced by local notes that aren't already
  /// on disk. Called during `syncNow` after notes have merged so the
  /// local body's photo tokens have a JPEG to render. Skips photos
  /// whose manifest matches a tombstoned note.
  private func downloadMissingPhotos(manifests: [PhotoManifest], tombstonedNoteIds: Set<UUID>, accessToken: String) async {
    let localNoteIds = Set(notes.map(\.id))
    for manifest in manifests {
      guard localNoteIds.contains(manifest.noteId),
            !tombstonedNoteIds.contains(manifest.noteId)
      else { continue }
      let localURL = PhotoStore.shared.url(noteID: manifest.noteId, photoID: manifest.photoId)
      if FileManager.default.fileExists(atPath: localURL.path) { continue }

      guard let data = await CloudSyncManager.shared.downloadPhoto(manifest: manifest, accessToken: accessToken) else { continue }
      let dir = localURL.deletingLastPathComponent()
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      do {
        try data.write(to: localURL, options: [.atomic])
      } catch {
        print("NotesStore: failed to write downloaded photo: \(error)")
      }
    }
  }

  private func noteToSyncable(_ note: Note) -> SyncableNote {
    SyncableNote(
      id: note.id,
      title: note.title,
      body: note.body,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      latitude: note.location?.latitude,
      longitude: note.location?.longitude,
      placeName: note.location?.placeName,
      isAutoTitle: note.isAutoTitle,
      sourceDevice: DeviceIdentity.id,
      sourcePlatform: .iOS
    )
  }

  private func mergeCloudNote(_ cloud: SyncableNote) {
    if let idx = notes.firstIndex(where: { $0.id == cloud.id }) {
      if cloud.updatedAt > notes[idx].updatedAt {
        notes[idx].title = cloud.title
        notes[idx].body = cloud.body
        notes[idx].updatedAt = cloud.updatedAt
        notes[idx].isAutoTitle = cloud.isAutoTitle
        if let lat = cloud.latitude, let lng = cloud.longitude {
          notes[idx].location = NoteLocation(latitude: lat, longitude: lng, placeName: cloud.placeName)
        }
      }
    } else if cloud.sourcePlatform == .iOS {
      let note = Note(
        id: cloud.id,
        title: cloud.title,
        body: cloud.body,
        createdAt: cloud.createdAt,
        updatedAt: cloud.updatedAt,
        location: cloud.latitude.flatMap { lat in
          cloud.longitude.map { lng in
            NoteLocation(latitude: lat, longitude: lng, placeName: cloud.placeName)
          }
        },
        isAutoTitle: cloud.isAutoTitle
      )
      notes.append(note)
    }
    save()
  }

  // MARK: - Persistence

  private func activeNoteIndex() -> Int? {
    guard let id = activeNoteID else { return nil }
    return notes.firstIndex(where: { $0.id == id })
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    do {
      var decoded = try JSONDecoder.notes.decode([Note].self, from: data)
      var recoveredDraft = false
      for index in decoded.indices where decoded[index].pendingTranscription != nil {
        // Even an empty draft must be cleared. A non-empty one is promoted to
        // ordinary body text so it is visible and eligible for the next sync.
        let hadPending = decoded[index].pendingTranscription != nil
        _ = decoded[index].recoverPendingTranscription()
        recoveredDraft = recoveredDraft || hadPending
      }
      self.notes = decoded
      if recoveredDraft { persistNotes() }
    } catch {
      // Corrupted or schema-mismatched file — log but don't crash.
      print("NotesStore: failed to decode notes.json: \(error)")
    }
  }

  private func save(syncNoteID: UUID? = nil) {
    persistNotes()
    updateWidgetSnapshot()

    if let id = syncNoteID, let note = notes.first(where: { $0.id == id }) {
      syncNoteToCloud(note)
    }
  }

  private func persistNotes() {
    do {
      let data = try JSONEncoder.notes.encode(notes)
      try data.write(to: fileURL, options: [.atomic])
    } catch {
      print("NotesStore: failed to persist notes.json: \(error)")
    }
  }

  private func scheduleDraftPersistence(noteID: UUID) {
    pendingDraftSaves[noteID]?.cancel()
    pendingDraftSaves[noteID] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self else { return }
      self.persistNotes()
      self.pendingDraftSaves[noteID] = nil
    }
  }

  /// Pick the most-recently-updated note and publish a compact
  /// snapshot for the widget extension.
  private func updateWidgetSnapshot() {
    guard let latest = sortedNotes.first else {
      QuillWidgetSnapshot.clear()
      #if canImport(WidgetKit)
      WidgetCenter.shared.reloadAllTimelines()
      #endif
      return
    }

    let cleanedBody = NoteContent.stripPhotos(from: latest.body)
    let previewChars = 120
    let preview: String
    if cleanedBody.count <= previewChars {
      preview = cleanedBody
    } else {
      preview = String(cleanedBody.prefix(previewChars)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    let snapshot = QuillWidgetSnapshot(
      title: latest.displayTitle,
      preview: preview,
      updatedAt: latest.updatedAt
    )
    snapshot.save()

    #if canImport(WidgetKit)
    WidgetCenter.shared.reloadAllTimelines()
    #endif
  }

  private func restoreActiveNoteID() {
    guard let raw = UserDefaults.standard.string(forKey: activeNoteKey),
          let uuid = UUID(uuidString: raw),
          notes.contains(where: { $0.id == uuid })
    else { return }
    self.activeNoteID = uuid
  }
}

private extension JSONEncoder {
  static let notes: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }()
}

private extension JSONDecoder {
  static let notes: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}
