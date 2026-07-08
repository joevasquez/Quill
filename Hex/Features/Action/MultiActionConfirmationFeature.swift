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
    /// App frontmost at record-start; target for pasting an extracted answer.
    var sourceAppBundleID: String?
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
      /// For chained steps: the id of the sibling item this step depends on
      /// (resolved from `intent.dependsOn` in `State.init`). nil → independent.
      var dependsOnID: UUID?

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

      /// Human-readable summary of what a *created* (non-MCP) step produced,
      /// built from the item's current (possibly resolve-filled) fields — the
      /// email that was drafted, the reminder that was added, etc.
      var completionDetail: String {
        switch intent.targetIntegration {
        case .gmail:
          var lines: [String] = []
          lines.append("To: \(editableRecipient.isEmpty ? "—" : editableRecipient)")
          let subject = editableSubject.isEmpty ? editableTitle : editableSubject
          if !subject.isEmpty { lines.append("Subject: \(subject)") }
          if !editableBody.isEmpty { lines.append("\n\(editableBody)") }
          return lines.joined(separator: "\n")
        case .calendar, .googleCalendar:
          let f = DateFormatter()
          f.dateStyle = .medium
          f.timeStyle = .short
          var lines = ["\(f.string(from: editableStartDate)) – \(f.string(from: editableEndDate))"]
          if !editableAttendees.isEmpty { lines.append("With: \(editableAttendees)") }
          if !editableNotes.isEmpty { lines.append(editableNotes) }
          return lines.joined(separator: "\n")
        default:
          var lines: [String] = []
          if !editableDueDate.isEmpty { lines.append("Due: \(editableDueDate)") }
          if !selectedList.isEmpty { lines.append("List: \(selectedList)") }
          if !editableNotes.isEmpty { lines.append(editableNotes) }
          return lines.joined(separator: "\n")
        }
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
        let itemID: UUID
        let title: String
        let text: String
        /// The specific answer extracted from `text` when the request was a
        /// question ("look up Joe's email" → the email). Filled asynchronously
        /// after the panel appears; nil until then / when there's no answer.
        var answer: String?
      }

      /// The extracted answers across all outputs, joined — the value the user
      /// actually asked for. Empty when nothing was extracted.
      var combinedAnswer: String {
        outputs.compactMap(\.answer).filter { !$0.isEmpty }.joined(separator: "\n")
      }

      /// Per-step outcome shown in the panel so the user sees what each step
      /// found or created — the Dex contact that was looked up, the email that
      /// was drafted (To/Subject/Body), etc. — not just "2 created".
      var steps: [StepOutcome] = []

      struct StepOutcome: Equatable, Identifiable {
        enum Status: Equatable { case succeeded, failed, queued }
        let id: UUID
        let title: String
        let status: Status
        /// Human-readable detail: a formatted lookup result, a created item's
        /// key fields, or a failure reason.
        let detail: String
        /// Whether this outcome is worth keeping the panel open for (a lookup
        /// result, an email draft, or a failure) vs. a plain created reminder.
        let reviewable: Bool
      }

      /// Keep the panel up (don't auto-dismiss) when any step is worth reading.
      var hasReviewableStep: Bool { steps.contains { $0.reviewable } }
    }

    init(intents: [ActionIntent], rawTranscript: String, autoExecute: Bool = false, sourceAppBundleID: String? = nil) {
      self.rawTranscript = rawTranscript
      self.sourceAppBundleID = sourceAppBundleID
      var built = intents.map { ActionItemState(intent: $0) }
      // Resolve each step's `dependsOn` index into the depended-on item's id,
      // so chaining survives panel reordering/removal.
      for (i, intent) in intents.enumerated() {
        if let dep = intent.dependsOn, dep >= 0, dep < built.count, dep != i {
          built[i].dependsOnID = built[dep].id
        }
      }
      self.items = IdentifiedArrayOf(uniqueElements: built)
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
    case copyAnswer
    case pasteAnswer
    case answerExtracted(UUID, String)
    case dependentResolved(UUID, ActionIntent)
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
  @Dependency(\.actionParsing) var actionParsing

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
        let request = state.rawTranscript
        @Shared(.hexSettings) var hexSettings: HexSettings
        let provider = hexSettings.aiProvider
        return .run { [todoist, reminders, calendarAdapter, gmailAdapter, googleCalendarAdapter, actionParsing] send in
          // Runs one already-final intent, returning both the panel result and
          // the raw text output (MCP tool result / created-item id) so a
          // dependent step can consume it.
          @Sendable func execute(_ finalIntent: ActionIntent) async -> (State.ItemResult, String) {
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
              return (.succeeded(id), id)
            } catch {
              if QueueableErrorClassifier.isQueueable(error) {
                await ActionQueueManager.shared.enqueue(finalIntent, lastError: error.localizedDescription)
                return (.queued, "")
              }
              return (.failed(error.localizedDescription), "")
            }
          }

          // Each item's raw text output, keyed by id — feeds dependent steps.
          var outputs: [UUID: String] = [:]

          // Phase 1 — independent steps run concurrently, as before.
          await withTaskGroup(of: (UUID, State.ItemResult, String).self) { group in
            for item in itemsSnapshot where item.dependsOnID == nil {
              group.addTask { let (r, text) = await execute(item.buildFinalIntent()); return (item.id, r, text) }
            }
            for await (itemID, result, text) in group {
              outputs[itemID] = text
              await send(.itemResult(itemID, result))
            }
          }

          // Phase 2 — dependent steps, in panel order, one at a time. Each
          // runs an LLM resolve pass over its dependency's output before
          // executing (e.g. fill the email recipient from a lookup result).
          for item in itemsSnapshot where item.dependsOnID != nil {
            let priorText = item.dependsOnID.flatMap { outputs[$0] } ?? ""
            guard !priorText.isEmpty else {
              // The step it depends on failed or was queued — don't run a
              // half-filled action (e.g. a draft with no recipient).
              await send(.itemResult(item.id, .failed("Skipped — a step it depends on didn't complete")))
              continue
            }
            var intent = item.buildFinalIntent()
            if intent.resolveInstruction != nil {
              intent = (try? await actionParsing.resolveStep(intent, priorText, request, provider)) ?? intent
              // Reflect the resolved values (filled recipient, personalized
              // body) back into the item so the completion summary is accurate.
              await send(.dependentResolved(item.id, intent))
            }
            let (result, text) = await execute(intent)
            outputs[item.id] = text
            await send(.itemResult(item.id, result))
          }
        }

      case let .itemResult(id, result):
        state.results[id] = result
        if state.results.count == state.items.count {
          state.isExecuting = false
          let succeeded = state.results.values.filter { if case .succeeded = $0 { return true }; return false }.count
          let failed = state.results.values.filter { if case .failed = $0 { return true }; return false }.count
          let queued = state.results.values.filter { if case .queued = $0 { return true }; return false }.count
          // Producers whose output was consumed by a dependent step — their
          // raw result doesn't get a standalone answer card (the dependent
          // already used it), but it IS still shown in the step list so the
          // user sees what was found.
          let consumed = Set(state.items.compactMap(\.dependsOnID))
          // Collect distinct failure reasons, standalone MCP outputs (for the
          // answer card), and a per-step outcome list (for display). `toExtract`
          // holds the RAW result for the answer-extraction pass.
          var reasons: [String] = []
          var outputs: [State.Completion.Output] = []
          var toExtract: [(UUID, String)] = []
          var steps: [State.Completion.StepOutcome] = []
          for item in state.items {
            switch state.results[item.id] {
            case let .failed(msg):
              if !reasons.contains(msg) { reasons.append(msg) }
              steps.append(.init(id: item.id, title: item.displayTitle, status: .failed, detail: msg, reviewable: true))
            case .queued:
              steps.append(.init(id: item.id, title: item.displayTitle, status: .queued,
                                 detail: "Saved — will retry when you're back online", reviewable: true))
            case let .succeeded(text):
              if item.intent.actionType == .mcpCall {
                // Lookup/query: show the formatted result ("what was found").
                let formatted = (!text.isEmpty && text != "Done") ? MCPResultFormatter.format(text) : "Done"
                steps.append(.init(id: item.id, title: item.displayTitle, status: .succeeded, detail: formatted, reviewable: true))
                // Only a standalone (non-consumed) read gets an answer card.
                if !text.isEmpty, text != "Done", !consumed.contains(item.id) {
                  outputs.append(.init(itemID: item.id, title: item.displayTitle, text: formatted))
                  toExtract.append((item.id, text))
                }
              } else {
                // Created item: summarize what was created (email To/Subject/
                // Body, reminder date/list). Email drafts are worth reviewing.
                let isEmail = item.intent.targetIntegration == .gmail
                steps.append(.init(id: item.id, title: item.displayTitle, status: .succeeded,
                                   detail: item.completionDetail, reviewable: isEmail))
              }
            case .none:
              break
            }
          }
          soundEffect.play(failed > 0 ? .cancel : .pasteTranscript)
          state.completion = .init(
            succeeded: succeeded, failed: failed, queued: queued,
            failureReasons: reasons, outputs: outputs, steps: steps
          )
          actionLogger.info("Multi-action complete: \(succeeded) succeeded, \(failed) failed, \(queued) queued, \(outputs.count) output(s)")

          // Auto-dismiss only for trivial done-and-gone results (plain
          // reminders/tasks). Anything worth reading — a lookup result, an
          // email draft, a failure — keeps the panel up.
          if failed == 0, !(state.completion?.hasReviewableStep ?? false) {
            return .run { send in
              try? await Task.sleep(for: .milliseconds(1800))
              await send(.completionDismissed)
            }
          }
          // Panel stays open. Extract the specific answer the user asked for
          // from each standalone MCP result (best-effort, in the background).
          guard !toExtract.isEmpty else { return .none }
          let request = state.rawTranscript
          @Shared(.hexSettings) var hexSettings: HexSettings
          let provider = hexSettings.aiProvider
          return .run { [actionParsing] send in
            for (id, raw) in toExtract {
              if let answer = try? await actionParsing.extractAnswer(request, raw, provider),
                 !answer.isEmpty {
                await send(.answerExtracted(id, answer))
              }
            }
          }
        }
        return .none

      case let .answerExtracted(id, answer):
        if let index = state.completion?.outputs.firstIndex(where: { $0.itemID == id }) {
          state.completion?.outputs[index].answer = answer
        }
        return .none

      case let .dependentResolved(id, intent):
        // Reflect a resolve pass's filled/personalized fields back into the
        // item so the completion summary shows the real drafted content.
        guard var item = state.items[id: id] else { return .none }
        item.intent = intent
        item.editableTitle = intent.title
        item.editableRecipient = intent.recipient ?? item.editableRecipient
        item.editableSubject = intent.subject ?? item.editableSubject
        item.editableBody = intent.notes ?? item.editableBody
        item.editableNotes = intent.notes ?? item.editableNotes
        state.items[id: id] = item
        return .none

      case .copyAnswer:
        let answer = state.completion?.combinedAnswer ?? ""
        guard !answer.isEmpty else { return .none }
        return .run { [pasteboard] _ in await pasteboard.copy(answer) }

      case .pasteAnswer:
        let answer = state.completion?.combinedAnswer ?? ""
        guard !answer.isEmpty else { return .none }
        let bundleID = state.sourceAppBundleID
        return .run { [pasteboard] send in
          await pasteboard.paste(answer, bundleID)
          await send(.completionDismissed)
        }

      case .copyOutput:
        let text = (state.completion?.steps ?? [])
          .map { $0.detail.isEmpty ? $0.title : "\($0.title)\n\($0.detail)" }
          .joined(separator: "\n\n")
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
