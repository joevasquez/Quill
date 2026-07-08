import ComposableArchitecture
import Foundation
import HexCore

private let actionLogger = HexLog.action

@Reducer
struct MultiActionConfirmationFeature {
  @ObservableState
  struct State: Equatable {
    var rawTranscript: String
    var items: IdentifiedArrayOf<ActionItemState>
    var availableIntegrations: [Integration.Identifier] = []
    var isExecuting: Bool = false
    var results: [UUID: ItemResult] = [:]
    var completion: Completion?
    /// Routine trust ladder: when true (auto-run routine), execution starts
    /// on appear — the panel becomes a progress display instead of a prompt.
    var autoExecute: Bool = false

    struct ActionItemState: Equatable, Identifiable {
      let id: UUID
      var intent: ActionIntent
      var editableTitle: String
      var editableDueDate: String
      var editableNotes: String
      var selectedList: String
      var editablePriority: Int
      var editableRecipient: String
      var editableSubject: String
      var editableBody: String
      var editableAttendees: String
      var editableStartDate: Date
      var editableEndDate: Date
      var availableLists: [String] = []
      var isExpanded: Bool = false

      init(intent: ActionIntent) {
        self.id = UUID()
        self.intent = intent
        self.editableTitle = intent.title
        self.editableDueDate = intent.dueDate ?? ""
        self.editableNotes = intent.notes ?? ""
        self.selectedList = intent.listName ?? ""
        self.editablePriority = intent.priority ?? 0
        self.editableRecipient = intent.recipient ?? ""
        self.editableSubject = intent.subject ?? intent.title
        self.editableBody = intent.notes ?? ""
        self.editableAttendees = intent.attendees?.joined(separator: ", ") ?? ""

        let parsedStart = (intent.dueDate.flatMap { parseDateAndTime($0) }) ?? Self.defaultEventStart()
        let minutes = intent.duration ?? 60
        self.editableStartDate = parsedStart
        self.editableEndDate = parsedStart.addingTimeInterval(Double(minutes) * 60)
      }

      private static func defaultEventStart() -> Date {
        let cal = Calendar.current
        let now = Date()
        let components = cal.dateComponents([.year, .month, .day, .hour], from: now)
        let topOfHour = cal.date(from: components) ?? now
        return cal.date(byAdding: .hour, value: 1, to: topOfHour) ?? now
      }

      var displayTitle: String {
        if intent.targetIntegration == .gmail, !editableSubject.isEmpty {
          return editableSubject
        }
        return editableTitle.isEmpty ? "(untitled)" : editableTitle
      }

      var displaySubtitle: String {
        if intent.actionType == .mcpCall {
          let server = intent.mcpServerName ?? "MCP"
          let tool = intent.mcpTool ?? "tool"
          return "\(server) · \(tool)"
        }
        switch intent.targetIntegration {
        case .calendar, .googleCalendar:
          let formatter = DateFormatter()
          formatter.dateStyle = .medium
          formatter.timeStyle = .short
          return formatter.string(from: editableStartDate)
        case .gmail:
          return editableRecipient.isEmpty ? "Draft" : "To: \(editableRecipient)"
        default:
          if !editableDueDate.isEmpty { return editableDueDate }
          return selectedList.isEmpty ? "No date" : selectedList
        }
      }

      func buildFinalIntent() -> ActionIntent {
        var final = intent
        // MCP calls pass through untouched — their arguments aren't
        // editable in the panel and the per-integration coercions below
        // would misapply (e.g. forcing actionType to .createEvent).
        if intent.actionType == .mcpCall {
          final.title = editableTitle
          return final
        }
        final.title = editableTitle
        final.dueDate = editableDueDate.isEmpty ? nil : editableDueDate
        final.notes = editableNotes.isEmpty ? nil : editableNotes
        final.listName = selectedList.isEmpty ? nil : selectedList
        final.priority = editablePriority == 0 ? nil : editablePriority
        if intent.targetIntegration == .calendar || intent.targetIntegration == .googleCalendar {
          final.actionType = .createEvent
          final.startDate = editableStartDate
          final.endDate = editableEndDate
          let emails = editableAttendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
          final.attendees = emails.isEmpty ? nil : emails
        }
        if intent.targetIntegration == .gmail {
          final.actionType = .createDraft
          final.recipient = editableRecipient.isEmpty ? nil : editableRecipient
          final.subject = editableSubject.isEmpty ? nil : editableSubject
          final.notes = editableBody.isEmpty ? nil : editableBody
        }
        return final
      }
    }

    enum ItemResult: Equatable {
      case succeeded(String)
      case failed(String)
      case queued
    }

    struct Completion: Equatable {
      let succeeded: Int
      let failed: Int
      let queued: Int
      /// Distinct error messages for the failed items, shown on the badge
      /// so the user sees *why* something failed (e.g. MCP auth).
      var failureReasons: [String] = []
      /// Text results worth showing the user — e.g. what an MCP read/query
      /// tool returned. Also copied to the clipboard.
      var outputs: [Output] = []

      struct Output: Equatable {
        let title: String
        let text: String
      }
    }

    init(intents: [ActionIntent], rawTranscript: String, autoExecute: Bool = false) {
      self.rawTranscript = rawTranscript
      self.items = IdentifiedArrayOf(uniqueElements: intents.map { ActionItemState(intent: $0) })
      self.autoExecute = autoExecute
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case integrationsLoaded([Integration.Identifier])
    case toggleExpanded(UUID)
    case removeItem(UUID)
    case executeAll
    case copyOutput
    case itemResult(UUID, State.ItemResult)
    case completionDismissed
    case cancel
  }

  @Dependency(\.reminders) var reminders
  @Dependency(\.todoist) var todoist
  @Dependency(\.calendarAdapter) var calendarAdapter
  @Dependency(\.gmailAdapter) var gmailAdapter
  @Dependency(\.googleCalendarAdapter) var googleCalendarAdapter
  @Dependency(\.googleOAuth) var googleOAuth
  @Dependency(\.keychain) var keychain
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.pasteboard) var pasteboard

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        let shouldAutoExecute = state.autoExecute && !state.isExecuting && state.results.isEmpty
        let loadIntegrations: Effect<Action> = .run { [googleOAuth, keychain] send in
          let connected = IntegrationConnectionStore.decode(
            UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey)
          )
          var available: [Integration.Identifier] = [.appleReminders, .calendar]
          if connected.contains(.todoist),
             let token = await keychain.read(KeychainKey.todoistAPIToken),
             !token.isEmpty {
            available.append(.todoist)
          }
          if await googleOAuth.isAuthorized() {
            if connected.contains(.googleCalendar) { available.append(.googleCalendar) }
            if connected.contains(.gmail) { available.append(.gmail) }
          }
          await send(.integrationsLoaded(available))
        }
        return shouldAutoExecute ? .merge(loadIntegrations, .send(.executeAll)) : loadIntegrations

      case let .integrationsLoaded(integrations):
        state.availableIntegrations = integrations
        return .none

      case let .toggleExpanded(id):
        state.items[id: id]?.isExpanded.toggle()
        return .none

      case let .removeItem(id):
        state.items.remove(id: id)
        if state.items.isEmpty {
          return .run { _ in
            NotificationCenter.default.post(name: .actionConfirmationCancelled, object: nil)
          }
        }
        return .none

      case .executeAll:
        state.isExecuting = true
        let itemsSnapshot = state.items.elements
        return .run { [todoist, reminders, calendarAdapter, gmailAdapter, googleCalendarAdapter] send in
          await withTaskGroup(of: (UUID, State.ItemResult).self) { group in
            for item in itemsSnapshot {
              group.addTask {
                let finalIntent = item.buildFinalIntent()
                let integration = finalIntent.targetIntegration
                do {
                  let id: String
                  if finalIntent.actionType == .mcpCall {
                    id = try await MCPActionExecutor.execute(finalIntent)
                  } else {
                    switch integration {
                    case .todoist:
                      id = try await todoist.createTask(finalIntent)
                    case .appleReminders:
                      id = try await reminders.createReminder(finalIntent)
                    case .calendar:
                      id = try await calendarAdapter.createEvent(finalIntent)
                    case .gmail:
                      id = try await gmailAdapter.createDraft(finalIntent)
                    case .googleCalendar:
                      id = try await googleCalendarAdapter.createEvent(finalIntent)
                    default:
                      throw ActionConfirmationError.unsupportedIntegration(integration)
                    }
                  }
                  return (item.id, .succeeded(id))
                } catch {
                  if QueueableErrorClassifier.isQueueable(error) {
                    await ActionQueueManager.shared.enqueue(finalIntent, lastError: error.localizedDescription)
                    return (item.id, .queued)
                  }
                  return (item.id, .failed(error.localizedDescription))
                }
              }
            }
            for await (itemID, result) in group {
              await send(.itemResult(itemID, result))
            }
          }
        }

      case let .itemResult(id, result):
        state.results[id] = result
        if state.results.count == state.items.count {
          state.isExecuting = false
          let succeeded = state.results.values.filter { if case .succeeded = $0 { return true }; return false }.count
          let failed = state.results.values.filter { if case .failed = $0 { return true }; return false }.count
          let queued = state.results.values.filter { if case .queued = $0 { return true }; return false }.count
          // Collect distinct failure reasons + MCP read/query outputs,
          // preserving item order.
          var reasons: [String] = []
          var outputs: [State.Completion.Output] = []
          for item in state.items {
            switch state.results[item.id] {
            case let .failed(msg):
              if !reasons.contains(msg) { reasons.append(msg) }
            case let .succeeded(text):
              // MCP tools return meaningful text (a query answer); native
              // adapters return an item id, which isn't worth showing.
              if item.intent.actionType == .mcpCall, !text.isEmpty, text != "Done" {
                outputs.append(.init(title: item.displayTitle, text: text))
              }
            default:
              break
            }
          }
          soundEffect.play(failed > 0 ? .cancel : .pasteTranscript)
          state.completion = .init(
            succeeded: succeeded, failed: failed, queued: queued,
            failureReasons: reasons, outputs: outputs
          )
          actionLogger.info("Multi-action complete: \(succeeded) succeeded, \(failed) failed, \(queued) queued, \(outputs.count) output(s)")

          // Auto-dismiss only when there's nothing to read (no failures and
          // no output). Otherwise keep the panel up until the user dismisses
          // (the output has an explicit Copy button).
          guard failed == 0, outputs.isEmpty else { return .none }
          return .run { send in
            try? await Task.sleep(for: .milliseconds(1800))
            await send(.completionDismissed)
          }
        }
        return .none

      case .copyOutput:
        let text = (state.completion?.outputs ?? []).map(\.text).joined(separator: "\n\n")
        guard !text.isEmpty else { return .none }
        return .run { [pasteboard] _ in await pasteboard.copy(text) }

      case .completionDismissed:
        return .run { _ in
          NotificationCenter.default.post(name: .actionConfirmationExecuted, object: nil)
        }

      case .cancel:
        soundEffect.play(.cancel)
        return .run { _ in
          NotificationCenter.default.post(name: .actionConfirmationCancelled, object: nil)
        }
      }
    }
  }
}
