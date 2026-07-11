import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct MultiActionConfirmationView: View {
  @Bindable var store: StoreOf<MultiActionConfirmationFeature>
  @ObserveInjection var inject
  @State private var didCopyOutput = false
  @State private var didCopyAnswer = false

  var body: some View {
    ZStack {
      if let completion = store.completion {
        multiCompletionBadge(completion)
          .transition(.scale(scale: 0.92).combined(with: .opacity))
      } else {
        VStack(alignment: .leading, spacing: 14) {
          header
          heardSection
          willDoSection
          Spacer(minLength: 0)
          footer
        }
        .padding(18)
      }
    }
    .frame(width: 380)
    .frame(minHeight: 320)
    .animation(.spring(duration: 0.32, bounce: 0.18), value: store.completion)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.black.opacity(0.45))
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    )
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
    )
    .onAppear { store.send(.onAppear) }
    .enableInjection()
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.purple.opacity(0.3))
          .frame(width: 36, height: 36)
        Image(systemName: "bolt.horizontal.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.purple)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text("\(store.items.count) actions detected")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
        Text("Multi-action mode")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.55))
      }
      Spacer(minLength: 0)
    }
  }

  // MARK: - HEARD

  @ViewBuilder
  private var heardSection: some View {
    if !store.rawTranscript.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        sectionLabel("HEARD")
        Text("\u{201C}\(store.rawTranscript)\u{201D}")
          .font(.system(size: 13))
          .foregroundStyle(.white.opacity(0.85))
          .lineSpacing(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(3)
      }
    }
  }

  // MARK: - WILL DO

  private var willDoSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("WILL DO")
      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 8) {
          ForEach(store.items) { item in
            actionCard(item)
          }
        }
      }
      .frame(maxHeight: 320)
    }
  }

  private func actionCard(_ item: MultiActionConfirmationFeature.State.ActionItemState) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 10) {
        stepTile(for: item, size: 28, cornerRadius: 6)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.displayTitle)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
          Text(item.displaySubtitle)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
        }
        Spacer(minLength: 0)

        Button { store.send(.toggleExpanded(item.id)) } label: {
          Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
        }
        .buttonStyle(.plain)

        Button { store.send(.removeItem(item.id)) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
        }
        .buttonStyle(.plain)
      }
      .padding(12)

      if item.isExpanded {
        Divider().opacity(0.2)
        expandedFields(item)
          .padding(.vertical, 4)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.white.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private func expandedFields(_ item: MultiActionConfirmationFeature.State.ActionItemState) -> some View {
    if let index = store.items.index(id: item.id) {
      VStack(spacing: 0) {
        if item.intent.actionType == .open {
          MultiEditableRow(icon: "link", label: "URL") {
            TextField("e.g. https://www.linkedin.com", text: $store.items[index].editableURL)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
          }
          MultiEditableRow(icon: "app", label: "Open with") {
            TextField("Default browser", text: $store.items[index].editableAppName)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
          }
        } else if item.intent.targetIntegration == .gmail {
          MultiEditableRow(icon: "person", label: "To") {
            TextField("e.g. mike@acme.com", text: $store.items[index].editableRecipient)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
          }
          MultiEditableRow(icon: "envelope", label: "Subject") {
            TextField("Subject", text: $store.items[index].editableSubject)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
          }
          MultiEditableRow(icon: "text.alignleft", label: "Body") {
            TextField("Draft body", text: $store.items[index].editableBody, axis: .vertical)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
              .lineLimit(2 ... 3)
          }
        } else {
          MultiEditableRow(icon: integrationIcon(item.intent.targetIntegration), label: "Title") {
            TextField("Title", text: $store.items[index].editableTitle)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
          }
          if item.intent.targetIntegration == .calendar || item.intent.targetIntegration == .googleCalendar {
            MultiEditableRow(icon: "calendar", label: "Start") {
              DatePicker("", selection: $store.items[index].editableStartDate, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.white.opacity(0.9))
            }
            MultiEditableRow(icon: "clock", label: "End") {
              DatePicker("", selection: $store.items[index].editableEndDate, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.white.opacity(0.9))
            }
          } else {
            MultiEditableRow(icon: "info.circle", label: "Due") {
              TextField("e.g. Friday", text: $store.items[index].editableDueDate)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            }
          }
          MultiEditableRow(icon: "note.text", label: "Notes") {
            TextField("Optional", text: $store.items[index].editableNotes, axis: .vertical)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
              .lineLimit(1 ... 2)
          }
        }
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Button { store.send(.cancel) } label: {
        Text("Dismiss")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white.opacity(0.7))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
      .buttonStyle(.plain)

      Button { store.send(.executeAll) } label: {
        HStack(spacing: 8) {
          if store.isExecuting {
            ProgressView()
              .scaleEffect(0.6)
              .frame(width: 14, height: 14)
              .tint(.white)
          }
          Text("Run \(store.items.count) actions")
            .font(.system(size: 13, weight: .semibold))
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white.opacity(0.22))
            .frame(width: 18, height: 18)
            .overlay(
              Image(systemName: "return")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
            )
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(store.isExecuting ? Color.purple.opacity(0.4) : Color.purple)
        )
      }
      .buttonStyle(.plain)
      .disabled(store.isExecuting || store.items.isEmpty)
      .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: - Completion Badge

  private func multiCompletionBadge(_ completion: MultiActionConfirmationFeature.State.Completion) -> some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(badgeTint(completion).opacity(0.22))
          .frame(width: 78, height: 78)
        Circle()
          .fill(badgeTint(completion))
          .frame(width: 58, height: 58)
        Image(systemName: completion.failed == 0 ? "checkmark" : "exclamationmark.triangle")
          .font(.system(size: 26, weight: .bold))
          .foregroundStyle(.white)
      }

      VStack(spacing: 3) {
        Text(completionTitle(completion))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
        Text(completionSubhead(completion))
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.7))
          .multilineTextAlignment(.center)
      }

      // Extracted answer (the specific value the user asked for), shown
      // prominently with Copy + Paste — appears once extraction returns.
      if !completion.combinedAnswer.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Answer")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
          Text(completion.combinedAnswer)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 8) {
            Button {
              store.send(.copyAnswer)
              didCopyAnswer = true
              Task { try? await Task.sleep(for: .seconds(1.4)); didCopyAnswer = false }
            } label: {
              Label(didCopyAnswer ? "Copied" : "Copy", systemImage: didCopyAnswer ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(didCopyAnswer ? .green : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)

            if store.sourceAppBundleID != nil {
              Button { store.send(.pasteAnswer) } label: {
                Label("Paste", systemImage: "text.cursor")
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(.white)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.55)))
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.10))
        )
      }

      // Per-step outcome: what each step found or created, so a chained
      // command (look up X → draft email) shows both the lookup result and
      // the drafted email — not just "2 created".
      if !completion.steps.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(completion.steps) { step in
            stepOutcomeRow(step)
          }
          Button {
            store.send(.copyOutput)
            didCopyOutput = true
            Task { try? await Task.sleep(for: .seconds(1.4)); didCopyOutput = false }
          } label: {
            Label(didCopyOutput ? "Copied" : "Copy", systemImage: didCopyOutput ? "checkmark" : "doc.on.doc")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(didCopyOutput ? .green : .white)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(.white.opacity(0.14))
              )
          }
          .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.06))
        )
      }

      // Manual dismiss whenever the panel isn't auto-closing.
      if !completion.steps.isEmpty {
        Button { store.send(.completionDismissed) } label: {
          Text("Dismiss")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 28)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func stepOutcomeRow(_ step: MultiActionConfirmationFeature.State.Completion.StepOutcome) -> some View {
    let (icon, tint): (String, Color) = {
      switch step.status {
      case .succeeded: return ("checkmark.circle.fill", .green)
      case .failed: return ("exclamationmark.circle.fill", .orange)
      case .queued: return ("clock.fill", .yellow)
      }
    }()
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 7) {
        Image(systemName: icon)
          .font(.system(size: 12))
          .foregroundStyle(tint)
        Text(step.title)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !step.detail.isEmpty {
        ScrollView(.vertical, showsIndicators: true) {
          Text(step.detail)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: 160)
        .padding(.leading, 19)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func completionTitle(_ c: MultiActionConfirmationFeature.State.Completion) -> String {
    if c.failed == 0 { return c.steps.count > 1 ? "Done" : (c.outputs.isEmpty ? "Done" : "Result") }
    if c.succeeded > 0 || c.queued > 0 { return "Partial success" }
    return c.failed == 1 ? "Action failed" : "Actions failed"
  }

  private func badgeTint(_ c: MultiActionConfirmationFeature.State.Completion) -> Color {
    if c.failed > 0 { return .orange }
    if c.queued > 0 { return .yellow }
    return .green
  }

  private func completionSubhead(_ c: MultiActionConfirmationFeature.State.Completion) -> String {
    var parts: [String] = []
    // "completed" reads correctly for a mix of lookups + creations; "created"
    // would be wrong for a step that just looked something up.
    if c.succeeded > 0 { parts.append("\(c.succeeded) \(c.succeeded == 1 ? "step" : "steps") completed") }
    if c.queued > 0 { parts.append("\(c.queued) queued offline") }
    if c.failed > 0 { parts.append("\(c.failed) failed") }
    return parts.joined(separator: ", ")
  }

  // MARK: - Helpers

  private func sectionLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .tracking(1.4)
      .foregroundStyle(.white.opacity(0.45))
  }

  private func integrationTile(for id: Integration.Identifier, size: CGFloat, cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(integrationTint(id))
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: integrationIcon(id))
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      )
  }

  private func integrationIcon(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.systemImage ?? "questionmark.circle"
  }

  private func integrationTint(_ id: Integration.Identifier) -> Color {
    let hex = Integration.all.first { $0.identifier == id }?.tintHex
    return Color(hex: hex ?? "") ?? .orange
  }

  // Step-aware icon tile: MCP steps and the Open action aren't in the
  // integrations catalog (their `targetIntegration` is a placeholder), so
  // key the icon off the action type instead of showing the wrong tile.
  private func stepTile(for item: MultiActionConfirmationFeature.State.ActionItemState, size: CGFloat, cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(stepTint(item))
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: stepIcon(item))
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      )
  }

  private func stepIcon(_ item: MultiActionConfirmationFeature.State.ActionItemState) -> String {
    // Unified ConnectionTarget branding: known MCP servers (Dex, Notion…)
    // get their directory icon; unknown ones the neutral puzzle piece.
    switch item.intent.actionType {
    case .mcpCall, .open: return ConnectionTarget.forIntent(item.intent).systemImage
    default: return integrationIcon(item.intent.targetIntegration)
    }
  }

  private func stepTint(_ item: MultiActionConfirmationFeature.State.ActionItemState) -> Color {
    switch item.intent.actionType {
    case .mcpCall:
      return ConnectionTarget.forIntent(item.intent).tintHex.flatMap { Color(hex: $0) }
        ?? Color(hex: "8E8E93") ?? .gray
    case .open: return Color(hex: "0A84FF") ?? .blue
    default: return integrationTint(item.intent.targetIntegration)
    }
  }
}

// MARK: - MultiEditableRow

private struct MultiEditableRow<Content: View>: View {
  let icon: String
  let label: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .frame(width: 14, height: 14)

      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}
