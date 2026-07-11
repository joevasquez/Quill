//
//  MultiActionConfirmationSheet.swift
//  Quill (iOS)
//
//  Multi-action confirmation sheet — the iOS port of macOS's
//  `MultiActionConfirmationFeature` (ObservableObject, no TCA). Supports
//  dependent (chained) steps: phase 1 runs independent steps, phase 2 runs
//  dependents sequentially with an LLM resolve pass over the dependency's
//  output (`IOSActionParsingClient.resolveStep`), the completion screen
//  lists per-step outcomes, and a standalone MCP read/query result gets a
//  formatted card + an extracted "Answer" with a Copy button.
//

import Combine
import HexCore
import SwiftUI

extension Notification.Name {
  static let quillActionQueuedOffline = Notification.Name("quill.actionQueuedOffline")
}

@MainActor
final class MultiActionConfirmationViewModel: ObservableObject {
  @Published var rawTranscript: String = ""
  @Published var items: [ActionItemVM] = []
  @Published var isExecuting: Bool = false
  @Published var completion: Completion?
  /// True between "the sheet opened on record-stop" and "the LLM parse
  /// landed" — the sheet shows HEARD + a skeleton card. This replaces
  /// the old separate single-action parsing sheet.
  @Published var isParsing: Bool = false
  /// Routine trust ladder: when true (auto-run routine), execution starts
  /// on appear — the sheet becomes a progress display instead of a prompt.
  var autoExecute: Bool = false
  /// True when Auto routing (not the user) decided this was an action.
  /// Shows the "Save to note instead" escape hatch.
  var wasAutoRouted: Bool = false
  /// Escape hatch for auto-routed misfires: dismisses the action and
  /// appends the transcript to the active note instead.
  var onSaveToNote: (() -> Void)?

  private var results: [UUID: ItemResult] = [:]
  private var extractionTask: Task<Void, Never>?

  struct ActionItemVM: Identifiable {
    let id = UUID()
    var intent: ActionIntent
    var editableTitle: String
    var editableDueDate: String
    var editableNotes: String
    var editableRecipient: String
    var editableSubject: String
    var editableBody: String
    var editableURL: String
    var editableAppName: String
    var isExpanded: Bool = false
    /// For chained steps: the id of the sibling item this step depends on
    /// (resolved from `intent.dependsOn` in `applyParsedIntents`). nil →
    /// independent. Ids survive row removal, unlike the raw index.
    var dependsOnID: UUID?

    init(intent: ActionIntent) {
      self.intent = intent
      self.editableTitle = intent.title
      self.editableDueDate = intent.dueDate ?? ""
      self.editableNotes = intent.notes ?? ""
      self.editableRecipient = intent.recipient ?? ""
      self.editableSubject = intent.subject ?? intent.title
      self.editableBody = intent.notes ?? ""
      self.editableURL = intent.urlString ?? ""
      self.editableAppName = intent.appName ?? ""
    }

    var displayTitle: String {
      if intent.targetIntegration == .gmail, intent.actionType != .mcpCall, intent.actionType != .open,
         !editableSubject.isEmpty {
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
      if intent.actionType == .open {
        if !editableURL.isEmpty { return editableURL }
        return editableAppName.isEmpty ? "Open" : "Launch \(editableAppName)"
      }
      switch intent.targetIntegration {
      case .calendar, .googleCalendar:
        return editableDueDate.isEmpty ? "No time" : editableDueDate
      case .gmail:
        return editableRecipient.isEmpty ? "Draft" : "To: \(editableRecipient)"
      default:
        return editableDueDate.isEmpty ? "No date" : editableDueDate
      }
    }

    func buildFinalIntent() -> ActionIntent {
      var final = intent
      // MCP calls pass through untouched — their arguments aren't editable
      // in the sheet and the per-integration coercions below would misapply
      // (e.g. forcing actionType to .createDraft).
      if intent.actionType == .mcpCall {
        final.title = editableTitle
        return final
      }
      if intent.actionType == .open {
        final.title = editableTitle
        final.urlString = editableURL.isEmpty ? nil : editableURL
        final.appName = editableAppName.isEmpty ? nil : editableAppName
        return final
      }
      final.title = editableTitle
      final.dueDate = editableDueDate.isEmpty ? nil : editableDueDate
      final.notes = editableNotes.isEmpty ? nil : editableNotes
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
      if intent.actionType == .open {
        if !editableURL.isEmpty { return editableURL }
        return editableAppName.isEmpty ? "" : "Launch \(editableAppName)"
      }
      switch intent.targetIntegration {
      case .gmail:
        var lines: [String] = []
        lines.append("To: \(editableRecipient.isEmpty ? "—" : editableRecipient)")
        let subject = editableSubject.isEmpty ? editableTitle : editableSubject
        if !subject.isEmpty { lines.append("Subject: \(subject)") }
        if !editableBody.isEmpty { lines.append("\n\(editableBody)") }
        return lines.joined(separator: "\n")
      default:
        var lines: [String] = []
        if !editableDueDate.isEmpty { lines.append("Due: \(editableDueDate)") }
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
    /// Distinct error messages for the failed items.
    var failureReasons: [String] = []
    /// Standalone MCP read/query results worth showing (formatted).
    var outputs: [Output] = []
    /// Per-step outcome list — what each step found or created.
    var steps: [StepOutcome] = []

    struct Output: Equatable {
      let itemID: UUID
      let title: String
      let text: String
      /// The specific answer extracted from `text` when the request was a
      /// question. Filled asynchronously after the sheet shows completion.
      var answer: String?
    }

    struct StepOutcome: Equatable, Identifiable {
      enum Status: Equatable { case succeeded, failed, queued }
      let id: UUID
      let title: String
      let status: Status
      let detail: String
      /// Whether this outcome is worth keeping the sheet open for (a lookup
      /// result, an email draft, or a failure) vs. a plain created reminder.
      let reviewable: Bool
    }

    var combinedAnswer: String {
      outputs.compactMap(\.answer).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Keep the sheet up (don't auto-dismiss) when any step is worth reading.
    var hasReviewableStep: Bool { steps.contains { $0.reviewable } }
  }

  init() {}

  /// Opens the sheet in its parsing-skeleton state the moment recording
  /// stops — the user sees what was HEARD while the LLM works.
  func startParsing(transcript: String, wasAutoRouted: Bool = false) {
    self.rawTranscript = transcript
    self.items = []
    self.completion = nil
    self.isExecuting = false
    self.isParsing = true
    self.autoExecute = false
    self.wasAutoRouted = wasAutoRouted
    self.results = [:]
    extractionTask?.cancel()
    extractionTask = nil
  }

  func applyParsedIntents(_ intents: [ActionIntent], rawTranscript: String, autoExecute: Bool = false) {
    self.rawTranscript = rawTranscript
    // Keep `wasAutoRouted` only when this parse continues a
    // `startParsing` session; direct presentations (routine triggers)
    // reset it.
    if !isParsing { wasAutoRouted = false }
    self.isParsing = false
    var built = intents.map { ActionItemVM(intent: $0) }
    // Resolve each step's `dependsOn` index into the depended-on item's id,
    // so chaining survives row removal.
    for (i, intent) in intents.enumerated() {
      if let dep = intent.dependsOn, dep >= 0, dep < built.count, dep != i {
        built[i].dependsOnID = built[dep].id
      }
    }
    self.items = built
    self.completion = nil
    self.isExecuting = false
    self.results = [:]
    self.autoExecute = autoExecute
    extractionTask?.cancel()
    extractionTask = nil
  }

  func removeItem(at id: UUID) {
    items.removeAll { $0.id == id }
  }

  func cancelBackgroundWork() {
    extractionTask?.cancel()
    extractionTask = nil
  }

  private var provider: AIProvider {
    AIProvider(
      rawValue: UserDefaults.standard.string(forKey: QuillIOSSettingsKey.aiProvider)
        ?? QuillIOSSettingsKey.defaultProvider
    ) ?? .anthropic
  }

  func executeAll() async {
    guard !isExecuting else { return }
    isExecuting = true
    results = [:]
    let itemsSnapshot = items
    let request = rawTranscript
    let provider = provider

    // Runs one already-final intent, returning both the result and the raw
    // text output (MCP tool result / created-item summary) so a dependent
    // step can consume it. `.open` is never queued offline — a reconnect-
    // triggered Safari launch hours later would be hostile on a phone.
    func execute(_ finalIntent: ActionIntent) async -> (ItemResult, String) {
      do {
        let output = try await IOSSystemActionQueueExecutor.executeReturningOutput(finalIntent)
        return (.succeeded(output), output)
      } catch {
        if finalIntent.actionType != .open, QueueableErrorClassifier.isQueueable(error) {
          await ActionQueueManager.shared.enqueue(finalIntent, lastError: error.localizedDescription)
          return (.queued, "")
        }
        return (.failed(error.localizedDescription), "")
      }
    }

    // Each item's raw text output, keyed by id — feeds dependent steps.
    var outputs: [UUID: String] = [:]

    // Phase 1 — independent steps run concurrently.
    await withTaskGroup(of: (UUID, ItemResult, String).self) { group in
      for item in itemsSnapshot where item.dependsOnID == nil {
        let finalIntent = item.buildFinalIntent()
        let itemID = item.id
        group.addTask { @MainActor in
          let (result, text) = await execute(finalIntent)
          return (itemID, result, text)
        }
      }
      for await (itemID, result, text) in group {
        outputs[itemID] = text
        results[itemID] = result
      }
    }

    // Phase 2 — dependent steps, in sheet order, one at a time. Each runs
    // an LLM resolve pass over its dependency's output before executing
    // (e.g. fill the email recipient from a lookup result).
    for item in itemsSnapshot where item.dependsOnID != nil {
      let priorText = item.dependsOnID.flatMap { outputs[$0] } ?? ""
      guard !priorText.isEmpty else {
        // The step it depends on failed or was queued — don't run a
        // half-filled action (e.g. a draft with no recipient).
        results[item.id] = .failed("Skipped — a step it depends on didn't complete")
        continue
      }
      var intent = item.buildFinalIntent()
      if intent.resolveInstruction != nil {
        intent = (try? await IOSActionParsingClient.resolveStep(
          intent: intent, priorResult: priorText, request: request, provider: provider
        )) ?? intent
        // Reflect the resolved values (filled recipient, personalized body)
        // back into the item so the completion summary is accurate.
        applyResolvedIntent(intent, to: item.id)
      }
      let (result, text) = await execute(intent)
      outputs[item.id] = text
      results[item.id] = result
    }

    isExecuting = false
    finishExecution(request: request, provider: provider)
  }

  private func applyResolvedIntent(_ intent: ActionIntent, to id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].intent = intent
    items[index].editableTitle = intent.title
    items[index].editableRecipient = intent.recipient ?? items[index].editableRecipient
    items[index].editableSubject = intent.subject ?? items[index].editableSubject
    items[index].editableBody = intent.notes ?? items[index].editableBody
    items[index].editableNotes = intent.notes ?? items[index].editableNotes
  }

  private func finishExecution(request: String, provider: AIProvider) {
    let succeeded = results.values.filter { if case .succeeded = $0 { return true }; return false }.count
    let failed = results.values.filter { if case .failed = $0 { return true }; return false }.count
    let queued = results.values.filter { if case .queued = $0 { return true }; return false }.count

    // Producers whose output was consumed by a dependent step — their raw
    // result doesn't get a standalone answer card (the dependent already
    // used it), but it IS shown in the step list.
    let consumed = Set(items.compactMap(\.dependsOnID))

    var reasons: [String] = []
    var outputs: [Completion.Output] = []
    var toExtract: [(UUID, String)] = []
    var steps: [Completion.StepOutcome] = []
    for item in items {
      switch results[item.id] {
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
          // Created item: summarize what was created. Email drafts are
          // worth reviewing before the sheet goes away.
          let isEmail = item.intent.targetIntegration == .gmail && item.intent.actionType != .open
          steps.append(.init(id: item.id, title: item.displayTitle, status: .succeeded,
                             detail: item.completionDetail, reviewable: isEmail))
        }
      case .none:
        break
      }
    }

    completion = Completion(
      succeeded: succeeded, failed: failed, queued: queued,
      failureReasons: reasons, outputs: outputs, steps: steps
    )

    // Extract the specific answer the user asked for from each standalone
    // MCP result (best-effort, in the background).
    guard !toExtract.isEmpty else { return }
    extractionTask = Task { [weak self] in
      for (id, raw) in toExtract {
        guard !Task.isCancelled else { return }
        if let answer = try? await IOSActionParsingClient.extractAnswer(
          request: request, result: raw, provider: provider
        ), !answer.isEmpty {
          self?.applyExtractedAnswer(answer, to: id)
        }
      }
    }
  }

  private func applyExtractedAnswer(_ answer: String, to id: UUID) {
    guard var completion, let index = completion.outputs.firstIndex(where: { $0.itemID == id }) else { return }
    completion.outputs[index].answer = answer
    self.completion = completion
  }
}

struct MultiActionConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var vm: MultiActionConfirmationViewModel

  var body: some View {
    ZStack {
      panelBackground.ignoresSafeArea()

      if vm.isParsing {
        parsingView
          .transition(.opacity)
      } else if let completion = vm.completion {
        completionView(completion)
          .transition(.scale(scale: 0.92).combined(with: .opacity))
          .task(id: completion.steps) {
            if completion.failed == 0 {
              UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
              UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            if completion.queued > 0 {
              NotificationCenter.default.post(name: .quillActionQueuedOffline, object: nil)
            }
            // Auto-dismiss only for trivial done-and-gone results (plain
            // reminders/tasks). Anything worth reading — a lookup result,
            // an email draft, a failure — keeps the sheet up.
            if completion.failed == 0, !completion.hasReviewableStep {
              try? await Task.sleep(for: .milliseconds(1800))
              dismiss()
            }
          }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            header
            heardSection
            willDoSection
            footer
          }
          .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
      }
    }
    .animation(.spring(duration: 0.35, bounce: 0.18), value: vm.completion)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.clear)
    .task {
      // Routine trust ladder: auto-run routines skip the confirmation.
      if vm.autoExecute, vm.completion == nil, !vm.isExecuting {
        await vm.executeAll()
      }
    }
    .onDisappear { vm.cancelBackgroundWork() }
  }

  // MARK: - Background

  private var panelBackground: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      Rectangle().fill(colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.65))
    }
  }

  // MARK: - Parsing skeleton

  /// Shown between record-stop and the parse landing: the HEARD quote
  /// plus a shimmering placeholder card where WILL DO will appear.
  private var parsingView: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        ZStack {
          Circle()
            .fill(QuillDesign.actionAccent.opacity(0.2))
            .frame(width: 36, height: 36)
          ProgressView()
            .tint(QuillDesign.actionAccent)
            .controlSize(.small)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Understanding…")
            .font(.system(size: 15, weight: .semibold))
          Text("Turning your words into actions")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      heardSection
      RoundedRectangle(cornerRadius: QuillDesign.cardCornerRadius, style: .continuous)
        .fill(Color.primary.opacity(0.05))
        .frame(height: 56)
        .overlay(
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
              .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
              RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                .frame(width: 150, height: 10)
              RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                .frame(width: 90, height: 8)
            }
            Spacer()
          }
          .padding(12)
        )
      Spacer()
    }
    .padding(18)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(QuillDesign.actionAccent.opacity(0.2))
          .frame(width: 36, height: 36)
        Image(systemName: "bolt.horizontal.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(QuillDesign.actionAccent)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(vm.items.count == 1 ? "Action detected" : "\(vm.items.count) actions detected")
          .font(.system(size: 15, weight: .semibold))
        Text(vm.wasAutoRouted ? "Auto-detected from your dictation" : (vm.items.count == 1 ? "Action mode" : "Multi-action mode"))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  // MARK: - HEARD

  @ViewBuilder
  private var heardSection: some View {
    if !vm.rawTranscript.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("HEARD")
          .font(.system(size: 10, weight: .semibold))
          .tracking(1.4)
          .foregroundStyle(.secondary)
        Text("\u{201C}\(vm.rawTranscript)\u{201D}")
          .font(.system(size: 14))
          .lineLimit(3)
      }
    }
  }

  // MARK: - WILL DO

  private var willDoSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("WILL DO")
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.4)
        .foregroundStyle(.secondary)

      ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
        actionCard(item, index: index)
      }
    }
  }

  private func actionCard(_ item: MultiActionConfirmationViewModel.ActionItemVM, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        stepTile(item.intent)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            Text(item.displayTitle)
              .font(.system(size: 14, weight: .semibold))
              .lineLimit(1)
            if item.dependsOnID != nil {
              Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            }
          }
          Text(item.displaySubtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          withAnimation { vm.items[index].isExpanded.toggle() }
        } label: {
          Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
        }
        Button {
          withAnimation { vm.removeItem(at: item.id) }
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)

      if item.isExpanded {
        Divider()
        expandedFields(index: index)
          .padding(.vertical, 6)
          .padding(.horizontal, 12)
      }
    }
    .quillCard()
  }

  @ViewBuilder
  private func expandedFields(index: Int) -> some View {
    let item = vm.items[index]
    VStack(spacing: 8) {
      if item.intent.actionType == .mcpCall {
        fieldRow("Title") {
          TextField("Title", text: $vm.items[index].editableTitle)
        }
        if let args = item.intent.mcpArguments, !args.isEmpty {
          ForEach(args.keys.sorted(), id: \.self) { key in
            fieldRow(key) {
              Text(args[key] ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      } else if item.intent.actionType == .open {
        fieldRow("URL") {
          TextField("https://…", text: $vm.items[index].editableURL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      } else if item.intent.targetIntegration == .gmail {
        fieldRow("To") {
          TextField("Recipient", text: $vm.items[index].editableRecipient)
        }
        fieldRow("Subject") {
          TextField("Subject", text: $vm.items[index].editableSubject)
        }
        fieldRow("Body") {
          TextField("Body", text: $vm.items[index].editableBody, axis: .vertical)
            .lineLimit(1...4)
        }
      } else {
        fieldRow("Title") {
          TextField("Title", text: $vm.items[index].editableTitle)
        }
        fieldRow("Due") {
          TextField("e.g. Friday", text: $vm.items[index].editableDueDate)
        }
        fieldRow("Notes") {
          TextField("Optional", text: $vm.items[index].editableNotes)
        }
      }
    }
  }

  private func fieldRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
    HStack {
      Text(label)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(width: 54, alignment: .leading)
      content()
        .font(.system(size: 13))
    }
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(spacing: 8) {
      // Auto-routing escape hatch: the classifier thought this was a
      // command; one tap turns it back into a note line instead.
      if vm.wasAutoRouted, vm.onSaveToNote != nil {
        Button {
          vm.onSaveToNote?()
          dismiss()
        } label: {
          Label("Save to note instead", systemImage: "note.text")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
      }
      footerButtons
    }
  }

  private var footerButtons: some View {
    HStack(spacing: 12) {
      Button { dismiss() } label: {
        Text("Dismiss")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
      }

      Button {
        Task { await vm.executeAll() }
      } label: {
        HStack(spacing: 6) {
          if vm.isExecuting {
            ProgressView().tint(.white)
          }
          Text(vm.items.count == 1 ? "Run action" : "Run \(vm.items.count) actions")
            .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(vm.isExecuting ? Color.purple.opacity(0.5) : Color.purple)
        )
      }
      .disabled(vm.isExecuting || vm.items.isEmpty)
    }
  }

  // MARK: - Completion

  private func completionView(_ c: MultiActionConfirmationViewModel.Completion) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        VStack(spacing: 10) {
          ZStack {
            Circle()
              .fill((c.failed == 0 ? QuillDesign.success : Color.orange).opacity(0.2))
              .frame(width: 64, height: 64)
            Circle()
              .fill(c.failed == 0 ? QuillDesign.success : Color.orange)
              .frame(width: 46, height: 46)
            Image(systemName: c.failed == 0 ? "checkmark" : "exclamationmark.triangle")
              .font(.system(size: 21, weight: .bold))
              .foregroundStyle(.white)
          }
          VStack(spacing: 3) {
            Text(c.failed == 0 ? "Done" : "Partial success")
              .font(.system(size: 16, weight: .semibold))
            Text(completionSubhead(c))
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.top, 26)

        answerCard(c)

        if !c.steps.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(c.steps) { step in
              stepOutcomeRow(step)
            }
          }
        }

        if c.hasReviewableStep || c.failed > 0 {
          Button {
            dismiss()
          } label: {
            Text("Done")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
              .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .fill(Color.purple)
              )
          }
          .padding(.top, 4)
        }
      }
      .padding(18)
    }
  }

  @ViewBuilder
  private func answerCard(_ c: MultiActionConfirmationViewModel.Completion) -> some View {
    let answer = c.combinedAnswer
    if !answer.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("ANSWER")
          .font(.system(size: 10, weight: .semibold))
          .tracking(1.4)
          .foregroundStyle(.secondary)
        Text(answer)
          .font(.system(size: 16, weight: .semibold))
          .textSelection(.enabled)
        Button {
          UIPasteboard.general.string = answer
          UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.purple))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.purple.opacity(colorScheme == .dark ? 0.18 : 0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.purple.opacity(0.25), lineWidth: 0.5)
      )
    }
  }

  private func stepOutcomeRow(_ step: MultiActionConfirmationViewModel.Completion.StepOutcome) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: stepStatusIcon(step.status))
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(stepStatusColor(step.status))
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        Text(step.title)
          .font(.system(size: 13, weight: .semibold))
        if !step.detail.isEmpty {
          Text(step.detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quillCard()
  }

  private func stepStatusIcon(_ status: MultiActionConfirmationViewModel.Completion.StepOutcome.Status) -> String {
    switch status {
    case .succeeded: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .queued: "tray.and.arrow.down.fill"
    }
  }

  private func stepStatusColor(_ status: MultiActionConfirmationViewModel.Completion.StepOutcome.Status) -> Color {
    switch status {
    case .succeeded: QuillDesign.success
    case .failed: .orange
    case .queued: .blue
    }
  }

  private func completionSubhead(_ c: MultiActionConfirmationViewModel.Completion) -> String {
    var parts: [String] = []
    if c.succeeded > 0 { parts.append("\(c.succeeded) completed") }
    if c.queued > 0 { parts.append("\(c.queued) queued offline") }
    if c.failed > 0 { parts.append("\(c.failed) failed") }
    return parts.joined(separator: ", ")
  }

  // MARK: - Helpers

  /// Step tile rendered from the unified `ConnectionTarget` — a Dex or
  /// Notion MCP step shows its brand icon/tint (via the connection
  /// directory), unknown MCP servers get the neutral puzzle piece, and
  /// open steps a globe.
  private func stepTile(_ intent: ActionIntent) -> some View {
    let target = ConnectionTarget.forIntent(intent)
    let fallback: Color = {
      if case .open = target { return .blue }
      return QuillDesign.mcpTile
    }()
    let tint = target.tintHex.flatMap { Color(hex: $0) } ?? fallback
    return RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(tint)
      .frame(width: 28, height: 28)
      .overlay(
        Image(systemName: target.systemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
      )
  }
}
