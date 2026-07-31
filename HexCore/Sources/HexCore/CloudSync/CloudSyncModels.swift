import Foundation

// MARK: - Syncable note (cross-platform)

public struct SyncableNote: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var body: String
  public var createdAt: Date
  public var updatedAt: Date
  public var latitude: Double?
  public var longitude: Double?
  public var placeName: String?
  public var isAutoTitle: Bool
  public var sourceDevice: String
  public var sourcePlatform: SyncPlatform

  public init(
    id: UUID,
    title: String,
    body: String,
    createdAt: Date,
    updatedAt: Date,
    latitude: Double? = nil,
    longitude: Double? = nil,
    placeName: String? = nil,
    isAutoTitle: Bool = false,
    sourceDevice: String,
    sourcePlatform: SyncPlatform
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.latitude = latitude
    self.longitude = longitude
    self.placeName = placeName
    self.isAutoTitle = isAutoTitle
    self.sourceDevice = sourceDevice
    self.sourcePlatform = sourcePlatform
  }
}

// MARK: - Syncable transcript (cross-platform)

public struct SyncableTranscript: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var text: String
  public var timestamp: Date
  public var duration: TimeInterval
  public var sourceAppBundleID: String?
  public var sourceAppName: String?
  public var sourceDevice: String
  public var sourcePlatform: SyncPlatform

  public init(
    id: UUID,
    text: String,
    timestamp: Date,
    duration: TimeInterval,
    sourceAppBundleID: String? = nil,
    sourceAppName: String? = nil,
    sourceDevice: String,
    sourcePlatform: SyncPlatform
  ) {
    self.id = id
    self.text = text
    self.timestamp = timestamp
    self.duration = duration
    self.sourceAppBundleID = sourceAppBundleID
    self.sourceAppName = sourceAppName
    self.sourceDevice = sourceDevice
    self.sourcePlatform = sourcePlatform
  }
}

// MARK: - Tombstone (delete propagation)

public struct SyncTombstone: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var deletedAt: Date
  public var sourceDevice: String

  public init(id: UUID, deletedAt: Date = Date(), sourceDevice: String) {
    self.id = id
    self.deletedAt = deletedAt
    self.sourceDevice = sourceDevice
  }
}

// MARK: - Helpers

public enum SyncPlatform: String, Codable, Sendable {
  case macOS
  case iOS
}

public enum CloudSyncConstants {
  public static let gcpProjectID = "quill-495210"
  public static let firestoreScope = "https://www.googleapis.com/auth/datastore"
  /// Was `quill-db` until 2026-07-31. That database was destroyed when the
  /// GCP project was deleted; undeleting the project restored the metadata
  /// record but not the data, leaving the ID tombstoned — `delete` returns
  /// NOT_FOUND while `create` returns ALREADY_EXISTS, so the name can never
  /// be used again. Deleting a Firestore database permanently burns its ID:
  /// if this one ever has to be replaced, pick another new name here rather
  /// than trying to recreate it.
  public static let firestoreDatabaseID = "quill-sync"
  public static let cloudSyncEnabledKey = "quill.cloudSyncEnabled"
  public static let gcsBucket = "quill-49521-notes"
  public static let photoStorageScope = "https://www.googleapis.com/auth/devstorage.read_write"
}

// MARK: - Photo manifest

/// Tells receiving devices which photos belong to which note + where to
/// find them in GCS. Written to Firestore at `users/{email}/photoManifests/{photoId}`
/// after the JPEG has been uploaded successfully.
public struct PhotoManifest: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID { photoId }
  public var noteId: UUID
  public var photoId: UUID
  public var gcsPath: String
  public var contentLength: Int
  public var uploadedAt: Date
  public var sourceDevice: String

  public init(
    noteId: UUID,
    photoId: UUID,
    gcsPath: String,
    contentLength: Int,
    uploadedAt: Date = Date(),
    sourceDevice: String
  ) {
    self.noteId = noteId
    self.photoId = photoId
    self.gcsPath = gcsPath
    self.contentLength = contentLength
    self.uploadedAt = uploadedAt
    self.sourceDevice = sourceDevice
  }
}
