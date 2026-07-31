import Foundation
import os

private let syncLogger = Logger(subsystem: "com.joevasquez.Quill", category: "cloudSync")

public actor CloudSyncManager {
  public static let shared = CloudSyncManager()

  private let firestore = FirestoreClient()
  private let storage = CloudStorageClient()
  private var isSyncing = false

  private init() {}

  // MARK: - Notes

  public func uploadNote(_ note: SyncableNote, accessToken: String, userEmail: String) async {
    do {
      try await firestore.uploadNote(note, userEmail: userEmail, accessToken: accessToken)
    } catch {
      lastError = error.localizedDescription
      syncLogger.error("Failed to upload note: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func uploadNotes(_ notes: [SyncableNote], accessToken: String, userEmail: String) async {
    for note in notes {
      await uploadNote(note, accessToken: accessToken, userEmail: userEmail)
    }
  }

  public func fetchNotes(accessToken: String, userEmail: String) async -> [SyncableNote] {
    do {
      return try await firestore.fetchNotes(userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Failed to fetch notes: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  public func deleteNote(id: UUID, accessToken: String, userEmail: String) async {
    do {
      try await firestore.deleteNote(id: id, userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Failed to delete note from cloud: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Photos

  public func uploadPhoto(
    noteId: UUID,
    photoId: UUID,
    data: Data,
    sourceDevice: String,
    accessToken: String,
    userEmail: String
  ) async {
    let path = CloudPhotoPath.jpeg(userEmail: userEmail, noteId: noteId, photoId: photoId)
    do {
      try await storage.uploadObject(objectPath: path, data: data, contentType: "image/jpeg", accessToken: accessToken)
      let manifest = PhotoManifest(
        noteId: noteId,
        photoId: photoId,
        gcsPath: path,
        contentLength: data.count,
        sourceDevice: sourceDevice
      )
      try await firestore.uploadPhotoManifest(manifest, userEmail: userEmail, accessToken: accessToken)
      syncLogger.info("Uploaded photo \(photoId.uuidString, privacy: .public) (\(data.count) bytes)")
    } catch {
      syncLogger.error("Photo upload failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func downloadPhoto(manifest: PhotoManifest, accessToken: String) async -> Data? {
    do {
      return try await storage.downloadObject(objectPath: manifest.gcsPath, accessToken: accessToken)
    } catch {
      syncLogger.error("Photo download failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  public func fetchPhotoManifests(accessToken: String, userEmail: String) async -> [PhotoManifest] {
    do {
      return try await firestore.fetchPhotoManifests(userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Photo manifest fetch failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  public func deletePhoto(noteId: UUID, photoId: UUID, accessToken: String, userEmail: String) async {
    let path = CloudPhotoPath.jpeg(userEmail: userEmail, noteId: noteId, photoId: photoId)
    do {
      try await storage.deleteObject(objectPath: path, accessToken: accessToken)
      try await firestore.deletePhotoManifest(photoId: photoId, userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Photo delete failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Tombstones

  public func writeTombstone(id: UUID, sourceDevice: String, accessToken: String, userEmail: String) async {
    let tomb = SyncTombstone(id: id, sourceDevice: sourceDevice)
    do {
      try await firestore.writeTombstone(tomb, userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Failed to write tombstone: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func fetchTombstones(accessToken: String, userEmail: String) async -> [SyncTombstone] {
    do {
      return try await firestore.fetchTombstones(userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Failed to fetch tombstones: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  // MARK: - Transcripts

  /// Why the most recent write failed, if it did. Sync methods swallow
  /// errors so one bad record can't abort a batch — this is how the UI
  /// still learns that nothing is reaching the cloud.
  public private(set) var lastError: String?

  public func clearLastError() { lastError = nil }

  public func uploadTranscript(_ transcript: SyncableTranscript, accessToken: String, userEmail: String) async {
    do {
      try await firestore.uploadTranscript(transcript, userEmail: userEmail, accessToken: accessToken)
    } catch {
      lastError = error.localizedDescription
      syncLogger.error("Failed to upload transcript: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func fetchTranscripts(accessToken: String, userEmail: String) async -> [SyncableTranscript] {
    do {
      return try await firestore.fetchTranscripts(userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Failed to fetch transcripts: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  public func deleteTranscript(id: UUID, accessToken: String, userEmail: String) async {
    do {
      try await firestore.deleteTranscript(id: id, userEmail: userEmail, accessToken: accessToken)
    } catch {
      syncLogger.error("Failed to delete transcript from cloud: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Full sync

  public struct SyncResult: Sendable {
    public let notesFromCloud: [SyncableNote]
    public let transcriptsFromCloud: [SyncableTranscript]
    public let notesUploaded: Int
    public let transcriptsUploaded: Int
  }

  public func fullSync(
    localNotes: [SyncableNote],
    localTranscripts: [SyncableTranscript],
    accessToken: String,
    userEmail: String
  ) async -> SyncResult {
    guard !isSyncing else {
      syncLogger.info("Sync already in progress, skipping")
      return SyncResult(notesFromCloud: [], transcriptsFromCloud: [], notesUploaded: 0, transcriptsUploaded: 0)
    }
    isSyncing = true
    defer { isSyncing = false }

    syncLogger.info("Starting full sync for \(userEmail, privacy: .private)")

    let cloudNotes = await fetchNotes(accessToken: accessToken, userEmail: userEmail)
    let cloudTranscripts = await fetchTranscripts(accessToken: accessToken, userEmail: userEmail)

    let notesToUpload = localNotes.filter { local in
      if let cloud = cloudNotes.first(where: { $0.id == local.id }) {
        return local.updatedAt > cloud.updatedAt
      }
      return true
    }

    for note in notesToUpload {
      await uploadNote(note, accessToken: accessToken, userEmail: userEmail)
    }

    let cloudTranscriptIDs = Set(cloudTranscripts.map(\.id))
    let localTranscriptIDs = Set(localTranscripts.map(\.id))
    let transcriptsToUpload = localTranscripts.filter { !cloudTranscriptIDs.contains($0.id) }

    for transcript in transcriptsToUpload {
      await uploadTranscript(transcript, accessToken: accessToken, userEmail: userEmail)
    }

    let newCloudNotes = cloudNotes.filter { cloud in
      !localNotes.contains(where: { $0.id == cloud.id && $0.updatedAt >= cloud.updatedAt })
    }
    let newCloudTranscripts = cloudTranscripts.filter { !localTranscriptIDs.contains($0.id) }

    syncLogger.info("Sync complete: \(notesToUpload.count) notes up, \(newCloudNotes.count) notes down, \(transcriptsToUpload.count) transcripts up, \(newCloudTranscripts.count) transcripts down")

    return SyncResult(
      notesFromCloud: newCloudNotes,
      transcriptsFromCloud: newCloudTranscripts,
      notesUploaded: notesToUpload.count,
      transcriptsUploaded: transcriptsToUpload.count
    )
  }
}
