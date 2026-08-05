import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Action confirmation panel — the modal a user sees after dictating in
/// Action mode. The layout follows the "HEARD / WILL DO" pattern:
///
/// 1. Header tile — integration icon + "New <noun> in <Integration>" + "Action detected"
/// 2. HEARD     — quoted raw transcript so the user can verify what we
///                heard before we run the action
/// 3. WILL DO   — preview card with the structured fields the integration
///                will receive, each row inline-editable via a pencil
/// 4. Footer    — Dismiss (ghost) + Run action (filled purple)
///
/// All editable fields keep the existing TCA bindings — we just changed
/// the visual treatment.
struct ActionConfirmationView: View {
  @Bindable var store: StoreOf<ActionConfirmationFeature>
  @ObserveInjection var inject

  var body: some View {
    ZStack {
      if let completion = store.completion {
        ActionCompletionBadgeView(completion: completion)
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
    .frame(minHeight: 280)
    .animation(.spring(duration: 0.32, bounce: 0.18), value: store.completion)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .fill(.black.opacity(0.45))
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    )
    .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
    )
    .onAppear { store.send(.onAppear) }
    .enableInjection()
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      integrationTile(size: 36, cornerRadius: QuillDesign.Radius.chip)

      VStack(alignment: .leading, spacing: 2) {
        if store.availableIntegrations.count > 1 {
          // Picker hosted on the title so users can change the routing
          // mid-review without leaving the panel.
          Picker("", selection: integrationBinding) {
            ForEach(store.availableIntegrations, id: \.self) { id in
              Text("New \(actionNoun(for: id)) in \(integrationName(id))").tag(id)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .tint(.white)
          .font(.system(size: 14, weight: .semibold))
        } else {
          Text("New \(actionNoun(for: store.selectedIntegration)) in \(integrationName(store.selectedIntegration))")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
        }
        Text("Action detected")
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
      }
    }
  }

  // MARK: - WILL DO

  private var willDoSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("WILL DO")
      VStack(alignment: .leading, spacing: 0) {
        // Top mini-row inside the card: integration tile + bold title +
        // secondary date/time. Mirrors the screenshot's preview header.
        HStack(alignment: .center, spacing: 10) {
          integrationTile(size: 32, cornerRadius: QuillDesign.Radius.chip)
          VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.white)
              .lineLimit(1)
            Text(displaySubtitle)
              .font(.system(size: 11))
              .foregroundStyle(.white.opacity(0.55))
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .padding(12)

        Divider().opacity(0.2)

        // Editable per-integration field rows.
        VStack(spacing: 0) {
          fieldRows
        }
        .padding(.vertical, 4)

        if let error = store.error {
          Text(error)
            .font(.system(size: 11))
            .foregroundStyle(.red.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(.white.opacity(0.05))
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
      )
    }
  }

  @ViewBuilder
  private var fieldRows: some View {
    if store.selectedIntegration == .gmail {
      EditableRow(icon: "person", label: "To") {
        TextField("e.g. mike@acme.com", text: $store.editableRecipient)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(.white)
      }
      EditableRow(icon: "envelope", label: "Subject") {
        TextField("Subject", text: $store.editableSubject)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(.white)
      }
      EditableRow(icon: "text.alignleft", label: "Body") {
        TextField("Draft body text", text: $store.editableBody, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(.white)
          .lineLimit(2 ... 4)
      }
    } else {
      EditableRow(icon: integrationIcon(store.selectedIntegration), label: "Title") {
        TextField("Title", text: $store.editableTitle)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(.white)
      }

      if store.selectedIntegration == .calendar || store.selectedIntegration == .googleCalendar {
        EditableRow(icon: "calendar", label: "Start") {
          DatePicker("", selection: tiedStartDateBinding, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(.white.opacity(0.9))
        }
        EditableRow(icon: "clock", label: "End") {
          DatePicker("", selection: $store.editableEndDate, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(.white.opacity(0.9))
        }
      } else {
        EditableRow(icon: "info.circle", label: "Due") {
          TextField("e.g. Friday, tomorrow", text: $store.editableDueDate)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
        }
      }

      if !store.availableLists.isEmpty {
        EditableRow(icon: listIcon, label: listLabel) {
          Picker("", selection: $store.selectedList) {
            ForEach(store.availableLists, id: \.self) { list in
              Text(list).tag(list)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .tint(.white.opacity(0.9))
        }
      }

      if store.selectedIntegration == .todoist {
        EditableRow(icon: "flag", label: "Priority") {
          Picker("", selection: $store.editablePriority) {
            Text("None").tag(0)
            Text("P1 (urgent)").tag(4)
            Text("P2").tag(3)
            Text("P3").tag(2)
            Text("P4 (low)").tag(1)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .tint(.white.opacity(0.9))
        }
      }

      if store.selectedIntegration == .calendar || store.selectedIntegration == .googleCalendar {
        EditableRow(icon: "person.2", label: "Attendees") {
          TextField("e.g. john@acme.com", text: $store.editableAttendees)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
        }
      }

      EditableRow(icon: "note.text", label: "Notes") {
        TextField("Optional", text: $store.editableNotes, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(.white)
          .lineLimit(1 ... 3)
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

      Button { store.send(.execute) } label: {
        HStack(spacing: 8) {
          if store.isExecuting {
            ProgressView()
              .scaleEffect(0.6)
              .frame(width: 14, height: 14)
              .tint(.white)
          }
          Text("Run action")
            .font(.system(size: 13, weight: .semibold))
          // Return-key glyph chip on the trailing edge.
          RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
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
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(executeDisabled ? Color.purple.opacity(0.4) : Color.purple)
        )
      }
      .buttonStyle(.plain)
      .disabled(executeDisabled)
      .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: - Helpers

  private var executeDisabled: Bool {
    if store.isExecuting { return true }
    if store.selectedIntegration == .gmail {
      return store.editableSubject.isEmpty
    }
    return store.editableTitle.isEmpty
  }

  private var displayTitle: String {
    if store.selectedIntegration == .gmail, !store.editableSubject.isEmpty {
      return store.editableSubject
    }
    return store.editableTitle.isEmpty ? "(untitled)" : store.editableTitle
  }

  private var displaySubtitle: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    switch store.selectedIntegration {
    case .calendar, .googleCalendar:
      let s = formatter.string(from: store.editableStartDate)
      return s
    case .gmail:
      return store.editableRecipient.isEmpty ? "Draft" : "To: \(store.editableRecipient)"
    default:
      if !store.editableDueDate.isEmpty { return store.editableDueDate }
      return store.selectedList.isEmpty ? "No date" : store.selectedList
    }
  }

  private var listLabel: String {
    switch store.selectedIntegration {
    case .todoist: "Project"
    case .calendar, .googleCalendar: "Calendar"
    default: "List"
    }
  }

  private var listIcon: String {
    switch store.selectedIntegration {
    case .todoist: "folder"
    case .calendar, .googleCalendar: "calendar.badge.plus"
    default: "list.bullet"
    }
  }

  private var integrationBinding: Binding<Integration.Identifier> {
    Binding(
      get: { store.selectedIntegration },
      set: { store.send(.selectedIntegrationChanged($0)) }
    )
  }

  /// Shifts `editableEndDate` by the same delta when start changes so the
  /// user-chosen duration is preserved.
  private var tiedStartDateBinding: Binding<Date> {
    Binding(
      get: { store.editableStartDate },
      set: { newStart in
        let delta = newStart.timeIntervalSince(store.editableStartDate)
        store.editableEndDate = store.editableEndDate.addingTimeInterval(delta)
        store.editableStartDate = newStart
      }
    )
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .tracking(1.4)
      .foregroundStyle(.white.opacity(0.45))
  }

  /// 36×36 (or 32×32) integration icon tile — colored background with the
  /// integration's `systemImage` in white. Reused by header + WILL DO card
  /// so the routing target reads the same in both places.
  private func integrationTile(size: CGFloat, cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(integrationTint(store.selectedIntegration))
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: integrationIcon(store.selectedIntegration))
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      )
  }

  private func actionNoun(for id: Integration.Identifier) -> String {
    switch id {
    case .calendar, .googleCalendar: "event"
    case .gmail: "draft"
    case .todoist: "task"
    case .appleReminders: "reminder"
    default: "item"
    }
  }

  private func integrationName(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.name ?? id.rawValue
  }

  private func integrationIcon(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.systemImage ?? "questionmark.circle"
  }

  private func integrationTint(_ id: Integration.Identifier) -> Color {
    let hex = Integration.all.first { $0.identifier == id }?.tintHex
    return Color(hex: hex ?? "") ?? .orange
  }
}

// MARK: - Completion badge

/// Replaces the panel content with a brief "Added to <Integration>"
/// confirmation after a successful (or queued) action. Stays on screen
/// long enough to register before the panel dismisses, so the user has
/// visible proof the action actually went through. Shape mirrors the
/// iOS sheet's `CompletionBadgeView`.
///
/// Tapping the integration pill deep-links into the integration's app
/// (when its URL scheme is supported on macOS — e.g. Todoist, Notion,
/// Things, Reminders all register their schemes).
struct ActionCompletionBadgeView: View {
  let completion: ActionConfirmationFeature.State.Completion

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(badgeTint.opacity(0.22))
          .frame(width: 78, height: 78)
        Circle()
          .fill(badgeTint)
          .frame(width: 58, height: 58)
        Image(systemName: badgeIcon)
          .font(.system(size: 26, weight: .bold))
          .foregroundStyle(.white)
      }
      .accessibilityHidden(true)

      VStack(spacing: 3) {
        Text(headline)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
        Text(subhead)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.7))
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }

      openInPill
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 32)
    .frame(maxWidth: .infinity)
  }

  /// Tappable when there's a deep link to open, plain pill otherwise.
  /// The chevron-square glyph is the only visual change between the
  /// two — the rest of the layout stays identical so the badge size
  /// doesn't shift between integrations.
  @ViewBuilder
  private var openInPill: some View {
    if let url = deepLinkURL {
      Button {
        NSWorkspace.shared.open(url)
      } label: {
        pillContent(showChevron: true)
      }
      .buttonStyle(.plain)
    } else {
      pillContent(showChevron: false)
    }
  }

  private func pillContent(showChevron: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: integrationIcon)
        .font(.system(size: 11, weight: .semibold))
      Text(pillText)
        .font(.system(size: 12, weight: .semibold))
      if showChevron {
        Image(systemName: "arrow.up.right.square.fill")
          .font(.system(size: 11, weight: .bold))
          .opacity(0.85)
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Capsule().fill(integrationColor))
  }

  private var deepLinkURL: URL? {
    guard completion.kind == .created else { return nil }
    return IntegrationDeepLink.appRoot(for: completion.integration)
  }

  private var badgeTint: Color {
    switch completion.kind {
    case .created: .green
    case .queued: .orange
    }
  }

  private var badgeIcon: String {
    switch completion.kind {
    case .created: "checkmark"
    case .queued: "wifi.exclamationmark"
    }
  }

  private var headline: String {
    switch completion.kind {
    case .created: "Done"
    case .queued: "Saved offline"
    }
  }

  private var subhead: String {
    switch completion.kind {
    case .created: "\u{201C}\(completion.title)\u{201D}"
    case .queued: "Will retry when you're back online."
    }
  }

  private var pillText: String {
    switch completion.kind {
    case .created: "Added to \(integrationName)"
    case .queued: "Queued for \(integrationName)"
    }
  }

  private var integrationName: String {
    Integration.all.first { $0.identifier == completion.integration }?.name
      ?? completion.integration.rawValue
  }

  private var integrationIcon: String {
    Integration.all.first { $0.identifier == completion.integration }?.systemImage
      ?? "checkmark.circle.fill"
  }

  private var integrationColor: Color {
    let hex = Integration.all.first { $0.identifier == completion.integration }?.tintHex
    return Color(hex: hex ?? "") ?? .purple
  }
}

// MARK: - EditableRow

/// Single row inside the WILL DO card: leading icon, label, value control,
/// trailing pencil. The pencil is decorative — the value control is always
/// editable inline; the pencil signals "this is editable" without adding a
/// state machine for "expanded vs collapsed" rows.
private struct EditableRow<Content: View>: View {
  let icon: String
  let label: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .frame(width: 16, height: 16)

      content()
        .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "pencil")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.35))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
