#if os(macOS)
import ComposableArchitecture
import Dependencies
import Foundation
import HexCore
import os
import Sharing

private let syncLogger = Logger(subsystem: "com.joevasquez.Quill", category: "cloudSync")

enum CloudSyncStatus: Equatable {
  case idle
  case syncing
  case completed(transcriptsUp: Int, notesDown: Int, at: Date)
  case failed(String)
}

@MainActor
final class MacCloudSync: ObservableObject {
  static let shared = MacCloudSync()

  private(set) var lastSyncNotesCount: Int = 0
  @Published var cloudNotes: [SyncableNote] = [] {
    didSet { scheduleLocalPersist() }
  }
  @Published private(set) var status: CloudSyncStatus = .idle
  /// Map of noteId → ordered photoIds, derived from photo manifests. The
  /// NotesView reads this to know which photos to render inline.
  @Published private(set) var cloudNotePhotos: [UUID: [UUID]] = [:] {
    didSet { scheduleLocalPersist() }
  }
  /// IDs of notes that have local edits not yet synced to cloud.
  @Published private(set) var dirtyNoteIDs: Set<UUID> = [] {
    didSet { scheduleLocalPersist() }
  }

  private init() {
    // Notes are cached on disk so the list is there the instant the app
    // opens — the network sync then refreshes it in the background.
    // Without this, every launch showed an empty pane until a round-trip
    // completed, and an edit that hadn't uploaded yet was lost on quit.
    loadLocalCache()
  }

  // MARK: - Local cache

  /// Everything the UI needs to render notes offline.
  private struct LocalNotesCache: Codable {
    var notes: [SyncableNote]
    var photos: [UUID: [UUID]]
    var dirtyIDs: [UUID]
  }

  private static let cacheFileName = "mac-notes-cache.json"
  private var cacheURL: URL? {
    try? URL.hexApplicationSupport.appendingPathComponent(Self.cacheFileName, isDirectory: false)
  }

  /// True while the cache is being applied, so the `didSet` hooks don't
  /// immediately re-persist what we just read.
  private var isLoadingCache = false
  private var pendingPersist: Task<Void, Never>?

  private func loadLocalCache() {
    guard let url = cacheURL,
          FileManager.default.fileExists(atPath: url.path)
    else { return }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let cache = try decoder.decode(LocalNotesCache.self, from: data)
      isLoadingCache = true
      cloudNotes = cache.notes
      cloudNotePhotos = cache.photos
      dirtyNoteIDs = Set(cache.dirtyIDs)
      lastSyncNotesCount = cache.notes.count
      isLoadingCache = false
      syncLogger.info("Loaded \(cache.notes.count, privacy: .public) note(s) from local cache (\(cache.dirtyIDs.count, privacy: .public) unsynced)")
    } catch {
      syncLogger.error("Local note cache load failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Coalesce the many small mutations an editing session produces (the
  /// editor writes through a binding on every keystroke) into one write.
  private func scheduleLocalPersist() {
    guard !isLoadingCache else { return }
    pendingPersist?.cancel()
    pendingPersist = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.persistLocalCacheNow()
    }
  }

  /// Synchronous write — also called on app termination so the last
  /// second of typing can't be lost.
  func persistLocalCacheNow() {
    pendingPersist?.cancel()
    pendingPersist = nil
    guard let url = cacheURL else { return }
    do {
      let cache = LocalNotesCache(
        notes: cloudNotes,
        photos: cloudNotePhotos,
        dirtyIDs: Array(dirtyNoteIDs)
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(cache).write(to: url, options: [.atomic])
    } catch {
      syncLogger.error("Local note cache save failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func markDirty(id: UUID) {
    dirtyNoteIDs.insert(id)
  }

  /// Per-note pending auto-uploads — each new change cancels and restarts
  /// the note's timer, so the upload fires once, after typing settles.
  private var pendingAutoUploads: [UUID: Task<Void, Never>] = [:]

  /// Auto-upload window after the LAST change. Wider than iOS's 500ms
  /// per-note debounce because Mac editing sessions are keystroke-heavy.
  private static let autoUploadDelay: Duration = .seconds(7)

  private var cloudSyncEnabled: Bool {
    @Shared(.hexSettings) var settings: HexSettings
    return settings.cloudSyncEnabled
  }

  /// Mark dirty AND schedule a debounced upload — edits sync themselves
  /// a few seconds after the user stops typing instead of waiting for a
  /// manual Sync Now.
  func markDirtyAndScheduleUpload(id: UUID) {
    markDirty(id: id)
    guard cloudSyncEnabled, isGoogleAuthorized() else { return }
    pendingAutoUploads[id]?.cancel()
    pendingAutoUploads[id] = Task { [weak self] in
      try? await Task.sleep(for: Self.autoUploadDelay)
      guard !Task.isCancelled else { return }
      await self?.uploadDirtyNote(id: id)
      self?.pendingAutoUploads[id] = nil
    }
  }

  func clearDirty(id: UUID) {
    dirtyNoteIDs.remove(id)
  }

  /// Renames locally first, then lets the normal debounced uploader carry
  /// the change across devices. An explicit rename disables auto-titling.
  func renameNote(id: UUID, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let index = cloudNotes.firstIndex(where: { $0.id == id })
    else { return }

    cloudNotes[index].title = trimmed
    cloudNotes[index].isAutoTitle = false
    cloudNotes[index].updatedAt = Date()
    markDirtyAndScheduleUpload(id: id)
  }

  /// One deletion path for the editor toolbar and sidebar row menu. The
  /// local cache is flushed immediately; cloud deletion uses the existing
  /// tombstone path so another device cannot resurrect a stale copy.
  func deleteNote(id: UUID) {
    pendingAutoUploads[id]?.cancel()
    pendingAutoUploads[id] = nil
    let photoIDs = cloudNotes
      .first { $0.id == id }
      .map { NoteContent.photoIDs(in: $0.body) } ?? []

    cloudNotes.removeAll { $0.id == id }
    dirtyNoteIDs.remove(id)
    cloudNotePhotos[id] = nil
    MacPhotoStore.shared.deleteAllPhotos(noteID: id)
    persistLocalCacheNow()

    Task {
      await deleteNoteFromCloud(id: id, photoIDs: photoIDs)
    }
  }

  func pauseAutomaticSync() {
    for task in pendingAutoUploads.values { task.cancel() }
    pendingAutoUploads.removeAll()
    status = .idle
  }

  /// Creates a locally durable Mac note and schedules cloud upload when sync
  /// is available. Used by recovery and by dictations with no text target.
  @discardableResult
  func createNote(body: String, title: String = "") -> UUID {
    let now = Date()
    let note = SyncableNote(
      id: UUID(),
      title: title,
      body: body,
      createdAt: now,
      updatedAt: now,
      isAutoTitle: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      sourceDevice: Host.current().localizedName ?? "Mac",
      sourcePlatform: .macOS
    )
    cloudNotes.insert(note, at: 0)
    markDirtyAndScheduleUpload(id: note.id)
    // Recovery/fallback saves should survive an immediate quit, not wait for
    // the normal one-second editor debounce.
    persistLocalCacheNow()
    return note.id
  }

  func uploadDirtyNote(id: UUID) async {
    guard cloudSyncEnabled,
          let note = cloudNotes.first(where: { $0.id == id }),
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    status = .syncing
    await CloudSyncManager.shared.clearLastError()
    await CloudSyncManager.shared.uploadNote(note, accessToken: accessToken, userEmail: email)
    if let error = await CloudSyncManager.shared.lastError {
      status = .failed(error)
    } else {
      dirtyNoteIDs.remove(id)
      status = .completed(transcriptsUp: 0, notesDown: 0, at: Date())
    }
  }

  func uploadAllDirtyNotes() async {
    guard cloudSyncEnabled,
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    status = .syncing
    let dirty = cloudNotes.filter { dirtyNoteIDs.contains($0.id) }
    await CloudSyncManager.shared.clearLastError()
    for note in dirty {
      await CloudSyncManager.shared.uploadNote(note, accessToken: accessToken, userEmail: email)
    }
    if let error = await CloudSyncManager.shared.lastError {
      status = .failed(error)
    } else {
      dirtyNoteIDs.removeAll()
      status = .completed(transcriptsUp: 0, notesDown: dirty.count, at: Date())
    }
  }

  func isGoogleAuthorized() -> Bool {
    guard !UserDefaults.standard.bool(forKey: GoogleOAuthClient.reconnectRequiredDefaultsKey) else {
      return false
    }
    let email = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)
    return email?.isEmpty == false
  }

  func syncTranscripts(_ transcripts: [Transcript]) async {
    guard cloudSyncEnabled else {
      status = .idle
      return
    }
    // App activation and Home appearance can arrive together. The shared
    // manager represents overlapping work with an empty result, so coalesce
    // duplicate requests here before that result can flash-clear the list.
    guard status != .syncing else {
      syncLogger.info("macOS sync already in progress; coalescing duplicate request")
      return
    }
    status = .syncing
    guard let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else {
      status = .failed("Not signed in to Google.")
      return
    }
    await CloudSyncManager.shared.clearLastError()

    let device = Host.current().localizedName ?? "Mac"

    let tombstones = await CloudSyncManager.shared.fetchTombstones(accessToken: accessToken, userEmail: email)
    let tombstonedIDs = Set(tombstones.map(\.id))

    let syncables = transcripts.map { t in
      SyncableTranscript(
        id: t.id,
        text: t.text,
        timestamp: t.timestamp,
        duration: t.duration,
        sourceAppBundleID: t.sourceAppBundleID,
        sourceAppName: t.sourceAppName,
        speakerTranscript: t.speakerTranscript,
        sourceDevice: device,
        sourcePlatform: .macOS
      )
    }.filter { !tombstonedIDs.contains($0.id) }

    let result = await CloudSyncManager.shared.fullSync(
      localNotes: [],
      localTranscripts: syncables,
      accessToken: accessToken,
      userEmail: email
    )

    let filteredNotes = result.notesFromCloud.filter { !tombstonedIDs.contains($0.id) }
    // Merge rather than replace: a note edited locally but not yet
    // uploaded (the debounced upload hadn't fired, or we were offline)
    // must survive the incoming cloud copy, otherwise the local cache
    // would show the edit and then a sync would silently revert it.
    let locallyDirty = cloudNotes.filter { dirtyNoteIDs.contains($0.id) && !tombstonedIDs.contains($0.id) }
    let merged = mergePreservingLocalEdits(cloudNotes: filteredNotes, tombstonedIDs: tombstonedIDs)
    self.cloudNotes = merged
    self.lastSyncNotesCount = merged.count

    // Fetch photo manifests + download any photos we don't have yet.
    let manifests = await CloudSyncManager.shared.fetchPhotoManifests(accessToken: accessToken, userEmail: email)
    let knownNoteIds = Set(merged.map(\.id))
    var photosByNote: [UUID: [UUID]] = [:]
    for manifest in manifests where knownNoteIds.contains(manifest.noteId) && !tombstonedIDs.contains(manifest.noteId) {
      photosByNote[manifest.noteId, default: []].append(manifest.photoId)
      if !MacPhotoStore.shared.hasPhoto(noteID: manifest.noteId, photoID: manifest.photoId) {
        if let data = await CloudSyncManager.shared.downloadPhoto(manifest: manifest, accessToken: accessToken) {
          do {
            try MacPhotoStore.shared.save(data: data, noteID: manifest.noteId, photoID: manifest.photoId)
          } catch {
            syncLogger.error("Failed to cache downloaded photo: \(error.localizedDescription, privacy: .public)")
          }
        }
      }
    }
    self.cloudNotePhotos = photosByNote
    // Push the local edits we just preserved — otherwise a note edited
    // offline stays dirty forever, since nothing else retries it.
    for note in locallyDirty {
      await CloudSyncManager.shared.uploadNote(note, accessToken: accessToken, userEmail: email)
      if await CloudSyncManager.shared.lastError == nil {
        dirtyNoteIDs.remove(note.id)
      }
    }

    // Writes swallow their errors so one bad record can't abort the batch,
    // so ask the manager whether anything actually failed — otherwise a
    // fully-rejected sync would still report "completed" and clear its dot.
    if let failure = await CloudSyncManager.shared.lastError {
      self.status = .failed(failure)
      await CloudSyncManager.shared.clearLastError()
    } else {
      self.status = .completed(transcriptsUp: result.transcriptsUploaded, notesDown: merged.count, at: Date())
    }

    syncLogger.info("macOS sync complete: \(merged.count) notes (\(locallyDirty.count) local edits preserved), \(result.transcriptsUploaded) transcripts uploaded, \(manifests.count) photo manifests")
  }

  /// Refresh on app activation without repeatedly hitting the network while
  /// the user moves between Quill and another app.
  func syncIfNeeded(_ transcripts: [Transcript], minimumInterval: TimeInterval = 300) async {
    guard cloudSyncEnabled, isGoogleAuthorized() else { return }
    if case let .completed(_, _, at) = status,
       Date().timeIntervalSince(at) < minimumInterval {
      return
    }
    await syncTranscripts(transcripts)
  }

  func deleteTranscriptFromCloud(id: UUID) async {
    @Shared(.hexSettings) var hexSettings: HexSettings
    guard hexSettings.cloudSyncEnabled,
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    let device = Host.current().localizedName ?? "Mac"
    await CloudSyncManager.shared.writeTombstone(id: id, sourceDevice: device, accessToken: accessToken, userEmail: email)
    await CloudSyncManager.shared.deleteTranscript(id: id, accessToken: accessToken, userEmail: email)
  }

  func deleteNoteFromCloud(id: UUID, photoIDs: [UUID] = []) async {
    @Shared(.hexSettings) var hexSettings: HexSettings
    guard hexSettings.cloudSyncEnabled,
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    let device = Host.current().localizedName ?? "Mac"
    await CloudSyncManager.shared.writeTombstone(id: id, sourceDevice: device, accessToken: accessToken, userEmail: email)
    await CloudSyncManager.shared.deleteNote(id: id, accessToken: accessToken, userEmail: email)
    // Delete-parity with iOS: the note's cloud photos (GCS objects +
    // manifests) go with it, so storage doesn't accrete orphans.
    for photoID in photoIDs {
      await CloudSyncManager.shared.deletePhoto(noteId: id, photoId: photoID, accessToken: accessToken, userEmail: email)
    }
    syncLogger.info("Deleted note \(id) from cloud with tombstone (+\(photoIDs.count) photo(s))")
  }

  /// On-demand photo download for one note — the detail pane calls this
  /// when a note with missing photos is opened, so photos appear without
  /// waiting for the next full sync.
  func fetchMissingPhotos(for note: SyncableNote) async {
    guard cloudSyncEnabled else { return }
    let missing = NoteContent.photoIDs(in: note.body).filter {
      !MacPhotoStore.shared.hasPhoto(noteID: note.id, photoID: $0)
    }
    guard !missing.isEmpty,
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    let manifests = await CloudSyncManager.shared.fetchPhotoManifests(accessToken: accessToken, userEmail: email)
    for photoID in missing {
      guard let manifest = manifests.first(where: { $0.noteId == note.id && $0.photoId == photoID }) else { continue }
      if let data = await CloudSyncManager.shared.downloadPhoto(manifest: manifest, accessToken: accessToken) {
        try? MacPhotoStore.shared.save(data: data, noteID: note.id, photoID: photoID)
      }
    }
  }

  func uploadTranscript(_ transcript: Transcript) async {
    guard cloudSyncEnabled,
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    let syncable = SyncableTranscript(
      id: transcript.id,
      text: transcript.text,
      timestamp: transcript.timestamp,
      duration: transcript.duration,
      sourceAppBundleID: transcript.sourceAppBundleID,
      sourceAppName: transcript.sourceAppName,
      speakerTranscript: transcript.speakerTranscript,
      sourceDevice: Host.current().localizedName ?? "Mac",
      sourcePlatform: .macOS
    )

    await CloudSyncManager.shared.uploadTranscript(syncable, accessToken: accessToken, userEmail: email)
  }

  func fetchCloudNotes() async -> [SyncableNote] {
    guard cloudSyncEnabled,
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return [] }

    let notes = await CloudSyncManager.shared.fetchNotes(accessToken: accessToken, userEmail: email)
    // Same merge as performSync — this runs on every Home appear, so a
    // blind assignment here would revert unsynced local edits.
    let merged = mergePreservingLocalEdits(cloudNotes: notes)
    self.cloudNotes = merged
    return merged
  }

  /// Cloud notes as the base, with locally-dirty notes (edited or created
  /// but not yet uploaded) laid back on top. `tombstonedIDs` drops notes
  /// deleted elsewhere.
  private func mergePreservingLocalEdits(
    cloudNotes incoming: [SyncableNote],
    tombstonedIDs: Set<UUID> = []
  ) -> [SyncableNote] {
    let locallyDirty = cloudNotes.filter {
      dirtyNoteIDs.contains($0.id) && !tombstonedIDs.contains($0.id)
    }
    var merged = incoming
    for dirty in locallyDirty {
      if let index = merged.firstIndex(where: { $0.id == dirty.id }) {
        if dirty.updatedAt >= merged[index].updatedAt {
          merged[index] = dirty
        }
      } else {
        merged.append(dirty)
      }
    }
    return merged
  }

  private func getAccessToken() async -> String? {
    @Dependency(\.googleOAuth) var googleOAuth
    do {
      return try await googleOAuth.refreshIfNeeded()
    } catch {
      syncLogger.error("Cloud sync: failed to get access token: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private func getUserEmail() -> String? {
    UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)
  }
}

#endif
