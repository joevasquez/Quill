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
//    • Edit    → alphabetized revision commands
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
    .glassEffect(in: .rect(cornerRadius: QuillDesign.Radius.panel))
  }

  private func railButton(_ m: QuillMode) -> some View {
    let isOn = mode == m
    let p = m.palette

    return Button {
      QuillMotion.run(.easeInOut(duration: 0.18)) { mode = m }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: m.systemImage)
          .quillFont(15, weight: isOn ? .semibold : .medium)
        Text(m.label)
          .quillFont(14.5, weight: isOn ? .bold : .medium)
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
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(isOn ? p.color(0.14) : .clear)
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
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
        .quillFont(13, weight: isOn ? .semibold : .medium)
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
          .quillFont(11, weight: .semibold)
        Text(label)
          .quillFont(13, weight: .medium)
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

// MARK: - Shared dropdown trigger

/// Identical chrome for format selection, edit commands, and app routing.
private struct QuillDropdownLabel: View {
  let title: String
  let systemImage: String
  let tint: OKLCH
  var accessory: String = "chevron.down"

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let theme = QuillTheme.of(colorScheme)
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .quillFont(13, weight: .medium)
      Text(title)
        .quillFont(13, weight: .semibold)
        .lineLimit(1)
        .truncationMode(.tail)
      Image(systemName: accessory)
        .quillFont(9, weight: .semibold)
        .opacity(0.7)
    }
    .foregroundStyle(tint.lightnessCapped(at: theme.isDark ? 0.82 : 0.5).color())
    .padding(.vertical, 7)
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(tint.color(0.13))
        .overlay(RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .strokeBorder(tint.color(0.5), lineWidth: 0.5))
    )
    .frame(minHeight: 44)
    .contentShape(Rectangle())
  }
}

// MARK: - Dictate: format sub-filters

/// Format is single-select, so it reads as a dropdown, not a chip cloud:
/// the active format uses the shared dropdown trigger to open all
/// formats with a check on the current one and an "Add format…" row under
/// a divider. (Contrast with Act, which is multi-select → summary + grid.)
struct QuillFormatChips: View {
  @Binding var format: AIProcessingMode
  /// Built-ins the user has hidden in Settings.
  var hidden: Set<AIProcessingMode> = []
  var onAddCustom: () -> Void

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
      QuillDropdownLabel(title: format.iosDisplayName, systemImage: format.iosIconName, tint: QuillDesign.ModePalette.dictate)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Format: \(format.iosDisplayName)")
    .accessibilityHint("Opens the format menu")
  }

}

// MARK: - Act: destinations
//
// `QuillActDestination` moved to HexCore (Models/ActDestination.swift) so the
// macOS Home command bar offers the same destinations, in the same order,
// with the same brand visuals.

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
      Button(action: onAdd) {
        QuillDropdownLabel(title: "Connect an app", systemImage: "app.connected.to.app.below.fill", tint: QuillDesign.ModePalette.act, accessory: "plus")
      }
      .buttonStyle(.plain)
    } else {
      VStack(spacing: 8) {
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
          QuillDropdownLabel(title: summaryText, systemImage: "square.grid.2x2", tint: QuillDesign.ModePalette.act,
                             accessory: isExpanded ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connected apps: \(summaryText)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides app routing options")
        if isExpanded { toggleGrid }
      }
    }
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
              .quillFont(13, weight: .medium)
              .foregroundStyle(d.palette.color())
            Text(d.name)
              .foregroundStyle(isOn ? theme.text : theme.text2)
            if d.isMCP {
              Text("MCP")
                .quillFont(9, weight: .heavy)
                .tracking(0.4)
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(
                  RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
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

struct QuillEditMenu: View {
  var learned: [String]
  var onCommand: (String) -> Void

  private var commands: [String] {
    Array(Set(NoteEditCommands.suggestions + learned))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  var body: some View {
    Menu {
      ForEach(commands, id: \.self) { command in
        Button(command) { onCommand(command) }
      }
    } label: {
      QuillDropdownLabel(title: "Edit options", systemImage: "sparkles", tint: QuillDesign.ModePalette.edit)
    }
    .buttonStyle(.plain)
    .menuOrder(.fixed)
    .accessibilityHint("Choose an editing command, listed alphabetically")
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
