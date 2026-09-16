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
  /// Composer capsule height — a minimum, so the field can grow with type.
  @ScaledMetric(relativeTo: .body) private var composerHeight: CGFloat = 48

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
  var onAsk: () -> Void
  var onRename: () -> Void
  var onShareText: () -> Void
  var onSharePDF: () -> Void
  /// True while the PDF export is building — disables the share menu so a
  /// double-tap doesn't kick off two exports.
  var isBuildingPDF: Bool = false
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
  /// True for a few seconds after an Auto capture landed here, offering to
  /// re-run it as an action instead. Same reasoning as `editError` for why
  /// it renders in the composer and not as a root status pill.
  var canRerouteToAction: Bool = false
  var onRerouteToAction: () -> Void = {}
  var onDismissReroute: () -> Void = {}

  var captureStatus: String?
  var isRecordingNote = false
  var isRecordingPaused = false
  var onStopRecording: () -> Void = {}
  var onPauseRecording: () -> Void = {}
  var onDiscardRecording: () -> Void = {}
  var savingFailed = false
  var onRetrySaving: () -> Void = {}
  var hasRecordingRecovery = false
  var onRecoverRecording: () -> Void = {}

  @ObservedObject private var notes = NotesStore.shared
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  @State private var followsLatest = true
  @State private var isAtBottom = true
  @State private var showingOriginals = false
  @State private var retryingCleanup = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showingDeleteConfirmation = false
  @State private var draft: String = ""
  @State private var isBodyEditing = false
  @State private var editingPhotoIDs: Set<UUID> = []

  var body: some View {
    VStack(spacing: 0) {
      header
      QuillNoteMeta(note: note)
        .padding(.horizontal, 20)
        // Enough of a gap that the metadata reads as a caption on the
        // header rather than as the note's first line.
        .padding(.bottom, 18)
      if savingFailed {
        Button("Couldn’t save the note. Audio retained — Retry saving", action: onRetrySaving)
          .font(.callout).padding(.horizontal)
      }
      if hasRecordingRecovery {
        Button("Recording saved for recovery — Retry transcription", action: onRecoverRecording)
          .font(.callout).padding(.horizontal)
      }
      if let record = note.transcriptions.last, let error = record.cleanupError {
        cleanupRetryCard(record: record, error: error)
      }
      if let pending = note.pendingEdit {
        editBanner(pending)
          .padding(.horizontal, 16)
          .padding(.bottom, 6)
      }
      if isBodyEditing {
        MarkdownTextEditorIOS(text: Binding(
          get: { note.body },
          set: { notes.updateBody(id: note.id, to: $0) }
        ), focusOnAppear: true)
      } else {
        bodyScroll
        if let captureStatus {
          recordingControls(captureStatus)
        } else {
          composer
        }
      }
    }
    .background(pageBackground.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .onDisappear { if isBodyEditing { finishBodyEditing() } }
    .sheet(isPresented: $showingOriginals) {
      NavigationStack {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(note.transcriptions.reversed()) { record in
              VStack(alignment: .leading, spacing: 8) {
                Text(record.recordedAt, style: .date).font(.headline)
                Text(record.recordedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                Text(record.original).textSelection(.enabled)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          }.padding()
        }
        .navigationTitle("Original Transcripts")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOriginals = false } } }
      }
    }
    .alert("Delete Note?", isPresented: $showingDeleteConfirmation) {
      Button("Delete", role: .destructive) {
        isBodyEditing = false
        editingPhotoIDs = []
        notes.deleteNote(id: note.id)
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently removes the note and all attached photos. This can't be undone.")
    }
  }

  private func beginBodyEditing() {
    guard captureStatus == nil, !retryingCleanup else { return }
    editingPhotoIDs = Set(NoteContent.photoIDs(in: note.body))
    isBodyEditing = true
  }

  private func finishBodyEditing() {
    let removed = editingPhotoIDs.subtracting(NoteContent.photoIDs(in: note.body))
    editingPhotoIDs = []
    isBodyEditing = false
    for photoID in removed {
      try? FileManager.default.removeItem(at: PhotoStore.shared.url(noteID: note.id, photoID: photoID))
      try? FileManager.default.removeItem(at: PhotoStore.shared.analysisURL(noteID: note.id, photoID: photoID))
      notes.deletePhotoFromCloud(noteID: note.id, photoID: photoID)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      Button { dismiss() } label: {
        QuillHeaderIcon(systemImage: "chevron.left")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Back")

      // Tapping the title opens the rename editor — the natural gesture,
      // which freed the header slot for the share menu.
      Button(action: onRename) {
        HStack(spacing: 8) {
          // The mode dot colours the note by how it was captured. Notes
          // don't record their capture mode yet, so this reflects the rail's
          // current mode rather than the note's history.
          Circle()
            .fill(mode.palette.color())
            .frame(width: 8, height: 8)
          Text(note.displayTitle)
            .quillFont(17, weight: .bold)
            .foregroundStyle(theme.text)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("Rename note")
      .accessibilityHint("Opens the title editor")

      if isBodyEditing {
        Button("Done", action: finishBodyEditing)
          .fontWeight(.semibold)
      }
      Menu {
        Button(action: onAsk) { Label("Ask", systemImage: "sparkle.magnifyingglass") }
        Button(action: onAddPhoto) { Label("Add Picture", systemImage: "photo") }
        shareMenu
        if !note.transcriptions.isEmpty {
          Button { showingOriginals = true } label: {
            Label("Original Transcripts", systemImage: "text.document")
          }
        }
        Divider()
        Button(role: .destructive) { showingDeleteConfirmation = true } label: {
          Label("Delete Note", systemImage: "trash")
        }
        .disabled(captureStatus != nil || retryingCleanup)
      } label: {
        QuillHeaderIcon(systemImage: "ellipsis")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Note actions")
    }
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 10)
  }

  /// Text-only or PDF — the share options from the classic note canvas,
  /// now living where the rename button used to be.
  private var shareMenu: some View {
    let text = NoteContent.stripPhotos(from: note.body)
    let hasPhotos = note.photoCount > 0

    return Menu {
      Button(action: onShareText) {
        Label("Share Text Only", systemImage: "text.alignleft")
      }
      .disabled(text.isEmpty)

      Button(action: onSharePDF) {
        Label(
          hasPhotos ? "Share as PDF (text + photos)" : "Share as PDF",
          systemImage: "doc.richtext"
        )
      }
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
        .quillFont(15, weight: .medium)
        .foregroundStyle(theme.text2)
        .frame(width: 36, height: 36)
        .background(
          Circle()
            .fill(theme.chip)
            .overlay(Circle().strokeBorder(theme.hair, lineWidth: 0.5))
        )
        .contentShape(Circle())
    }
    .disabled(isBuildingPDF)
    .opacity(isBuildingPDF ? 0.5 : 1)
    .accessibilityLabel("Share note")
  }

  // MARK: - Edit review

  /// An edit isn't committed until the user says so. The diff below plus
  /// a lossless Undo is what makes revising by voice feel safe.
  private func editBanner(_ pending: NoteEdit) -> some View {
    let edit = QuillDesign.ModePalette.edit
    return HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .quillFont(13)
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Circle().fill(edit.color()))

      VStack(alignment: .leading, spacing: 1) {
        Text(pending.label)
          .quillFont(14.5, weight: .semibold)
          .foregroundStyle(theme.text)
        Text("Review the changes below")
          .quillFont(12)
          .foregroundStyle(theme.text3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Undo") { notes.undoEdit(id: note.id) }
        .quillFont(13.5, weight: .semibold)
        .foregroundStyle(theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(theme.card)
            .overlay(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
                .strokeBorder(theme.hair, lineWidth: 1)
            )
        )
        .buttonStyle(.plain)

      Button("Keep") { notes.keepEdit(id: note.id) }
        .quillFont(13.5, weight: .bold)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(edit.color())
        )
        .buttonStyle(.plain)
    }
    .padding(11)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(edit.color(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .strokeBorder(edit.color(0.4), lineWidth: 1)
        )
    )
  }

  // MARK: - Body

  private var bodyScroll: some View {
    let liveText = note.pendingTranscription?.text ?? ""
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let pending = note.pendingEdit {
            diffView(from: pending.previousBody, to: note.body)
          } else if note.body.isEmpty, liveText.isEmpty, captureStatus == nil {
            Text("Tap to write, or hold the orb below to dictate.")
              .onTapGesture(perform: beginBodyEditing)
              .foregroundStyle(theme.text3).padding(.top, 20)
          } else {
            ForEach(Array(NoteContent.segments(from: note.body).enumerated()), id: \.offset) { _, seg in
              segmentView(seg)
            }
          }
          if !liveText.isEmpty {
            liveTranscriptionView(liveText)
          } else if captureStatus != nil {
            Text(isRecordingNote ? "Listening for speech… Audio is being recorded." : "Transcribing saved audio…")
              .foregroundStyle(theme.text2)
          }
          Color.clear.frame(height: 1).id("latest-transcript")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 16)
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 50
      } action: { _, atBottom in
        isAtBottom = atBottom
      }
      .onScrollPhaseChange { _, phase in
        if phase == .interacting { followsLatest = false }
        if phase == .idle, isAtBottom { followsLatest = true }
      }
      .onChange(of: liveText) { _, _ in
        if followsLatest { proxy.scrollTo("latest-transcript", anchor: .bottom) }
      }
      .onChange(of: note.body) { _, _ in
        if followsLatest { proxy.scrollTo("latest-transcript", anchor: .bottom) }
      }
      .onAppear {
        if captureStatus != nil { proxy.scrollTo("latest-transcript", anchor: .bottom) }
      }
      .overlay(alignment: .bottomTrailing) {
        if !followsLatest, captureStatus != nil {
          Button {
            followsLatest = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
              proxy.scrollTo("latest-transcript", anchor: .bottom)
            }
          } label: {
            Label("Jump to latest", systemImage: "arrow.down")
              .font(.callout.bold()).padding(12)
              .background(.regularMaterial, in: Capsule())
          }.padding(12)
        }
      }
    }
  }

  private func liveTranscriptionView(_ text: String) -> some View {
    let words = text.split(whereSeparator: { $0.isWhitespace })
    let chunks = stride(from: 0, to: words.count, by: 80).map {
      words[$0..<min($0 + 80, words.count)]
    }
    return VStack(alignment: .leading, spacing: 16) {
      ForEach(chunks.indices, id: \.self) { index in
        let chunk = chunks[index]
        let recentCount = index == chunks.count - 1 ? min(12, chunk.count) : 0
        let earlier = chunk.dropLast(recentCount).joined(separator: " ")
        let recent = chunk.suffix(recentCount).joined(separator: " ")
        (Text(earlier + (earlier.isEmpty || recent.isEmpty ? "" : " ")).foregroundColor(theme.text2)
          + Text(recent).foregroundColor(theme.text).bold())
          .quillFont(16)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func cleanupRetryCard(record: NoteTranscription, error: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "sparkles")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(QuillDesign.brand.color())
          .frame(width: 36, height: 36)
          .background(QuillDesign.brand.color().opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 4) {
          Text(retryingCleanup ? "Cleaning up…" : "Your transcript is safe")
            .quillFont(15, weight: .semibold)
            .foregroundStyle(theme.text)
          Text(retryingCleanup ? "You can keep reading while Quill tries again." : "Cleanup didn’t finish. Try again whenever you’re ready.")
            .quillFont(13)
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(spacing: 12) {
        Button { showingOriginals = true } label: {
          Text("View original").quillFont(13, weight: .semibold)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
        Spacer(minLength: 0)
        Button {
          retryingCleanup = true
          Task {
            await notes.retryCleanup(noteID: note.id, recordID: record.id)
            retryingCleanup = false
          }
        } label: {
          HStack(spacing: 6) {
            if retryingCleanup { ProgressView().controlSize(.small).tint(.white) }
            else { Image(systemName: "arrow.clockwise") }
            Text(retryingCleanup ? "Retrying…" : "Retry cleanup")
          }
          .quillFont(13, weight: .semibold)
          .foregroundStyle(.white)
          .padding(.horizontal, 12).frame(minHeight: 44)
          .background(QuillDesign.brand.color(), in: RoundedRectangle(cornerRadius: QuillDesign.Radius.chip))
        }
        .buttonStyle(.plain)
        .disabled(retryingCleanup || captureStatus != nil)
      }
      DisclosureGroup("Details") {
        Text(error).font(.caption).foregroundStyle(theme.text2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .font(.caption)
      .foregroundStyle(theme.text3)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(theme.card)
        .overlay(RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
          .strokeBorder(theme.hair, lineWidth: 0.5))
    )
    .padding(.horizontal, 16).padding(.bottom, 10)
  }

  private func recordingControls(_ status: String) -> some View {
    HStack(spacing: 14) {
      if !isRecordingNote { ProgressView().controlSize(.small) }
      VStack(alignment: .leading, spacing: 3) {
        Text(status).font(.callout.bold())
        Text(isRecordingNote ? "Live preview · recording audio" : "Your text stays here until processing finishes")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if isRecordingNote {
        Button(action: onPauseRecording) {
          Image(systemName: isRecordingPaused ? "play.fill" : "pause.fill").frame(width: 44, height: 44)
        }.accessibilityLabel(isRecordingPaused ? "Resume recording" : "Pause recording")
        Button("Stop", action: onStopRecording).buttonStyle(.borderedProminent)
        Menu {
          Button("Discard recording", role: .destructive, action: onDiscardRecording)
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
        .accessibilityLabel("Recording options")
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 11)
    .padding(.bottom, 8)
    .background(composerBackground)
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
              .quillFont(12, design: .monospaced)
              .foregroundStyle(gutterColor(row.kind, removed: removed, added: added))
              .frame(width: 14, alignment: .leading)

            Text(row.text.replacingOccurrences(of: "**", with: ""))
              .quillFont(16, weight: row.text.hasPrefix("**") ? .bold : .regular)
              .foregroundStyle(row.kind == .removed ? removed.color() : theme.text)
              .strikethrough(row.kind == .removed)
              .opacity(row.kind == .removed ? 0.7 : 1)
              .padding(.horizontal, row.kind == .added ? 5 : 0)
              .padding(.vertical, row.kind == .added ? 1 : 0)
              .background(
                RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
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
      .contentShape(Rectangle())
      .onTapGesture(perform: beginBodyEditing)
      .accessibilityAction(named: "Edit note", beginBodyEditing)
    case .photo(let photoID):
      VStack(alignment: .leading, spacing: 8) {
        if let ui = PhotoStore.shared.loadImage(noteID: note.id, photoID: photoID) {
          Image(uiImage: ui)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
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
          .quillFont(14)
          .foregroundStyle(theme.text)
        ForEach(analysis.keyDetails, id: \.self) { detail in
          HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(theme.text3)
            Text(detail)
          }
          .quillFont(13)
          .foregroundStyle(theme.text2)
        }
        if let transcribed = analysis.transcribedText, !transcribed.isEmpty {
          Text(transcribed)
            .quillFont(13, design: .monospaced)
            .foregroundStyle(theme.text2)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
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
          .quillFont(13)
        Text(message)
          .quillFont(13)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Image(systemName: "xmark")
          .quillFont(11, weight: .semibold)
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

  /// "Saved as a note — meant it as a command?" Takes the chip row's slot
  /// for a few seconds after an Auto capture lands, then gets out of the way.
  /// The transcript still exists, so this costs a tap instead of a re-take.
  private var rerouteBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "note.text")
        .quillFont(13)
        .foregroundStyle(theme.text3)

      Text("Saved as a note")
        .quillFont(13)
        .foregroundStyle(theme.text2)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      Button(action: onRerouteToAction) {
        HStack(spacing: 5) {
          Image(systemName: "bolt.fill")
            .quillFont(11, weight: .bold)
          Text("Run as action")
            .quillFont(13, weight: .semibold)
        }
        .foregroundStyle(QuillDesign.ModePalette.act.lightnessCapped(at: theme.isDark ? 0.84 : 0.44).color())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .fill(QuillDesign.ModePalette.act.color(0.18))
        )
      }
      .buttonStyle(.plain)

      Button(action: onDismissReroute) {
        Image(systemName: "xmark")
          .quillFont(11, weight: .semibold)
          .foregroundStyle(theme.text3)
          .padding(4)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Keep as a note")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(theme.chip)
    )
  }

  // MARK: - Composer

  private var composer: some View {
    VStack(spacing: 10) {
      QuillModeRail(mode: $mode, order: QuillMode.noteOrder, compact: true)

      if isEditing {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Revising…")
            .quillFont(13)
            .foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if let editError {
        editErrorBanner(editError)
      } else if canRerouteToAction {
        rerouteBanner
      } else {
        subRow
      }

      HStack(spacing: 11) {
        HStack(spacing: 9) {
          TextField(placeholder, text: $draft)
            .quillFont(16)
            .foregroundStyle(theme.text)
            .submitLabel(.send)
            .onSubmit(send)

          if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            Button(action: send) {
              Image(systemName: "arrow.up")
                .quillFont(16, weight: .semibold)
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
        .frame(minHeight: composerHeight)
        .glassEffect(.regular.interactive(), in: .capsule)

        if draft.trimmingCharacters(in: .whitespaces).isEmpty {
          QuillTriggerButton(
            mode: mode,
            onTap: onTapTrigger,
            onHold: onHoldTrigger,
            onRelease: onReleaseTrigger,
            size: 48,
            slot: .inlineTrigger
          )
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 11)
    .padding(.bottom, 8)
    .background(composerBackground)
  }

  /// Shared chrome keeps recording and composing in the same visual surface.
  private var composerBackground: some View {
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
  }

  @ViewBuilder
  private var subRow: some View {
    switch mode {
    case .dictate:
      QuillFormatChips(format: $format, hidden: hiddenFormats, onAddCustom: onAddFormat)
    case .edit:
      QuillEditMenu(learned: learnedEditCommands, onCommand: onEditCommand)
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
