//
//  ActDestinationChips.swift
//  Quill (macOS)
//
//  The Mac port of the iOS Act chip row (`QuillActChips`): collapsed to a
//  stacked-icon summary by default, expanding into a toggle grid on
//  "Manage". Same model (`QuillActDestination`, in HexCore), same
//  collapse-by-default behaviour, same "+ Add" → Connections escape hatch.
//
//  Muting a destination here is not decoration: the muted set narrows what
//  the planner is shown, exactly like an `@` mention pins it. See
//  `ActTargeting`.
//

import HexCore
import SwiftUI

struct ActDestinationChips: View {
  var destinations: [QuillActDestination]
  /// Destination IDs excluded from routing.
  @Binding var muted: Set<String>
  /// Jump to the Integrations/Connections tab.
  var onAdd: () -> Void

  @State private var isExpanded = false

  private var enabled: [QuillActDestination] {
    destinations.filter { !muted.contains($0.id) }
  }

  var body: some View {
    if destinations.isEmpty {
      addChip(label: "Connect an app")
    } else if isExpanded {
      VStack(alignment: .leading, spacing: 8) {
        toggleGrid
        Button {
          QuillMotion.run(.easeInOut(duration: 0.2)) { isExpanded = false }
        } label: {
          Text("Done")
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    } else {
      summaryRow
    }
  }

  // MARK: - Collapsed summary

  private var summaryRow: some View {
    Button {
      QuillMotion.run(.easeInOut(duration: 0.2)) { isExpanded = true }
    } label: {
      HStack(spacing: 9) {
        HStack(spacing: -7) {
          ForEach(enabled.prefix(5)) { destination in
            Image(systemName: destination.systemImage)
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(destination.palette.color())
              .frame(width: 24, height: 24)
              .background(
                Circle()
                  .fill(Color(nsColor: .windowBackgroundColor))
                  .overlay(Circle().fill(destination.palette.color(0.15)))
                  .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
              )
          }
        }

        Text(summaryText)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 6)

        HStack(spacing: 3) {
          Text("Manage")
            .font(.system(size: 12, weight: .semibold))
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 10)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(Color.primary.opacity(0.04))
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Choose which apps this command can reach")
    // The stacked marks are decorative — the summary text already names the
    // destinations, so this reads as one control rather than N images.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Destinations: \(summaryText)")
    .accessibilityHint("Choose which apps this command can reach")
    .accessibilityLabel("Connected apps: \(summaryText). Click to manage.")
  }

  private var summaryText: String {
    let count = enabled.count
    guard count > 0 else { return "No apps enabled" }
    let names = enabled.prefix(2).map(\.name).joined(separator: ", ")
    let suffix = count > 2 ? "\(names)…" : names
    return "\(count) app\(count == 1 ? "" : "s") · \(suffix)"
  }

  // MARK: - Expanded grid

  private var toggleGrid: some View {
    ActWrapLayout(spacing: 7) {
      ForEach(destinations) { destination in
        let isOn = !muted.contains(destination.id)
        Button {
          if isOn { muted.insert(destination.id) } else { muted.remove(destination.id) }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: destination.systemImage)
              .font(.system(size: 11.5, weight: .medium))
              .foregroundStyle(destination.palette.color())
            Text(destination.name)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(isOn ? .primary : .secondary)
            if destination.isMCP {
              Text("MCP")
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1)
                .overlay(
                  RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5)
                )
            }
          }
          .padding(.vertical, 5)
          .padding(.horizontal, 9)
          .background(
            Capsule()
              .fill(isOn ? destination.palette.color(0.13) : Color.primary.opacity(0.04))
              .overlay(
                Capsule().strokeBorder(
                  isOn ? destination.palette.color(0.45) : Color.primary.opacity(0.08),
                  lineWidth: 1
                )
              )
          )
          .opacity(isOn ? 1 : 0.6)
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "\(destination.name) is routable — click to mute" : "Muted — click to allow")
    .accessibilityLabel(destination.name)
    .accessibilityValue(isOn ? "Routable" : "Muted")
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
      }

      addChip(label: "Add")
    }
  }

  private func addChip(label: String) -> some View {
    Button(action: onAdd) {
      HStack(spacing: 5) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .bold))
        Text(label)
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundStyle(.secondary)
      .padding(.vertical, 5)
      .padding(.horizontal, 9)
      .background(
        Capsule().strokeBorder(
          Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Connect another app or MCP server")
        .accessibilityLabel("Connect another app or MCP server")
  }
}

/// Left-aligned wrapping row. (NotesView has a private twin for the
/// note-edit chips; this one is scoped to the Act surfaces.)
struct ActWrapLayout: Layout {
  var spacing: CGFloat = 7

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var totalWidth: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight + spacing
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
        rowHeight = max(rowHeight, size.height)
      }
    }
    totalWidth = max(totalWidth, rowWidth)
    totalHeight += rowHeight
    return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
