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
  @Published var cloudNotes: [SyncableNote] = []
  @Published private(set) var status: CloudSyncStatus = .idle
  /// Map of noteId → ordered photoIds, derived from photo manifests. The
  /// NotesView reads this to know which photos to render inline.
  @Published private(set) var cloudNotePhotos: [UUID: [UUID]] = [:]
  /// IDs of notes that have local edits not yet synced to cloud.
  @Published private(set) var dirtyNoteIDs: Set<UUID> = []

  private init() {}

  func markDirty(id: UUID) {
    dirtyNoteIDs.insert(id)
  }

  func clearDirty(id: UUID) {
    dirtyNoteIDs.remove(id)
  }

  func uploadDirtyNote(id: UUID) async {
    guard let note = cloudNotes.first(where: { $0.id == id }),
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    status = .syncing
    await CloudSyncManager.shared.uploadNote(note, accessToken: accessToken, userEmail: email)
    dirtyNoteIDs.remove(id)
    status = .completed(transcriptsUp: 0, notesDown: 0, at: Date())
  }

  func uploadAllDirtyNotes() async {
    guard let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    status = .syncing
    let dirty = cloudNotes.filter { dirtyNoteIDs.contains($0.id) }
    for note in dirty {
      await CloudSyncManager.shared.uploadNote(note, accessToken: accessToken, userEmail: email)
    }
    dirtyNoteIDs.removeAll()
    status = .completed(transcriptsUp: 0, notesDown: dirty.count, at: Date())
  }

  func isGoogleAuthorized() -> Bool {
    let email = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)
    return email?.isEmpty == false
  }

  func syncTranscripts(_ transcripts: [Transcript]) async {
    status = .syncing
    guard let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else {
      status = .failed("Not signed in to Google.")
      return
    }

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
    self.cloudNotes = filteredNotes
    self.lastSyncNotesCount = filteredNotes.count

    // Fetch photo manifests + download any photos we don't have yet.
    let manifests = await CloudSyncManager.shared.fetchPhotoManifests(accessToken: accessToken, userEmail: email)
    let knownNoteIds = Set(filteredNotes.map(\.id))
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
    self.status = .completed(transcriptsUp: result.transcriptsUploaded, notesDown: filteredNotes.count, at: Date())

    syncLogger.info("macOS sync complete: \(filteredNotes.count) notes from cloud, \(result.transcriptsUploaded) transcripts uploaded, \(manifests.count) photo manifests")
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

  func deleteNoteFromCloud(id: UUID) async {
    @Shared(.hexSettings) var hexSettings: HexSettings
    guard hexSettings.cloudSyncEnabled,
          let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    let device = Host.current().localizedName ?? "Mac"
    await CloudSyncManager.shared.writeTombstone(id: id, sourceDevice: device, accessToken: accessToken, userEmail: email)
    await CloudSyncManager.shared.deleteNote(id: id, accessToken: accessToken, userEmail: email)
    syncLogger.info("Deleted note \(id) from cloud with tombstone")
  }

  func uploadTranscript(_ transcript: Transcript) async {
    guard let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return }

    let syncable = SyncableTranscript(
      id: transcript.id,
      text: transcript.text,
      timestamp: transcript.timestamp,
      duration: transcript.duration,
      sourceAppBundleID: transcript.sourceAppBundleID,
      sourceAppName: transcript.sourceAppName,
      sourceDevice: Host.current().localizedName ?? "Mac",
      sourcePlatform: .macOS
    )

    await CloudSyncManager.shared.uploadTranscript(syncable, accessToken: accessToken, userEmail: email)
  }

  func fetchCloudNotes() async -> [SyncableNote] {
    guard let accessToken = await getAccessToken(),
          let email = getUserEmail()
    else { return [] }

    let notes = await CloudSyncManager.shared.fetchNotes(accessToken: accessToken, userEmail: email)
    self.cloudNotes = notes
    return notes
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
