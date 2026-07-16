//
//  QuillActiveNoteStrip.swift
//  Quill (iOS)
//
//  Compact "you're working on this note" strip. Sits below
//  `QuillHeaderBar` on every screen attached to a specific note so the
//  user has a consistent context frame — note title, location, time,
//  word count — and a tap-to-rename affordance.
//
//  Extracted from ContentView for the same reason as QuillHeaderBar:
//  upcoming screens (empty home, recording, action-confirmation) can
//  drop this in without duplicating the metadata logic.
//

import SwiftUI

struct QuillActiveNoteStrip: View {
  /// The currently-active note, if any. When `nil` the strip renders a
  /// muted "tap record to start" placeholder so the row doesn't
  /// suddenly collapse mid-flow.
  let activeNote: Note?
  /// Tap-to-rename. Called only when `activeNote != nil`; otherwise the
  /// title row is non-interactive.
  let onTapRename: () -> Void
  /// When non-nil, the strip swaps its right-edge metadata for a live
  /// recording indicator (red dot + elapsed timer). `nil` = idle.
  var recordingElapsed: TimeInterval? = nil

  var body: some View {
    HStack(spacing: 12) {
      // Translucent-lavender chip with a Quill-purple edit-text glyph.
      // Background: rgba(192,132,252,0.22), glyph: #7c3aed. Reads as a
      // soft "this is your note context" badge — not a button itself
      // (the rename affordance lives on the title row).
      Image(systemName: "square.and.pencil")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color(red: 0.486, green: 0.227, blue: 0.929))
        .frame(width: 32, height: 32)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(red: 0.753, green: 0.518, blue: 0.988).opacity(0.22))
        )

      Button(action: onTapRename) {
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 4) {
            Text(activeNote?.displayTitle ?? "No active note")
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .foregroundStyle(.primary)
            if activeNote != nil {
              Image(systemName: "pencil")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .buttonStyle(.plain)
      .disabled(activeNote == nil)
      .accessibilityLabel("Rename active note")

      Spacer()

      // Live recording indicator — red pulsing dot + monospaced
      // elapsed time. Sits in the slot the metadata would otherwise
      // occupy so the strip height stays stable when recording starts.
      if let elapsed = recordingElapsed {
        HStack(spacing: 6) {
          Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .modifier(PulsingOpacity())
          Text(formatElapsed(elapsed))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.red)
            .monospacedDigit()
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Rectangle().fill(.ultraThinMaterial))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.06))
        .frame(height: 0.5)
    }
  }

  private var subtitle: String {
    guard let note = activeNote else {
      return "Tap record to start your first note"
    }
    // Subtitle stays static even while recording — the red dot +
    // timer on the right edge of the strip is the live indicator,
    // and stuffing "recording…" into the subtitle just adds noise.
    var parts: [String] = []
    if let place = note.location?.placeName {
      parts.append(place)
    }
    parts.append("Updated \(note.updatedAt.quillRelativeFormatted().lowercased())")
    if recordingElapsed == nil {
      parts.append("\(note.wordCount) words")
    }
    return parts.joined(separator: " · ")
  }

  private func formatElapsed(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%d:%02d", m, s)
  }
}

/// Pulses opacity 1.0 → 0.4 → 1.0 every ~1.2s. Used by the recording
/// dot — gentle enough not to be distracting, distinct enough to read
/// as "active" rather than a static decorative dot.
private struct PulsingOpacity: ViewModifier {
  @State private var dim = false

  func body(content: Content) -> some View {
    content
      .opacity(dim ? 0.4 : 1.0)
      .onAppear {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
          dim = true
        }
      }
  }
}

// MARK: - Date formatting (mirrors macOS Date.relativeFormatted)

extension Date {
  func quillRelativeFormatted() -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(self) { return "Today" }
    if calendar.isDateInYesterday(self) { return "Yesterday" }
    if let daysAgo = calendar.dateComponents([.day], from: self, to: Date()).day,
       daysAgo < 7 {
      let f = DateFormatter()
      f.dateFormat = "EEEE"
      return f.string(from: self)
    }
    return self.formatted(date: .abbreviated, time: .omitted)
  }
}
