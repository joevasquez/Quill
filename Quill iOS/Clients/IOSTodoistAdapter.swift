import Foundation
import HexCore

@MainActor
enum IOSTodoistAdapter {
  private static let baseURL = URL(string: "https://api.todoist.com/api/v1/")!

  static func validateToken(_ token: String) async -> (isValid: Bool, projects: [TodoistProject]) {
    do {
      let projects = try await fetchProjectsRequest(token: token)
      return (true, projects)
    } catch {
      return (false, [])
    }
  }

  static func fetchProjects() async -> [TodoistProject] {
    let (token, _) = KeychainStore.read(account: KeychainKey.todoistAPIToken)
    guard let token, !token.isEmpty else { return [] }
    return (try? await fetchProjectsRequest(token: token)) ?? []
  }

  static func createTask(_ intent: ActionIntent) async throws -> String {
    let (token, _) = KeychainStore.read(account: KeychainKey.todoistAPIToken)
    guard let token, !token.isEmpty else {
      throw IOSActionError.missingToken("Todoist")
    }

    var projectId: String?
    if let listName = intent.listName, !listName.isEmpty {
      let projects = (try? await fetchProjectsRequest(token: token)) ?? []
      if let match = projects.first(where: { $0.name.localizedCaseInsensitiveCompare(listName) == .orderedSame }) {
        projectId = match.id
      }
    }

    var request = authorizedRequest("tasks", token: token, method: "POST")
    var body: [String: Any] = ["content": intent.title]
    if let notes = intent.notes, !notes.isEmpty { body["description"] = notes }
    if let dueDate = intent.dueDate, !dueDate.isEmpty { body["due_string"] = dueDate }
    if let priority = intent.priority, (1...4).contains(priority) { body["priority"] = priority }
    if let projectId { body["project_id"] = projectId }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw IOSActionError.apiError("Todoist", code)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw IOSActionError.invalidResponse("Todoist")
    }
    if let id = json["id"] as? String { return id }
    if let n = json["id"] as? Int { return String(n) }
    throw IOSActionError.invalidResponse("Todoist")
  }

  /// Read-only snapshot of active tasks for the suggestion engine — one
  /// line per task with its due date, overdue flagged. Best-effort:
  /// returns "" when there's no token or the request fails.
  static func tasksSnapshot(limit: Int = 25) async -> String {
    let (token, _) = KeychainStore.read(account: KeychainKey.todoistAPIToken)
    guard let token, !token.isEmpty else { return "" }

    let request = authorizedRequest("tasks", token: token)
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse, http.statusCode == 200
    else { return "" }

    var tasks: [[String: Any]] = []
    if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      tasks = array
    } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = dict["results"] as? [[String: Any]] {
      tasks = results
    }
    guard !tasks.isEmpty else { return "" }

    let today = Calendar.current.startOfDay(for: Date())
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"

    // Overdue first, then dated, then undated — the interesting ones lead.
    func dueDate(_ task: [String: Any]) -> Date? {
      guard let due = task["due"] as? [String: Any],
            let dateString = due["date"] as? String
      else { return nil }
      return dayFormatter.date(from: String(dateString.prefix(10)))
    }
    let sorted = tasks.sorted { a, b in
      switch (dueDate(a), dueDate(b)) {
      case (let x?, let y?): return x < y
      case (_?, nil): return true
      default: return false
      }
    }

    let lines = sorted.prefix(limit).compactMap { task -> String? in
      guard let content = task["content"] as? String, !content.isEmpty else { return nil }
      guard let due = dueDate(task) else { return "- \(content) (no due date)" }
      let overdue = due < today ? " [OVERDUE]" : ""
      return "- \(content) (due \(dayFormatter.string(from: due)))\(overdue)"
    }
    guard !lines.isEmpty else { return "" }
    return "Active Todoist tasks:\n" + lines.joined(separator: "\n")
  }

  // MARK: - Private

  private static func authorizedRequest(_ path: String, token: String, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15
    return request
  }

  private static func fetchProjectsRequest(token: String) async throws -> [TodoistProject] {
    let request = authorizedRequest("projects", token: token)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw IOSActionError.apiError("Todoist", code)
    }

    if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      return array.compactMap(parseProject)
    }
    if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let results = dict["results"] as? [[String: Any]] {
      return results.compactMap(parseProject)
    }
    throw IOSActionError.invalidResponse("Todoist")
  }

  private static func parseProject(_ obj: [String: Any]) -> TodoistProject? {
    let id: String
    if let s = obj["id"] as? String { id = s }
    else if let n = obj["id"] as? Int { id = String(n) }
    else { return nil }
    guard let name = obj["name"] as? String else { return nil }
    return TodoistProject(id: id, name: name)
  }
}
