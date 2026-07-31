#if os(macOS)
import AppKit
import Foundation
import HexCore
import os

private let photoLogger = Logger(subsystem: "com.joevasquez.Quill", category: "macPhotos")

/// Read-mostly local cache of photos downloaded from cloud (originating
/// on iOS). Lives at `~/Library/Application Support/com.joevasquez.Quill/SyncedPhotos/{noteId}/{photoId}.jpg`.
/// Mirrors iOS `PhotoStore`'s on-disk shape so the path math is symmetric
/// and a future "edit on Mac" extension can reuse the same layout.
@MainActor
final class MacPhotoStore: ObservableObject {
  static let shared = MacPhotoStore()

  /// Bumped on every cache mutation so SwiftUI views re-read the disk —
  /// `image(noteID:photoID:)` is a plain file read, so observation alone
  /// would never notice a newly-downloaded photo.
  @Published private(set) var revision = 0

  private let rootURL: URL

  private init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let containerName = Bundle.main.bundleIdentifier ?? "com.joevasquez.Quill"
    self.rootURL = support
      .appendingPathComponent(containerName, isDirectory: true)
      .appendingPathComponent("SyncedPhotos", isDirectory: true)
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  func url(noteID: UUID, photoID: UUID) -> URL {
    rootURL
      .appendingPathComponent(noteID.uuidString, isDirectory: true)
      .appendingPathComponent("\(photoID.uuidString).jpg")
  }

  func hasPhoto(noteID: UUID, photoID: UUID) -> Bool {
    FileManager.default.fileExists(atPath: url(noteID: noteID, photoID: photoID).path)
  }

  func image(noteID: UUID, photoID: UUID) -> NSImage? {
    NSImage(contentsOf: url(noteID: noteID, photoID: photoID))
  }

  /// Save a downloaded JPEG to the cache. Creates the per-note directory
  /// on demand. Atomic write so a crash mid-write doesn't leave a torn file.
  func save(data: Data, noteID: UUID, photoID: UUID) throws {
    let dir = rootURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let target = dir.appendingPathComponent("\(photoID.uuidString).jpg")
    try data.write(to: target, options: [.atomic])
    revision += 1
    photoLogger.info("Cached photo \(photoID.uuidString, privacy: .public) (\(data.count) bytes)")
  }

  func deleteAllPhotos(noteID: UUID) {
    let dir = rootURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    revision += 1
  }
}
#endif
