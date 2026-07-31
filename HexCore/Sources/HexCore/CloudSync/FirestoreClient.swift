import Foundation
import os

private let syncLogger = Logger(subsystem: "com.joevasquez.Quill", category: "cloudSync")

public actor FirestoreClient {
  private let projectID: String
  private let baseURL: String

  public init(projectID: String = CloudSyncConstants.gcpProjectID, databaseID: String = CloudSyncConstants.firestoreDatabaseID) {
    self.projectID = projectID
    self.baseURL = "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/\(databaseID)/documents"
  }

  // MARK: - Notes

  public func uploadNote(_ note: SyncableNote, userEmail: String, accessToken: String) async throws {
    let path = "users/\(sanitizeEmail(userEmail))/notes/\(note.id.uuidString)"
    let fields = noteToFields(note)
    try await upsertDocument(path: path, fields: fields, accessToken: accessToken)
    syncLogger.info("Uploaded note \(note.id.uuidString, privacy: .public)")
  }

  public func fetchNotes(userEmail: String, accessToken: String) async throws -> [SyncableNote] {
    let path = "users/\(sanitizeEmail(userEmail))/notes"
    let documents = try await listDocuments(path: path, accessToken: accessToken)
    return documents.compactMap { fieldsToNote($0) }
  }

  public func deleteNote(id: UUID, userEmail: String, accessToken: String) async throws {
    let path = "users/\(sanitizeEmail(userEmail))/notes/\(id.uuidString)"
    try await deleteDocument(path: path, accessToken: accessToken)
    syncLogger.info("Deleted note \(id.uuidString, privacy: .public) from cloud")
  }

  // MARK: - Photo manifests

  public func uploadPhotoManifest(_ manifest: PhotoManifest, userEmail: String, accessToken: String) async throws {
    let path = "users/\(sanitizeEmail(userEmail))/photoManifests/\(manifest.photoId.uuidString)"
    let fields: [String: Any] = [
      "noteId": ["stringValue": manifest.noteId.uuidString],
      "photoId": ["stringValue": manifest.photoId.uuidString],
      "gcsPath": ["stringValue": manifest.gcsPath],
      "contentLength": ["integerValue": String(manifest.contentLength)],
      "uploadedAt": ["timestampValue": iso8601(manifest.uploadedAt)],
      "sourceDevice": ["stringValue": manifest.sourceDevice],
    ]
    try await upsertDocument(path: path, fields: fields, accessToken: accessToken)
    syncLogger.info("Uploaded photo manifest \(manifest.photoId.uuidString, privacy: .public)")
  }

  public func fetchPhotoManifests(userEmail: String, accessToken: String) async throws -> [PhotoManifest] {
    let path = "users/\(sanitizeEmail(userEmail))/photoManifests"
    let documents = try await listDocuments(path: path, accessToken: accessToken)
    return documents.compactMap { fields in
      guard let noteIdStr = fields["noteId"]?["stringValue"] as? String,
            let noteId = UUID(uuidString: noteIdStr),
            let photoIdStr = fields["photoId"]?["stringValue"] as? String,
            let photoId = UUID(uuidString: photoIdStr),
            let gcsPath = fields["gcsPath"]?["stringValue"] as? String,
            let uploadedStr = fields["uploadedAt"]?["timestampValue"] as? String,
            let uploadedAt = parseISO8601(uploadedStr)
      else { return nil }
      let contentLengthStr = fields["contentLength"]?["integerValue"] as? String ?? "0"
      let contentLength = Int(contentLengthStr) ?? 0
      return PhotoManifest(
        noteId: noteId,
        photoId: photoId,
        gcsPath: gcsPath,
        contentLength: contentLength,
        uploadedAt: uploadedAt,
        sourceDevice: fields["sourceDevice"]?["stringValue"] as? String ?? "unknown"
      )
    }
  }

  public func deletePhotoManifest(photoId: UUID, userEmail: String, accessToken: String) async throws {
    let path = "users/\(sanitizeEmail(userEmail))/photoManifests/\(photoId.uuidString)"
    try await deleteDocument(path: path, accessToken: accessToken)
  }

  // MARK: - Tombstones

  public func writeTombstone(_ tomb: SyncTombstone, userEmail: String, accessToken: String) async throws {
    let path = "users/\(sanitizeEmail(userEmail))/tombstones/\(tomb.id.uuidString)"
    let fields: [String: Any] = [
      "id": ["stringValue": tomb.id.uuidString],
      "deletedAt": ["timestampValue": iso8601(tomb.deletedAt)],
      "sourceDevice": ["stringValue": tomb.sourceDevice],
    ]
    try await upsertDocument(path: path, fields: fields, accessToken: accessToken)
    syncLogger.info("Wrote tombstone \(tomb.id.uuidString, privacy: .public)")
  }

  public func fetchTombstones(userEmail: String, accessToken: String) async throws -> [SyncTombstone] {
    let path = "users/\(sanitizeEmail(userEmail))/tombstones"
    let documents = try await listDocuments(path: path, accessToken: accessToken)
    return documents.compactMap { fields in
      guard let idStr = fields["id"]?["stringValue"] as? String,
            let id = UUID(uuidString: idStr),
            let deletedStr = fields["deletedAt"]?["timestampValue"] as? String,
            let deletedAt = parseISO8601(deletedStr)
      else { return nil }
      return SyncTombstone(
        id: id,
        deletedAt: deletedAt,
        sourceDevice: fields["sourceDevice"]?["stringValue"] as? String ?? "unknown"
      )
    }
  }

  // MARK: - Transcripts

  public func uploadTranscript(_ transcript: SyncableTranscript, userEmail: String, accessToken: String) async throws {
    let path = "users/\(sanitizeEmail(userEmail))/transcripts/\(transcript.id.uuidString)"
    let fields = transcriptToFields(transcript)
    try await upsertDocument(path: path, fields: fields, accessToken: accessToken)
    syncLogger.info("Uploaded transcript \(transcript.id.uuidString, privacy: .public)")
  }

  public func fetchTranscripts(userEmail: String, accessToken: String) async throws -> [SyncableTranscript] {
    let path = "users/\(sanitizeEmail(userEmail))/transcripts"
    let documents = try await listDocuments(path: path, accessToken: accessToken)
    return documents.compactMap { fieldsToTranscript($0) }
  }

  public func deleteTranscript(id: UUID, userEmail: String, accessToken: String) async throws {
    let path = "users/\(sanitizeEmail(userEmail))/transcripts/\(id.uuidString)"
    try await deleteDocument(path: path, accessToken: accessToken)
    syncLogger.info("Deleted transcript \(id.uuidString, privacy: .public) from cloud")
  }

  // MARK: - REST API

  private func upsertDocument(path: String, fields: [String: Any], accessToken: String) async throws {
    let url = URL(string: "\(baseURL)/\(path)")!
    var request = URLRequest(url: url)
    request.httpMethod = "PATCH"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30

    let body: [String: Any] = ["fields": fields]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      syncLogger.error("Firestore PATCH failed: HTTP \(code, privacy: .public) [\(GoogleAPIError.describe(data), privacy: .public)] path=\(path, privacy: .public)")
      throw CloudSyncError.uploadFailed(code, reason: GoogleAPIError.reason(data))
    }
  }

  private func listDocuments(path: String, accessToken: String) async throws -> [[String: [String: Any]]] {
    var allDocuments: [[String: [String: Any]]] = []
    var pageToken: String?

    repeat {
      var urlString = "\(baseURL)/\(path)?pageSize=300"
      if let token = pageToken {
        urlString += "&pageToken=\(token)"
      }
      let url = URL(string: urlString)!
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
      request.timeoutInterval = 30

      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        syncLogger.error("Firestore GET failed: HTTP \(code, privacy: .public) [\(GoogleAPIError.describe(data), privacy: .public)] path=\(path, privacy: .public)")
        throw CloudSyncError.fetchFailed(code)
      }

      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        break
      }

      if let documents = json["documents"] as? [[String: Any]] {
        for doc in documents {
          if let fields = doc["fields"] as? [String: [String: Any]] {
            allDocuments.append(fields)
          }
        }
      }

      pageToken = json["nextPageToken"] as? String
    } while pageToken != nil

    return allDocuments
  }

  private func deleteDocument(path: String, accessToken: String) async throws {
    let url = URL(string: "\(baseURL)/\(path)")!
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw CloudSyncError.deleteFailed(code)
    }
  }

  // MARK: - Field encoding (Note)

  private func noteToFields(_ note: SyncableNote) -> [String: Any] {
    var fields: [String: Any] = [
      "id": ["stringValue": note.id.uuidString],
      "title": ["stringValue": note.title],
      "body": ["stringValue": note.body],
      "createdAt": ["timestampValue": iso8601(note.createdAt)],
      "updatedAt": ["timestampValue": iso8601(note.updatedAt)],
      "isAutoTitle": ["booleanValue": note.isAutoTitle],
      "sourceDevice": ["stringValue": note.sourceDevice],
      "sourcePlatform": ["stringValue": note.sourcePlatform.rawValue],
    ]
    if let lat = note.latitude {
      fields["latitude"] = ["doubleValue": lat]
    }
    if let lng = note.longitude {
      fields["longitude"] = ["doubleValue": lng]
    }
    if let place = note.placeName {
      fields["placeName"] = ["stringValue": place]
    }
    return fields
  }

  private func fieldsToNote(_ fields: [String: [String: Any]]) -> SyncableNote? {
    guard let idStr = fields["id"]?["stringValue"] as? String,
          let id = UUID(uuidString: idStr),
          let title = fields["title"]?["stringValue"] as? String,
          let body = fields["body"]?["stringValue"] as? String,
          let createdStr = fields["createdAt"]?["timestampValue"] as? String,
          let updatedStr = fields["updatedAt"]?["timestampValue"] as? String,
          let createdAt = parseISO8601(createdStr),
          let updatedAt = parseISO8601(updatedStr)
    else { return nil }

    return SyncableNote(
      id: id,
      title: title,
      body: body,
      createdAt: createdAt,
      updatedAt: updatedAt,
      latitude: fields["latitude"]?["doubleValue"] as? Double,
      longitude: fields["longitude"]?["doubleValue"] as? Double,
      placeName: fields["placeName"]?["stringValue"] as? String,
      isAutoTitle: fields["isAutoTitle"]?["booleanValue"] as? Bool ?? false,
      sourceDevice: fields["sourceDevice"]?["stringValue"] as? String ?? "unknown",
      sourcePlatform: SyncPlatform(rawValue: fields["sourcePlatform"]?["stringValue"] as? String ?? "") ?? .iOS
    )
  }

  // MARK: - Field encoding (Transcript)

  private func transcriptToFields(_ t: SyncableTranscript) -> [String: Any] {
    var fields: [String: Any] = [
      "id": ["stringValue": t.id.uuidString],
      "text": ["stringValue": t.text],
      "timestamp": ["timestampValue": iso8601(t.timestamp)],
      "duration": ["doubleValue": t.duration],
      "sourceDevice": ["stringValue": t.sourceDevice],
      "sourcePlatform": ["stringValue": t.sourcePlatform.rawValue],
    ]
    if let bid = t.sourceAppBundleID {
      fields["sourceAppBundleID"] = ["stringValue": bid]
    }
    if let name = t.sourceAppName {
      fields["sourceAppName"] = ["stringValue": name]
    }
    return fields
  }

  private func fieldsToTranscript(_ fields: [String: [String: Any]]) -> SyncableTranscript? {
    guard let idStr = fields["id"]?["stringValue"] as? String,
          let id = UUID(uuidString: idStr),
          let text = fields["text"]?["stringValue"] as? String,
          let tsStr = fields["timestamp"]?["timestampValue"] as? String,
          let timestamp = parseISO8601(tsStr),
          let duration = fields["duration"]?["doubleValue"] as? Double
    else { return nil }

    return SyncableTranscript(
      id: id,
      text: text,
      timestamp: timestamp,
      duration: duration,
      sourceAppBundleID: fields["sourceAppBundleID"]?["stringValue"] as? String,
      sourceAppName: fields["sourceAppName"]?["stringValue"] as? String,
      sourceDevice: fields["sourceDevice"]?["stringValue"] as? String ?? "unknown",
      sourcePlatform: SyncPlatform(rawValue: fields["sourcePlatform"]?["stringValue"] as? String ?? "") ?? .macOS
    )
  }

  // MARK: - Helpers

  private func sanitizeEmail(_ email: String) -> String {
    email.replacingOccurrences(of: ".", with: "_")
         .replacingOccurrences(of: "@", with: "_at_")
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private func parseISO8601(_ string: String) -> Date? {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}

// MARK: - Errors

public enum CloudSyncError: LocalizedError {
  case uploadFailed(Int, reason: String? = nil)
  case fetchFailed(Int)
  case deleteFailed(Int)
  case notAuthenticated
  case syncDisabled

  public var errorDescription: String? {
    switch self {
    case .uploadFailed(let code, let reason):
      GoogleAPIError.userFacingMessage(status: code, reason: reason)
        ?? "Cloud sync upload failed (HTTP \(code))"
    case .fetchFailed(let code): "Cloud sync fetch failed (HTTP \(code))"
    case .deleteFailed(let code): "Cloud sync delete failed (HTTP \(code))"
    case .notAuthenticated: "Not signed in to Google — connect in Settings."
    case .syncDisabled: "Cloud sync is not enabled."
    }
  }
}

/// Decodes Google's standard JSON error envelope so failures are
/// diagnosable from a log line instead of a bare status code. A 403 can
/// mean a missing scope, a disabled API, or an invalid project (billing) —
/// which are very different problems with the same status.
public enum GoogleAPIError {
  /// `reason` from the first `ErrorInfo` detail, e.g. `CONSUMER_INVALID`,
  /// `SERVICE_DISABLED`, `ACCESS_TOKEN_SCOPE_INSUFFICIENT`.
  public static func reason(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any],
          let details = error["details"] as? [[String: Any]]
    else { return nil }
    return details.compactMap { $0["reason"] as? String }.first
  }

  /// Compact "REASON: message" for logging.
  public static func describe(_ data: Data) -> String {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any]
    else { return "no error body" }
    let message = (error["message"] as? String) ?? ""
    if let reason = reason(data) { return "\(reason): \(message)" }
    return message.isEmpty ? "unknown error" : message
  }

  /// Plain-English guidance for the failure modes a user can act on.
  public static func userFacingMessage(status: Int, reason: String?) -> String? {
    switch reason {
    case "CONSUMER_INVALID", "ACCOUNT_STATE_INVALID":
      return "Cloud sync is unavailable: the Quill cloud project is inactive (usually a billing issue). Your notes are safe on this device."
    case "SERVICE_DISABLED":
      return "Cloud sync is unavailable: the Firestore API is disabled for the Quill cloud project."
    case "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
      return "Cloud sync needs permissions your Google sign-in didn't grant. Disconnect and reconnect Google, allowing every requested permission."
    default:
      return status == 401
        ? "Google sign-in expired — reconnect in Settings."
        : nil
    }
  }
}
