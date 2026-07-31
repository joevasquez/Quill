//
//  QuillModeRail.swift
//  Quill (iOS)
//
//  The mode rail and its sub-rows. Picking a mode re-tints the rail, the
//  orb, and the capture sheet — one hue, everywhere.
//
//  Each mode reveals its own sub-row beneath the rail:
//    • Dictate → format sub-filters (the AIProcessingMode cases)
//    • Act     → the connected destinations eligible for routing
//    • Edit    → revision commands, most-used first
//
//  Flat throughout: no shadows. Elevation is a hairline border plus a tint.
//

import HexCore
import SwiftUI

// MARK: - Rail

struct QuillModeRail: View {
  @Binding var mode: QuillMode
  var order: [QuillMode]
  var compact: Bool = false

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(order) { m in
        railButton(m)
      }
    }
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(theme.chip)
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(theme.hair, lineWidth: 0.5)
        )
    )
  }

  private func railButton(_ m: QuillMode) -> some View {
    let isOn = mode == m
    let p = m.palette

    return Button {
      withAnimation(.easeInOut(duration: 0.18)) { mode = m }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: m.systemImage)
          .font(.system(size: 15, weight: isOn ? .semibold : .medium))
        Text(m.label)
          .font(.system(size: 14.5, weight: isOn ? .bold : .medium))
      }
      .foregroundStyle(
        isOn
          ? p.lightnessCapped(at: theme.isDark ? 0.82 : 0.55).color()
          : theme.text2
      )
      .frame(maxWidth: .infinity)
      .padding(.vertical, compact ? 7 : 9)
      .padding(.horizontal, 8)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(isOn ? p.color(0.14) : .clear)
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(isOn ? p.color(0.5) : .clear, lineWidth: 1)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(m.label)
    .accessibilityHint(m.subtitle)
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
  }
}

// MARK: - Shared chip chrome

/// The one chip shape. `tint` nil = an unselected/neutral chip.
private struct QuillChip<Label: View>: View {
  var tint: OKLCH?
  var isOn: Bool
  var action: () -> Void
  @ViewBuilder var label: () -> Label

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    Button(action: action) {
      label()
        .font(.system(size: 13, weight: isOn ? .semibold : .medium))
        .foregroundStyle(foreground)
        .padding(.vertical, 6)
        .padding(.horizontal, 11)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .fill(isOn ? (tint?.color(0.13) ?? theme.chip) : theme.card)
            .overlay(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                .strokeBorder(isOn ? (tint?.color(0.5) ?? theme.hair) : theme.hair, lineWidth: 0.5)
            )
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var foreground: Color {
    guard isOn else { return theme.text2 }
    guard let tint else { return theme.text }
    return tint.lightnessCapped(at: theme.isDark ? 0.82 : 0.5).color()
  }
}

/// The dashed "+ Add" affordance that ends every sub-row.
private struct QuillAddChip: View {
  var label: String = "Add"
  var action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
        Text(label)
          .font(.system(size: 13, weight: .medium))
      }
      .foregroundStyle(theme.text2)
      .padding(.vertical, 6)
      .padding(.horizontal, 12)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .strokeBorder(
            theme.isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.25),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Dictate: format sub-filters

/// Format is single-select, so it reads as a dropdown, not a chip cloud:
/// the active format is a pill (`Clean ⌄`) that opens a menu of all
/// formats with a check on the current one and an "Add format…" row under
/// a divider. (Contrast with Act, which is multi-select → summary + grid.)
struct QuillFormatChips: View {
  @Binding var format: AIProcessingMode
  /// Built-ins the user has hidden in Settings.
  var hidden: Set<AIProcessingMode> = []
  var onAddCustom: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  private var visible: [AIProcessingMode] {
    AIProcessingMode.allCases.filter { $0 == .off || !hidden.contains($0) }
  }

  var body: some View {
    Menu {
      // Picker-in-Menu renders the system single-select treatment: one
      // row per format, checkmark on the current selection.
      Picker("Format", selection: $format) {
        ForEach(visible, id: \.self) { f in
          Label(f.iosDisplayName, systemImage: f.iosIconName).tag(f)
        }
      }
      Divider()
      Button(action: onAddCustom) {
        Label("Add format…", systemImage: "plus")
      }
    } label: {
      activePill
    }
    .accessibilityLabel("Format: \(format.iosDisplayName)")
    .accessibilityHint("Opens the format menu")
  }

  private var activePill: some View {
    let tint = QuillDesign.ModePalette.dictate
    return HStack(spacing: 6) {
      Image(systemName: format.iosIconName)
        .font(.system(size: 13, weight: .medium))
      Text(format.iosDisplayName)
        .font(.system(size: 13, weight: .semibold))
      Image(systemName: "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .opacity(0.7)
    }
    .foregroundStyle(tint.lightnessCapped(at: theme.isDark ? 0.82 : 0.5).color())
    .padding(.vertical, 6)
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(tint.color(0.13))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .strokeBorder(tint.color(0.5), lineWidth: 0.5)
        )
    )
    .contentShape(Rectangle())
  }
}

// MARK: - Act: destinations

/// A destination the agent can route to — a native integration or an MCP
/// server. The rail only offers things that are actually connected;
/// "+ Add" goes to Connections rather than pretending a toggle can
/// authenticate.
struct QuillActDestination: Identifiable, Equatable {
  enum Kind: Equatable {
    case integration(Integration.Identifier)
    case mcp(String)
  }

  var kind: Kind
  var name: String
  var systemImage: String
  var hue: Double

  var id: String {
    switch kind {
    case .integration(let i): "integration:\(i.rawValue)"
    case .mcp(let name): "mcp:\(name)"
    }
  }

  var isMCP: Bool {
    if case .mcp = kind { return true }
    return false
  }

  var palette: OKLCH { QuillDesign.destination(hue: hue) }

  /// Everything the agent could actually route to right now: connected
  /// native integrations plus enabled MCP servers.
  ///
  /// Unlike the design prototype — where destinations were a hardcoded list
  /// with a bool toggle — connecting is a real act of authentication, so
  /// this only reflects what's already set up. "+ Add" leads to Connections.
  static func connected(
    integrationData: Data,
    mcpData: Data
  ) -> [QuillActDestination] {
    let connectedIDs = IntegrationConnectionStore.decode(integrationData)
    let integrations = Integration.all
      .filter { connectedIDs.contains($0.identifier) }
      .map {
        QuillActDestination(
          kind: .integration($0.identifier),
          name: $0.name,
          systemImage: $0.systemImage,
          hue: $0.satelliteHue
        )
      }

    let servers = MCPServersStorage.decode(mcpData)
      .filter(\.isEnabled)
      .map { server -> QuillActDestination in
        // A known server gets its brand; an unknown one a neutral tone.
        let brand = ConnectionDirectory.brand(forServerNamed: server.name, url: server.url)
        return QuillActDestination(
          kind: .mcp(server.name),
          name: brand?.name ?? server.name,
          systemImage: brand?.systemImage ?? "puzzlepiece.extension.fill",
          hue: brand.flatMap { OKLCH(hex: $0.tintHex)?.H } ?? Self.neutralMCPHue
        )
      }

    return integrations + servers
  }

  /// Steel — for MCP servers with no brand of their own.
  private static let neutralMCPHue: Double = 250

  /// The destination a partial transcript points at, or nil if nothing has
  /// been said yet that names one.
  ///
  /// Mirrors the macOS orb's ring intuition: a server named outright beats
  /// an integration matched on a generic verb, since "linear" is a much
  /// stronger signal than "issue". This only previews the guess — the LLM
  /// parse still decides, and the user can override by tapping a chip.
  static func intuit(
    from transcript: String,
    among destinations: [QuillActDestination]
  ) -> QuillActDestination? {
    let haystack = " \(transcript.lowercased()) "
    guard haystack.count > 2 else { return nil }

    // A destination named explicitly wins outright.
    if let named = destinations.first(where: {
      haystack.contains(" \($0.name.lowercased()) ")
    }) {
      return named
    }

    // Otherwise fall back to each integration's keywords, most hits first.
    var best: (destination: QuillActDestination, hits: Int)?
    for destination in destinations {
      guard case .integration(let id) = destination.kind,
            let integration = Integration.all.first(where: { $0.identifier == id })
      else { continue }

      let hits = integration.intuitKeywords.filter { haystack.contains($0) }.count
      if hits > 0, hits > (best?.hits ?? 0) {
        best = (destination, hits)
      }
    }
    return best?.destination
  }
}

struct QuillActChips: View {
  var destinations: [QuillActDestination]
  /// Destinations excluded from routing for this capture.
  @Binding var disabled: Set<String>
  var onAdd: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: QuillTheme { .of(colorScheme) }

  /// Collapsed by default (design handoff §7): the toggle grid is a
  /// configuration surface, not something to stare at every capture.
  @State private var isExpanded = false

  private var enabled: [QuillActDestination] {
    destinations.filter { !disabled.contains($0.id) }
  }

  var body: some View {
    if destinations.isEmpty {
      // Nothing connected yet — the summary row would be an empty shell,
      // so keep the direct "Connect an app" affordance.
      QuillWrap(spacing: 7) {
        QuillAddChip(label: "Connect an app", action: onAdd)
      }
    } else if isExpanded {
      VStack(spacing: 8) {
        toggleGrid
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded = false }
        } label: {
          Text("Done")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.text2)
            .padding(.vertical, 5)
            .padding(.horizontal, 16)
            .background(Capsule().fill(theme.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    } else {
      summaryRow
    }
  }

  // MARK: - Collapsed summary

  /// Overlapping source-tinted circles + "N apps · Todoist, Gmail…" +
  /// Manage. One glance says what's routable; tap to change it.
  private var summaryRow: some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded = true }
    } label: {
      HStack(spacing: 10) {
        HStack(spacing: -7) {
          ForEach(enabled.prefix(5)) { d in
            Image(systemName: d.systemImage)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(d.palette.color())
              .frame(width: 26, height: 26)
              .background(
                Circle()
                  .fill(theme.cardSolid)
                  .overlay(Circle().fill(d.palette.color(theme.isDark ? 0.2 : 0.13)))
                  .overlay(Circle().strokeBorder(theme.hair, lineWidth: 0.5))
              )
          }
        }

        Text(summaryText)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(theme.text2)
          .lineLimit(1)

        Spacer(minLength: 6)

        HStack(spacing: 3) {
          Text("Manage")
            .font(.system(size: 13, weight: .semibold))
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(theme.text2)
      }
      .padding(.vertical, 7)
      .padding(.horizontal, 11)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(theme.hair, lineWidth: 0.5)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Connected apps: \(summaryText). Tap to manage.")
  }

  private var summaryText: String {
    let count = enabled.count
    guard count > 0 else { return "No apps enabled" }
    let names = enabled.prefix(2).map(\.name).joined(separator: ", ")
    let suffix = count > 2 ? "\(names)…" : names
    return "\(count) app\(count == 1 ? "" : "s") · \(suffix)"
  }

  // MARK: - Expanded toggle grid

  private var toggleGrid: some View {
    QuillWrap(spacing: 7) {
      ForEach(destinations) { d in
        let isOn = !disabled.contains(d.id)
        QuillChip(tint: d.palette, isOn: isOn) {
          if isOn { disabled.insert(d.id) } else { disabled.remove(d.id) }
        } label: {
          HStack(spacing: 7) {
            Image(systemName: d.systemImage)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(d.palette.color())
            Text(d.name)
              .foregroundStyle(isOn ? theme.text : theme.text2)
            if d.isMCP {
              Text("MCP")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(
                  RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(theme.hair, lineWidth: 0.5)
                )
            }
          }
        }
        .opacity(isOn ? 1 : 0.72)
      }
      QuillAddChip(action: onAdd)
    }
  }
}

// MARK: - Edit: revision commands

struct QuillEditChips: View {
  /// Commands the user reaches for most, surfaced first with a clock mark.
  var learned: [String]
  var onCommand: (String) -> Void

  // Shared with macOS via HexCore so both platforms offer the same chips.
  static let suggestions = NoteEditCommands.suggestions

  private var extras: [String] {
    learned.filter { !Self.suggestions.contains($0) }.prefix(3).map { $0 }
  }

  var body: some View {
    QuillWrap(spacing: 7) {
      ForEach(extras, id: \.self) { cmd in
        chip(cmd, isLearned: true)
      }
      ForEach(Self.suggestions, id: \.self) { cmd in
        chip(cmd, isLearned: learned.contains(cmd))
      }
    }
  }

  private func chip(_ cmd: String, isLearned: Bool) -> some View {
    let p = QuillDesign.ModePalette.edit
    return Button {
      onCommand(cmd)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isLearned ? "clock" : "sparkles")
          .font(.system(size: 12, weight: .medium))
        Text(cmd)
          .font(.system(size: 13, weight: .semibold))
      }
      .foregroundStyle(p.lightnessCapped(at: 0.84).color())
      .padding(.vertical, 6)
      .padding(.horizontal, 12)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .fill(p.color(isLearned ? 0.18 : 0.12))
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .strokeBorder(p.color(isLearned ? 0.55 : 0.4), lineWidth: 0.5)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Wrapping layout

/// A wrapping row — the sub-rows are chip clouds, not scrollers, so a long
/// destination list stays fully visible instead of hiding behind an edge.
struct QuillWrap: Layout {
  var spacing: CGFloat = 7

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let rows = layout(subviews: subviews, maxWidth: maxWidth)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: maxWidth == .infinity ? rows.map(\.width).max() ?? 0 : maxWidth, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let rows = layout(subviews: subviews, maxWidth: bounds.width)
    var y = bounds.minY
    for row in rows {
      var x = bounds.minX
      for i in row.indices {
        let size = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
          proposal: ProposedViewSize(size)
        )
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()

    for (i, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > maxWidth, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
        current.indices = [i]
        current.width = size.width
        current.height = size.height
      } else {
        current.indices.append(i)
        current.width = needed
        current.height = max(current.height, size.height)
      }
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
