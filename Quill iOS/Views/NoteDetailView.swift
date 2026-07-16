//
//  NoteDetailView.swift
//  Quill (iOS)
//
//  A note, open. Home starts captures; this is where they land and where
//  you add to them.
//
//  Layout (design handoff §6): back / title / compose header, a meta row,
//  the body, and a pinned glass composer carrying the note's own mode rail
//  — Dictate to add, Edit to revise, Act to do something with it.
//
//  The body renders the same segment model as before (text + inline photos
//  + analysis cards), so photos, checkboxes, share, PDF export and the
//  markdown editor all keep working.
//

import HexCore
import SwiftUI

struct NoteDetailView: View {
  let note: Note

  @Binding var mode: QuillMode
  @Binding var format: AIProcessingMode
  @Binding var mutedDestinations: Set<String>

  var destinations: [QuillActDestination]
  var hiddenFormats: Set<AIProcessingMode>
  var learnedEditCommands: [String]

  var onTapTrigger: () -> Void
  var onHoldTrigger: () -> Void
  var onReleaseTrigger: () -> Void
  var onSendText: (String) -> Void
  var onEditCommand: (String) -> Void
  var onAddPhoto: () -> Void
  var onEditBody: () -> Void
  var onRename: () -> Void
  var onAddDestination: () -> Void
  var onAddFormat: () -> Void
  /// True while a revision is in flight — an edit takes a beat, so the
  /// composer says so rather than looking inert.
  var isEditing: Bool = false
  /// Why the last edit didn't land. Shown in the composer: the home
  /// screen's status pill can't be seen from here (it lives on the
  /// navigation root, under this view), so a failed edit was silently
  /// doing nothing at all.
  var editError: String?
  var onDismissEditError: () -> Void = {}

  @ObservedObject private var notes = NotesStore.shared
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  @State private var draft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      QuillNoteMeta(note: note)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
      if let pending = note.pendingEdit {
        editBanner(pending)
          .padding(.horizontal, 16)
          .padding(.bottom, 6)
      }
      bodyScroll
      composer
    }
    .background(pageBackground.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      roundButton("chevron.left", "Back") { dismiss() }

      HStack(spacing: 8) {
        // The mode dot colours the note by how it was captured. Notes
        // don't record their capture mode yet, so this reflects the rail's
        // current mode rather than the note's history.
        Circle()
          .fill(mode.palette.color())
          .frame(width: 8, height: 8)
        Text(note.displayTitle)
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(theme.text)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      roundButton("textformat", "Rename", action: onRename)
      roundButton("camera", "Add photo", action: onAddPhoto)
      roundButton("square.and.pencil", "Edit text", tint: QuillDesign.brand.color(), action: onEditBody)
    }
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 10)
  }

  private func roundButton(
    _ symbol: String,
    _ label: String,
    tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(tint ?? theme.text2)
        .frame(width: 36, height: 36)
        .background(
          Circle()
            .fill(theme.chip)
            .overlay(Circle().strokeBorder(theme.hair, lineWidth: 0.5))
        )
        .contentShape(Circle())
    }
    .buttonStyle(QuillPressStyle())
    .accessibilityLabel(label)
  }

  // MARK: - Edit review

  /// An edit isn't committed until the user says so. The diff below plus
  /// a lossless Undo is what makes revising by voice feel safe.
  private func editBanner(_ pending: NoteEdit) -> some View {
    let edit = QuillDesign.ModePalette.edit
    return HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Circle().fill(edit.color()))

      VStack(alignment: .leading, spacing: 1) {
        Text(pending.label)
          .font(.system(size: 14.5, weight: .semibold))
          .foregroundStyle(theme.text)
        Text("Review the changes below")
          .font(.system(size: 12))
          .foregroundStyle(theme.text3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Undo") { notes.undoEdit(id: note.id) }
        .font(.system(size: 13.5, weight: .semibold))
        .foregroundStyle(theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.card)
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.hair, lineWidth: 1)
            )
        )
        .buttonStyle(.plain)

      Button("Keep") { notes.keepEdit(id: note.id) }
        .font(.system(size: 13.5, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(edit.color())
        )
        .buttonStyle(.plain)
    }
    .padding(11)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(edit.color(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(edit.color(0.4), lineWidth: 1)
        )
    )
  }

  // MARK: - Body

  private var bodyScroll: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let pending = note.pendingEdit {
          diffView(from: pending.previousBody, to: note.body)
        } else if note.body.isEmpty {
          Text("Empty — hold the orb below to start dictating.")
            .font(.system(size: 16.5))
            .italic()
            .foregroundStyle(theme.text3)
            .padding(.top, 20)
        } else {
          ForEach(Array(NoteContent.segments(from: note.body).enumerated()), id: \.offset) { _, seg in
            segmentView(seg)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20)
      .padding(.bottom, 16)
    }
  }

  /// Removed lines struck through in red with a `−` gutter; additions
  /// highlighted green with a `+`.
  private func diffView(from before: String, to after: String) -> some View {
    let removed = OKLCH(0.6, 0.17, 25)
    let added = QuillDesign.ModePalette.resolved

    return VStack(alignment: .leading, spacing: 6) {
      ForEach(LineDiff.rows(from: before, to: after)) { row in
        if row.text.trimmingCharacters(in: .whitespaces).isEmpty {
          Color.clear.frame(height: 8)
        } else {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(gutter(row.kind))
              .font(.system(size: 12, design: .monospaced))
              .foregroundStyle(gutterColor(row.kind, removed: removed, added: added))
              .frame(width: 14, alignment: .leading)

            Text(row.text.replacingOccurrences(of: "**", with: ""))
              .font(.system(size: 16, weight: row.text.hasPrefix("**") ? .bold : .regular))
              .foregroundStyle(row.kind == .removed ? removed.color() : theme.text)
              .strikethrough(row.kind == .removed)
              .opacity(row.kind == .removed ? 0.7 : 1)
              .padding(.horizontal, row.kind == .added ? 5 : 0)
              .padding(.vertical, row.kind == .added ? 1 : 0)
              .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                  .fill(row.kind == .added ? added.color(0.16) : .clear)
              )
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  private func gutter(_ kind: LineDiff.Kind) -> String {
    switch kind {
    case .removed: "−"
    case .added: "+"
    case .unchanged: ""
    }
  }

  private func gutterColor(_ kind: LineDiff.Kind, removed: OKLCH, added: OKLCH) -> Color {
    switch kind {
    case .removed: removed.color()
    case .added: added.lightnessCapped(at: 0.55).color()
    case .unchanged: theme.text3
    }
  }

  @ViewBuilder
  private func segmentView(_ seg: NoteSegment) -> some View {
    switch seg {
    case .text(let text):
      NoteTextView(
        text: text,
        headingColor: QuillDesign.brand.color(),
        onToggleCheckbox: { lineIndex in
          toggleCheckbox(segmentText: text, lineIndex: lineIndex)
        }
      )
      .textSelection(.enabled)
    case .photo(let photoID):
      VStack(alignment: .leading, spacing: 8) {
        if let ui = PhotoStore.shared.loadImage(noteID: note.id, photoID: photoID) {
          Image(uiImage: ui)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.chip)
            .frame(height: 80)
            .overlay(
              Label("Missing photo", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(theme.text3)
            )
        }
        analysisCard(photoID: photoID)
      }
    }
  }

  @ViewBuilder
  private func analysisCard(photoID: UUID) -> some View {
    if notes.analyzingPhotoIDs.contains(photoID) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Analyzing photo…")
          .font(.caption)
          .foregroundStyle(theme.text3)
      }
    } else if let analysis = notes.photoAnalyses[photoID] {
      VStack(alignment: .leading, spacing: 6) {
        Text(analysis.summary)
          .font(.system(size: 14))
          .foregroundStyle(theme.text)
        ForEach(analysis.keyDetails, id: \.self) { detail in
          HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(theme.text3)
            Text(detail)
          }
          .font(.system(size: 13))
          .foregroundStyle(theme.text2)
        }
        if let transcribed = analysis.transcribedText, !transcribed.isEmpty {
          Text(transcribed)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(theme.text2)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(theme.hair, lineWidth: 0.5)
          )
      )
    } else if let error = notes.analysisErrors[photoID] {
      Text(error)
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  /// Flip a `- [ ]` / `- [x]` marker. The canvas renders body *segments*
  /// (text between photo tokens), so the toggle runs on the segment and
  /// the edited segment is spliced back at its first occurrence.
  private func toggleCheckbox(segmentText: String, lineIndex: Int) {
    guard let toggled = MarkdownCheckbox.toggleLine(lineIndex, in: segmentText),
          let range = note.body.range(of: segmentText)
    else { return }
    var body = note.body
    body.replaceSubrange(range, with: toggled)
    notes.updateBody(id: note.id, to: body)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  /// Replaces the command chips while an error stands, so the failure is
  /// impossible to miss and tapping it clears back to the chips.
  private func editErrorBanner(_ message: String) -> some View {
    Button(action: onDismissEditError) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 13))
        Text(message)
          .font(.system(size: 13))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(QuillDesign.ModePalette.edit.lightnessCapped(at: theme.isDark ? 0.82 : 0.46).color())
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .fill(QuillDesign.ModePalette.edit.color(0.14))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Dismisses this message")
  }

  // MARK: - Composer

  private var composer: some View {
    VStack(spacing: 10) {
      QuillModeRail(mode: $mode, order: QuillMode.noteOrder, compact: true)

      if isEditing {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Revising…")
            .font(.system(size: 13))
            .foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if let editError {
        editErrorBanner(editError)
      } else {
        subRow
      }

      HStack(spacing: 11) {
        HStack(spacing: 9) {
          TextField(placeholder, text: $draft)
            .font(.system(size: 16))
            .foregroundStyle(theme.text)
            .submitLabel(.send)
            .onSubmit(send)

          if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            Button(action: send) {
              Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(mode.palette.color()))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send")
          }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 48)
        .background(
          Capsule()
            .fill(theme.field)
            .overlay(Capsule().strokeBorder(theme.fieldRing, lineWidth: 1))
        )

        if draft.trimmingCharacters(in: .whitespaces).isEmpty {
          QuillTriggerButton(
            mode: mode,
            onTap: onTapTrigger,
            onHold: onHoldTrigger,
            onRelease: onReleaseTrigger,
            size: 48,
            orbSize: 44
          )
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 11)
    .padding(.bottom, 8)
    .background(
      UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
        .fill(theme.glass)
        .background(
          UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
          Rectangle().fill(theme.hair).frame(height: 0.5)
        }
        .ignoresSafeArea(edges: .bottom)
    )
  }

  @ViewBuilder
  private var subRow: some View {
    switch mode {
    case .dictate:
      QuillFormatChips(format: $format, hidden: hiddenFormats, onAddCustom: onAddFormat)
    case .edit:
      QuillEditChips(learned: learnedEditCommands, onCommand: onEditCommand)
    case .act:
      QuillActChips(destinations: destinations, disabled: $mutedDestinations, onAdd: onAddDestination)
    case .auto:
      EmptyView()
    }
  }

  private var placeholder: String {
    switch mode {
    case .edit: "Edit this note — e.g. shorten by 20%"
    case .act: "Act on this note…"
    default: "Add to this note…"
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draft = ""
    if mode == .edit {
      onEditCommand(text)
    } else {
      onSendText(text)
    }
  }

  private var pageBackground: some View {
    Group {
      if theme.isDark {
        RadialGradient(
          gradient: Gradient(colors: theme.pageGradient),
          center: UnitPoint(x: 0.5, y: -0.08),
          startRadius: 0,
          endRadius: 900
        )
      } else {
        LinearGradient(
          gradient: Gradient(colors: theme.pageGradient),
          startPoint: .top,
          endPoint: .bottom
        )
      }
    }
  }
}
