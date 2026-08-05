//
//  ActionRunsView.swift
//  Quill (macOS)
//
//  The Actions pane: every Action-mode run, newest first, with an
//  expandable trace per step.
//
//  This is a debugging surface as much as a history one — the point is to
//  answer "why did that do the wrong thing?", which usually means reading
//  the plan the LLM produced and the raw text a tool actually returned.
//  So a step shows its tool + arguments, its raw result, and (for a chained
//  step) the intent before and after the resolve pass, rather than only the
//  tidy summary the confirmation panel renders.
//

import HexCore
import SwiftUI

@MainActor
final class ActionRunsModel: ObservableObject {
  @Published private(set) var runs: [ActionRun] = []
  @Published private(set) var isLoading = false

  private var observer: NSObjectProtocol?

  init() {
    observer = NotificationCenter.default.addObserver(
      forName: .actionRunRecorded, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.load() }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func load() async {
    isLoading = true
    runs = await ActionRunStore.shared.loadAll()
    isLoading = false
  }

  func delete(_ run: ActionRun) {
    runs.removeAll { $0.id == run.id }
    Task { await ActionRunStore.shared.remove(id: run.id) }
  }

  func clearAll() {
    runs = []
    Task { await ActionRunStore.shared.removeAll() }
  }
}

struct ActionRunsView: View {
  @StateObject private var model = ActionRunsModel()
  @State private var expanded: Set<UUID> = []
  @State private var searchText = ""

  private var filtered: [ActionRun] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return model.runs }
    return model.runs.filter { run in
      run.request.lowercased().contains(query)
        || run.steps.contains {
          $0.title.lowercased().contains(query)
            || $0.targetName.lowercased().contains(query)
            || ($0.mcpTool?.lowercased().contains(query) ?? false)
            || ($0.errorMessage?.lowercased().contains(query) ?? false)
        }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        if model.runs.isEmpty {
          emptyState
        } else {
          ForEach(filtered) { run in
            ActionRunCard(
              run: run,
              isExpanded: expanded.contains(run.id),
              onToggle: {
                if expanded.contains(run.id) { expanded.remove(run.id) } else { expanded.insert(run.id) }
              },
              onDelete: { model.delete(run) }
            )
          }
          if filtered.isEmpty {
            Text("No runs match \u{201C}\(searchText)\u{201D}")
              .font(.callout)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(16)
              .quillCard()
          }
        }
      }
      .padding(.horizontal, 28)
      .padding(.top, 20)
      .padding(.bottom, 36)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .animation(.spring(duration: 0.3), value: expanded)
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search actions")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(role: .destructive) {
          model.clearAll()
        } label: {
          Label("Clear", systemImage: "trash")
        }
        .disabled(model.runs.isEmpty)
        .help("Delete all recorded action traces")
      }
    }
    .task { await model.load() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Actions")
        .font(.system(size: 22, weight: .bold))
      Text(
        model.runs.isEmpty
          ? "Every action you run is recorded here with a full trace."
          : "\(model.runs.count) recent \(model.runs.count == 1 ? "run" : "runs") \u{00B7} expand a run to see each step\u{2019}s tool, arguments, and raw result."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .padding(.bottom, 4)
  }

  private var emptyState: some View {
    HStack(spacing: 12) {
      Image(systemName: "bolt.badge.clock")
        .font(.system(size: 22))
        .foregroundStyle(QuillDesign.actionAccent)
      VStack(alignment: .leading, spacing: 4) {
        Text("No actions yet")
          .font(.headline)
        Text("Type a command on Home or dictate one in Act mode. Runs land here with a step-by-step trace.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .quillCard()
  }
}

// MARK: - Run card

private struct ActionRunCard: View {
  let run: ActionRun
  let isExpanded: Bool
  var onToggle: () -> Void
  var onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggle) {
        HStack(alignment: .top, spacing: 11) {
          statusTile
          VStack(alignment: .leading, spacing: 3) {
            Text(run.request.isEmpty ? "(no request text)" : run.request)
              .font(.system(size: 13.5, weight: .semibold))
              .foregroundStyle(run.request.isEmpty ? .secondary : .primary)
              .lineLimit(isExpanded ? nil : 2)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
              Label(run.trigger.displayName, systemImage: run.trigger.systemImage)
                .font(.system(size: 11))
              if !run.targetSummary.isEmpty {
                Text("\u{00B7}")
                Text(run.targetSummary).font(.system(size: 11))
              }
              Text("\u{00B7}")
              Text("\(run.steps.count) \(run.steps.count == 1 ? "step" : "steps")")
                .font(.system(size: 11))
              Text("\u{00B7}")
              Text(formatDuration(run.duration)).font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          VStack(alignment: .trailing, spacing: 4) {
            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(.tertiary)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.tertiary)
          }
        }
        .padding(13)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        Divider().opacity(0.35)
        VStack(alignment: .leading, spacing: 12) {
          ForEach(run.steps) { step in
            ActionStepRow(step: step)
          }
          HStack {
            Spacer()
            Button(role: .destructive) { onDelete() } label: {
              Label("Delete this run", systemImage: "trash")
                .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
          }
        }
        .padding(13)
      }
    }
    .quillCard()
  }

  private var statusTile: some View {
    let (icon, tint): (String, Color) = switch run.status {
    case .succeeded: ("checkmark", QuillDesign.ModePalette.resolved.color())
    case .partial: ("exclamationmark", .orange)
    case .failed: ("xmark", .red)
    case .queued: ("clock", .yellow)
    }
    return RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
      .fill(tint.opacity(0.16))
      .frame(width: 28, height: 28)
      .overlay(
        Image(systemName: icon)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(tint)
      )
  }
}

// MARK: - Step row

private struct ActionStepRow: View {
  let step: ActionStepTrace
  @State private var showsPlan = false
  /// Labels of blocks the user flipped back to raw text, keyed by the block
  /// label since a step has at most one of each.
  @State private var rawBlocks: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(systemName: statusIcon)
          .font(.system(size: 12))
          .foregroundStyle(statusTint)
        Text("\(step.index + 1). \(step.title)")
          .font(.system(size: 12.5, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        if let duration = step.duration {
          Text(formatDuration(duration))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
      }

      // What this step targeted, and — for a chained step — what it fed on.
      HStack(spacing: 6) {
        chip(step.targetName, icon: "arrow.right.circle")
        chip(step.actionType, icon: "curlybraces")
        if let tool = step.mcpTool { chip(tool, icon: "wrench.and.screwdriver") }
        if let dependsOn = step.dependsOnIndex {
          chip("uses step \(dependsOn + 1)", icon: "link")
        }
      }

      if let arguments = step.mcpArguments, !arguments.isEmpty {
        traceBlock("Arguments", text: arguments
          .sorted { $0.key < $1.key }
          .map { "\($0.key): \($0.value)" }
          .joined(separator: "\n"))
      }

      if let instruction = step.resolveInstruction, !instruction.isEmpty {
        traceBlock("Resolve instruction", text: instruction)
      }

      if let raw = step.rawResult, !raw.isEmpty {
        traceBlock("Result", text: raw, monospaced: true, maxHeight: 220)
      }

      if let error = step.errorMessage, !error.isEmpty {
        traceBlock("Error", text: error, tint: .orange)
      }

      // The full intent JSON is the last resort — useful, but noisy enough
      // that it shouldn't be the first thing in the reader's way.
      DisclosureGroup(isExpanded: $showsPlan) {
        VStack(alignment: .leading, spacing: 8) {
          traceBlock("Planned", text: step.plannedIntentJSON, monospaced: true, maxHeight: 260)
          if let resolved = step.resolvedIntentJSON {
            traceBlock("After resolve", text: resolved, monospaced: true, maxHeight: 260)
          }
        }
        .padding(.top, 6)
      } label: {
        Text(step.resolvedIntentJSON == nil ? "Planned intent" : "Planned intent + resolve")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(11)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(Color.primary.opacity(0.04))
    )
  }

  private var statusIcon: String {
    switch step.status {
    case .succeeded: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle.fill"
    case .queued: "clock.fill"
    case .skipped: "minus.circle.fill"
    }
  }

  private var statusTint: Color {
    switch step.status {
    case .succeeded: QuillDesign.ModePalette.resolved.color()
    case .failed: .orange
    case .queued: .yellow
    case .skipped: .secondary
    }
  }

  private func chip(_ text: String, icon: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon).font(.system(size: 8.5, weight: .semibold))
      Text(text).font(.system(size: 10.5, weight: .medium))
    }
    .foregroundStyle(.secondary)
    .padding(.vertical, 2)
    .padding(.horizontal, 6)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
        .fill(Color.primary.opacity(0.06))
    )
  }

  @ViewBuilder
  private func traceBlock(
    _ label: String,
    text: String,
    monospaced: Bool = false,
    tint: Color? = nil,
    maxHeight: CGFloat? = nil
  ) -> some View {
    // MCP tools answer in JSON, usually minified onto one line — unreadable
    // as-is. Pretty-print it when it parses, but keep the raw text one click
    // away: escaping and whitespace are sometimes exactly what you're
    // chasing, and a failed parse shouldn't hide the payload.
    let pretty = JSONFormatting.prettified(text)
    let showingRaw = rawBlocks.contains(label)
    let displayed = (showingRaw ? nil : pretty) ?? text

    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(label.uppercased())
          .font(.system(size: 9, weight: .heavy))
          .tracking(0.4)
          .foregroundStyle(tint ?? .secondary)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(displayed, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 8.5))
        }
        .buttonStyle(.borderless)
        .help("Copy \(label.lowercased())")
        .accessibilityLabel("Copy \(label.lowercased())")

        if pretty != nil {
          Button {
            if showingRaw { rawBlocks.remove(label) } else { rawBlocks.insert(label) }
          } label: {
            Text(showingRaw ? "Formatted" : "Raw")
              .font(.system(size: 8.5, weight: .heavy))
              .tracking(0.3)
          }
          .buttonStyle(.borderless)
          .help(showingRaw ? "Show formatted JSON" : "Show the exact text the step returned")
        }
      }
      Group {
        if let maxHeight {
          ScrollView([.vertical, .horizontal]) {
            traceText(displayed, isJSON: !showingRaw && pretty != nil, monospaced: monospaced, tint: tint)
          }
          .frame(maxHeight: maxHeight)
        } else {
          traceText(displayed, isJSON: !showingRaw && pretty != nil, monospaced: monospaced, tint: tint)
        }
      }
    }
  }

  @ViewBuilder
  private func traceText(_ text: String, isJSON: Bool, monospaced: Bool, tint: Color?) -> some View {
    if isJSON {
      Text(JSONSyntax.highlight(text))
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      Text(text)
        .font(.system(size: 11, design: monospaced ? .monospaced : .default))
        .foregroundStyle(tint ?? .primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - JSON syntax highlighting

/// Minimal colouriser for already-valid, pretty-printed JSON. Deliberately
/// a scanner rather than a re-serialization pass: it preserves the exact
/// text being displayed (so selection and copy match what's on screen) and
/// can't reorder or drop anything.
private enum JSONSyntax {
  static func highlight(_ json: String) -> AttributedString {
    var out = AttributedString()
    let scalars = Array(json)
    var i = 0

    func append(_ text: String, _ color: Color?) {
      var run = AttributedString(text)
      run.foregroundColor = color ?? .primary
      out.append(run)
    }

    while i < scalars.count {
      let char = scalars[i]

      if char == "\"" {
        // Read to the closing quote, honouring backslash escapes.
        var j = i + 1
        while j < scalars.count {
          if scalars[j] == "\\" { j += 2; continue }
          if scalars[j] == "\"" { break }
          j += 1
        }
        let end = min(j, scalars.count - 1)
        let literal = String(scalars[i...end])
        // A string followed by a colon is a key.
        var k = end + 1
        while k < scalars.count, scalars[k] == " " { k += 1 }
        let isKey = k < scalars.count && scalars[k] == ":"
        append(literal, isKey ? keyColor : stringColor)
        i = end + 1
        continue
      }

      if char.isNumber || (char == "-" && i + 1 < scalars.count && scalars[i + 1].isNumber) {
        var j = i
        while j < scalars.count, scalars[j].isNumber || "-+.eE".contains(scalars[j]) { j += 1 }
        append(String(scalars[i..<j]), literalColor)
        i = j
        continue
      }

      if let keyword = ["true", "false", "null"].first(where: { matches($0, in: scalars, at: i) }) {
        append(keyword, literalColor)
        i += keyword.count
        continue
      }

      append(String(char), "{}[],:".contains(char) ? punctuationColor : nil)
      i += 1
    }
    return out
  }

  private static func matches(_ word: String, in scalars: [Character], at index: Int) -> Bool {
    guard index + word.count <= scalars.count else { return false }
    return String(scalars[index..<(index + word.count)]) == word
  }

  private static let keyColor = Color.accentColor
  private static let stringColor = QuillDesign.ModePalette.resolved.color()
  private static let literalColor = QuillDesign.ModePalette.edit.color()
  private static let punctuationColor = Color.secondary
}

// MARK: - Shared formatting

private func formatDuration(_ seconds: TimeInterval) -> String {
  if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
  if seconds < 60 { return String(format: "%.1fs", seconds) }
  return String(format: "%dm %ds", Int(seconds) / 60, Int(seconds) % 60)
}
