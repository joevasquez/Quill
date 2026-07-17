#if os(macOS)
import AppKit
import ComposableArchitecture
import HexCore
import Sharing
import SwiftUI

// MARK: - Shared selection state

/// Observable object that bridges note selection between the sidebar list
/// (in AppView) and the detail editor (in NotesView). Singleton so both
/// views stay in sync without threading state through TCA.
@MainActor
final class NoteSelectionState: ObservableObject {
  static let shared = NoteSelectionState()
  @Published var selectedNoteID: UUID?
  private init() {}
}

// MARK: - Sidebar list (hosted in the AppView sidebar)

struct NotesSidebarList: View {
  @ObservedObject private var cloudSync = MacCloudSync.shared
  @ObservedObject private var selection = NoteSelectionState.shared
  @State private var searchQuery: String = ""

  private var sortedNotes: [SyncableNote] {
    cloudSync.cloudNotes.sorted { $0.updatedAt > $1.updatedAt }
  }

  /// Notes filtered by the current search query. Case-insensitive
  /// substring match against title, body (photo tokens stripped), and
  /// location — mirrors the iOS `NotesListView` behavior.
  private var visibleNotes: [SyncableNote] {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return sortedNotes }
    return sortedNotes.filter { note in
      let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty, title.localizedCaseInsensitiveContains(trimmed) { return true }
      let textBody = NoteContent.stripPhotos(from: note.body)
      if textBody.localizedCaseInsensitiveContains(trimmed) { return true }
      if let place = note.placeName,
         place.localizedCaseInsensitiveContains(trimmed) { return true }
      return false
    }
  }

  var body: some View {
    if sortedNotes.isEmpty {
      VStack(spacing: 12) {
        Spacer()
        Image(systemName: "note.text")
          .font(.system(size: 36))
          .foregroundStyle(.tertiary)
        Text("No notes yet")
          .font(.headline)
        Button {
          createNewNote()
        } label: {
          Label("New Note", systemImage: "square.and.pencil")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        if cloudSync.isGoogleAuthorized() {
          Text("Notes sync to the cloud so you can access them from your iPhone.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(selection: $selection.selectedNoteID) {
        if visibleNotes.isEmpty {
          ContentUnavailableView.search(text: searchQuery)
        } else {
          ForEach(visibleNotes) { note in
            NoteListRow(note: note, isDirty: cloudSync.dirtyNoteIDs.contains(note.id))
              .tag(Optional(note.id))
          }
        }
      }
      .listStyle(.sidebar)
      .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search notes")
    }
  }

  private func createNewNote() {
    let now = Date()
    let note = SyncableNote(
      id: UUID(),
      title: "",
      body: "",
      createdAt: now,
      updatedAt: now,
      isAutoTitle: true,
      sourceDevice: Host.current().localizedName ?? "Mac",
      sourcePlatform: .macOS
    )
    cloudSync.cloudNotes.insert(note, at: 0)
    selection.selectedNoteID = note.id
    cloudSync.markDirty(id: note.id)
  }
}

// MARK: - Row

private struct NoteListRow: View {
  let note: SyncableNote
  let isDirty: Bool

  private var displayTitle: String {
    let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    let stripped = NoteContent.stripPhotos(from: note.body)
    let firstLine = stripped.components(separatedBy: .newlines).first ?? stripped
    let words = firstLine.split(separator: " ", omittingEmptySubsequences: true).prefix(6).joined(separator: " ")
    return words.isEmpty ? "New Note" : String(words.prefix(60))
  }

  private var preview: String {
    let cleaned = NoteContent.stripPhotos(from: note.body)
    return String(cleaned.prefix(120))
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(displayTitle)
          .font(.headline)
          .lineLimit(1)
        if !preview.isEmpty {
          Text(preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 6) {
          Text(note.updatedAt, format: .relative(presentation: .named))
            .font(.caption2)
            .foregroundStyle(.tertiary)
          if note.sourcePlatform == .iOS {
            Label("iOS", systemImage: "iphone")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
      Spacer(minLength: 4)
      if isDirty {
        Circle()
          .fill(Color.orange)
          .frame(width: 8, height: 8)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Detail view (full-width editor, hosted in the detail pane)

struct NotesView: View {
  @ObservedObject private var cloudSync = MacCloudSync.shared
  @ObservedObject private var photoStore = MacPhotoStore.shared
  @ObservedObject private var selection = NoteSelectionState.shared
  @Shared(.hexSettings) private var hexSettings
  @State private var isManuallyRefreshing = false
  @State private var showDeleteConfirmation = false
  @State private var noteToDelete: UUID?

  private var sortedNotes: [SyncableNote] {
    cloudSync.cloudNotes.sorted { $0.updatedAt > $1.updatedAt }
  }

  var body: some View {
    Group {
      if let id = selection.selectedNoteID,
         let noteIndex = cloudSync.cloudNotes.firstIndex(where: { $0.id == id }) {
        NoteEditorView(
          note: $cloudSync.cloudNotes[noteIndex],
          photoStore: photoStore,
          isDirty: cloudSync.dirtyNoteIDs.contains(id),
          onSync: { syncNote(id: id) },
          onMarkDirty: { cloudSync.markDirty(id: id) },
          onDelete: {
            noteToDelete = id
            showDeleteConfirmation = true
          }
        )
      } else {
        notesLandingView
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        newNoteButton
      }
    }
    .task {
      refresh()
    }
    .alert("Delete Note", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {
        noteToDelete = nil
      }
      Button("Delete", role: .destructive) {
        if let id = noteToDelete {
          deleteNote(id: id)
        }
        noteToDelete = nil
      }
    } message: {
      Text("Are you sure you want to delete this note? This cannot be undone.")
    }
  }

  // MARK: - Landing (no note selected)

  @ViewBuilder
  private var notesLandingView: some View {
    VStack(spacing: 24) {
      Spacer()
      if sortedNotes.isEmpty {
        landingGlyph("note.text")
        Text("No notes yet")
          .font(.title3.weight(.medium))
        Text("Create a note here, or dictate one on your iPhone —\nthey sync automatically when Cloud Sync is on.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      } else {
        landingGlyph("square.and.pencil")
        Text("Select a note")
          .font(.title3.weight(.medium))
        Text("Pick a note from the sidebar, or start a new one.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()

      // Cloud Sync panel — only when Google is connected
      if cloudSync.isGoogleAuthorized() {
        cloudSyncPanel
          .padding(.horizontal, 60)
          .padding(.bottom, 24)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func landingGlyph(_ symbol: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color.purple.opacity(0.18), Color.blue.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: 76, height: 76)
      Image(systemName: symbol)
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(
          LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom)
        )
    }
  }

  // MARK: - Cloud Sync panel

  @ViewBuilder
  private var cloudSyncPanel: some View {
    VStack(spacing: 12) {
      Toggle(isOn: Binding(
        get: { hexSettings.cloudSyncEnabled },
        set: { newValue in $hexSettings.withLock { $0.cloudSyncEnabled = newValue } }
      )) {
        Label("Sync to Cloud", systemImage: "icloud.and.arrow.up")
      }
      .toggleStyle(.switch)

      if hexSettings.cloudSyncEnabled {
        Button {
          refresh()
        } label: {
          HStack {
            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            if case .syncing = cloudSync.status {
              ProgressView().controlSize(.small)
            }
          }
        }
        .disabled(isSyncing)

        syncStatusText
      }

      Text("When on, your notes and transcriptions sync to Google Cloud so you can access them across devices.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(16)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private var syncStatusText: some View {
    switch cloudSync.status {
    case .idle:
      Label("No sync since launch", systemImage: "clock")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .syncing:
      Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption)
        .foregroundStyle(.blue)
    case .completed(let up, let down, let at):
      let when = at.formatted(.relative(presentation: .named))
      HStack(spacing: 12) {
        Label {
          if up == 0 && down == 0 {
            Text("Up to date")
          } else {
            Text("\(up)↑ \(down)↓")
          }
        } icon: {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
        .font(.caption)
        Spacer()
        Text(when)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    case .failed(let msg):
      Label(msg, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(2)
    }
  }

  // MARK: - Toolbar buttons

  @ViewBuilder
  private var newNoteButton: some View {
    Button {
      createNewNote()
    } label: {
      Image(systemName: "square.and.pencil")
    }
    .help("New Note")
  }

  private var isSyncing: Bool {
    if case .syncing = cloudSync.status { return true }
    return false
  }

  private func refresh() {
    @Shared(.transcriptionHistory) var history: TranscriptionHistory
    Task {
      await cloudSync.syncTranscripts(history.history)
    }
  }

  private func syncNote(id: UUID) {
    Task {
      await cloudSync.uploadDirtyNote(id: id)
    }
  }

  private func createNewNote() {
    let now = Date()
    let note = SyncableNote(
      id: UUID(),
      title: "",
      body: "",
      createdAt: now,
      updatedAt: now,
      isAutoTitle: true,
      sourceDevice: Host.current().localizedName ?? "Mac",
      sourcePlatform: .macOS
    )
    cloudSync.cloudNotes.insert(note, at: 0)
    selection.selectedNoteID = note.id
    cloudSync.markDirty(id: note.id)
  }

  private func deleteNote(id: UUID) {
    if selection.selectedNoteID == id {
      selection.selectedNoteID = nil
    }
    cloudSync.cloudNotes.removeAll { $0.id == id }
    cloudSync.clearDirty(id: id)
    Task {
      await cloudSync.deleteNoteFromCloud(id: id)
    }
  }
}

// MARK: - Rich editor

private struct NoteEditorView: View {
  @Binding var note: SyncableNote
  @ObservedObject var photoStore: MacPhotoStore
  let isDirty: Bool
  let onSync: () -> Void
  let onMarkDirty: () -> Void
  let onDelete: () -> Void

  @State private var editingTitle: String = ""
  @State private var editingBody: String = ""
  @State private var hasInitialized = false
  @State private var textViewRef: NSTextView?
  @FocusState private var bodyFocused: Bool
  @StateObject private var dictation = NoteDictationController()
  /// AI cleanup for note dictations (.notes mode: structured bullets).
  /// Persisted — it's a working style, not a per-recording choice.
  @AppStorage("quill.noteDictationCleanup") private var cleanupDictation = true

  // ── AI Edit (mirrors the iOS note composer's Edit mode) ──
  @Shared(.hexSettings) private var hexSettings: HexSettings
  /// Per-command usage counts, so the user's go-to edits float to the
  /// front. Same key + format as iOS (`quill.editCommandUsage`).
  @AppStorage("quill.editCommandUsage") private var editUsageData: Data = Data()
  @State private var editDraft: String = ""
  /// Set while an AI revision awaits Undo/Keep — holds the pre-edit body so
  /// Undo is lossless. Deliberately local (not on `SyncableNote`): a pending
  /// review on the Mac shouldn't sync to the phone.
  @State private var pendingEdit: PendingNoteEdit?
  @State private var isEditingWithAI = false
  @State private var editError: String?
  @Environment(\.colorScheme) private var colorScheme

  /// Readable amber for the Edit chips/labels — the mode hue is light, so
  /// on a dark background it needs a high lightness to stay legible, and on
  /// a light background a lower one for contrast.
  private var editInk: Color {
    QuillDesign.ModePalette.edit.lightnessCapped(at: colorScheme == .dark ? 0.86 : 0.42).color()
  }

  var body: some View {
    VStack(spacing: 0) {
      editorToolbar
      Divider()

      // The markdown text view is the ONE scroller — no outer ScrollView.
      // The old nested-scroll arrangement (SwiftUI ScrollView wrapping the
      // NSTextView's own NSScrollView) fought over wheel events and pinned
      // the editor to its minHeight instead of filling the window. Title
      // and metadata stay fixed above; the editor takes all remaining
      // space and scales with the window. The column width adapts to the
      // window — proportional, clamped to a readable measure.
      GeometryReader { proxy in
        let column = min(max(proxy.size.width * 0.88, 520), 980)
        VStack(alignment: .leading, spacing: 12) {
          titleField
          metadataRow
          if let pending = pendingEdit {
            editBanner(pending)
          } else {
            aiEditBar
          }
          photoSegments
          Divider()
          if let pending = pendingEdit {
            editDiffView(from: pending.previousBody, to: editingBody)
          } else {
            bodyEditor
          }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .frame(width: column, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .onAppear { loadFields() }
    .onChange(of: note.id) { loadFields() }
  }

  // MARK: - Title

  @ViewBuilder
  private var titleField: some View {
    TextField("Title", text: $editingTitle)
      .font(.title.bold())
      .textFieldStyle(.plain)
      .onChange(of: editingTitle) {
        guard hasInitialized else { return }
        note.title = editingTitle
        note.updatedAt = Date()
        onMarkDirty()
      }
  }

  // MARK: - Metadata

  @ViewBuilder
  private var metadataRow: some View {
    HStack(spacing: 8) {
      Text(note.updatedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
        .font(.caption)
        .foregroundStyle(.secondary)
      if let place = note.placeName {
        Label(place, systemImage: "mappin.and.ellipse")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if note.sourcePlatform == .iOS {
        Label("iOS", systemImage: "iphone")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.1), in: Capsule())
      }
      Spacer()
      if isDirty {
        Label("Unsaved changes", systemImage: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }

  // MARK: - Photos (inline, read-only)

  @ViewBuilder
  private var photoSegments: some View {
    let segments = NoteContent.segments(from: note.body)
    let photos = segments.compactMap { seg -> UUID? in
      if case .photo(let id) = seg { return id }
      return nil
    }
    if !photos.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(photos, id: \.self) { photoID in
            if let image = photoStore.image(noteID: note.id, photoID: photoID) {
              Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 180, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
              RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 180, height: 120)
                .overlay {
                  VStack(spacing: 4) {
                    Image(systemName: "photo")
                      .foregroundStyle(.tertiary)
                    Text("Not downloaded")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
            }
          }
        }
      }
    }
  }

  // MARK: - Body editor

  @ViewBuilder
  private var bodyEditor: some View {
    ZStack(alignment: .topLeading) {
      MarkdownTextEditor(
        text: $editingBody,
        textView: $textViewRef
      )
      if editingBody.isEmpty {
        Text("Start writing — or hit the mic to dictate into this note.\nMarkdown works: **bold**, _italic_, # headings, - lists.")
          .font(.system(size: NSFont.systemFontSize + 2))
          .foregroundStyle(.tertiary)
          .padding(.top, 8)
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: editingBody) {
      guard hasInitialized else { return }
      note.body = editingBody
      note.updatedAt = Date()
      onMarkDirty()
    }
  }

  // MARK: - Editor toolbar

  // MARK: - Formatting

  private func wrapSelection(prefix: String, suffix: String) {
    guard let tv = textViewRef,
          let textStorage = tv.textStorage else { return }
    let range = tv.selectedRange()
    guard range.length > 0 else { return }
    let selected = (textStorage.string as NSString).substring(with: range)
    let replacement = prefix + selected + suffix
    tv.undoManager?.beginUndoGrouping()
    textStorage.replaceCharacters(in: range, with: replacement)
    tv.undoManager?.endUndoGrouping()
    // Place cursor after the inserted text
    tv.setSelectedRange(NSRange(location: range.location + replacement.count, length: 0))
    // Sync back to SwiftUI binding
    editingBody = textStorage.string
  }

  private func insertAtLineStart(_ marker: String) {
    guard let tv = textViewRef,
          let textStorage = tv.textStorage else { return }
    let range = tv.selectedRange()
    let str = textStorage.string as NSString
    let lineRange = str.lineRange(for: range)
    let lineStart = lineRange.location
    tv.undoManager?.beginUndoGrouping()
    textStorage.replaceCharacters(in: NSRange(location: lineStart, length: 0), with: marker)
    tv.undoManager?.endUndoGrouping()
    tv.setSelectedRange(NSRange(location: range.location + marker.count, length: range.length))
    editingBody = textStorage.string
  }

  // MARK: - AI Edit (chips + free-form command)

  /// The Edit-mode command bar: learned + built-in chips and a free-form
  /// field. Runs the same `InlineEditPrompt` pipeline as the iOS note
  /// composer and the macOS system-wide inline edit.
  @ViewBuilder
  private var aiEditBar: some View {
    let learned = NoteEditCommands.mostUsed(editUsageData)
      .filter { !NoteEditCommands.suggestions.contains($0) }
    let edit = QuillDesign.ModePalette.edit

    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles")
          .font(.caption)
          .foregroundStyle(editInk)
        Text("Edit with AI")
          .font(.caption.weight(.semibold))
          .foregroundStyle(editInk.opacity(0.85))
        if isEditingWithAI {
          ProgressView().controlSize(.small).padding(.leading, 4)
          Text("Revising…").font(.caption).foregroundStyle(.secondary)
        }
      }

      // Chips wrap across the readable column.
      FlowLayout(spacing: 7) {
        ForEach(learned, id: \.self) { editChip($0, isLearned: true) }
        ForEach(NoteEditCommands.suggestions, id: \.self) {
          editChip($0, isLearned: learned.contains($0))
        }
      }

      HStack(spacing: 8) {
        TextField("Edit this note — e.g. shorten by 20%", text: $editDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { submitEditDraft() }
          .disabled(isEditingWithAI)
        Button("Run") { submitEditDraft() }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(editDraft.trimmingCharacters(in: .whitespaces).isEmpty || isEditingWithAI)
      }

      if let editError {
        Label(editError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(editInk)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(edit.color(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(edit.color(0.25), lineWidth: 1)
        )
    )
  }

  private func editChip(_ command: String, isLearned: Bool) -> some View {
    let edit = QuillDesign.ModePalette.edit
    return Button {
      runEdit(command)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: isLearned ? "clock" : "sparkles")
          .font(.system(size: 10, weight: .semibold))
        Text(command)
          .font(.system(size: 12, weight: .semibold))
      }
      .foregroundStyle(editInk)
      .padding(.vertical, 5)
      .padding(.horizontal, 10)
      .background(
        Capsule().fill(edit.color(colorScheme == .dark ? 0.24 : 0.14))
          .overlay(Capsule().strokeBorder(edit.color(0.45), lineWidth: 0.75))
      )
    }
    .buttonStyle(.plain)
    .disabled(isEditingWithAI)
  }

  /// Banner shown while a revision awaits Undo / Keep.
  private func editBanner(_ pending: PendingNoteEdit) -> some View {
    let edit = QuillDesign.ModePalette.edit
    return HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(Circle().fill(edit.color()))
      VStack(alignment: .leading, spacing: 1) {
        Text(pending.label).font(.subheadline.weight(.semibold))
        Text("Review the changes below").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Undo") { undoEdit() }
        .controlSize(.regular)
      Button("Keep") { keepEdit() }
        .controlSize(.regular)
        .buttonStyle(.borderedProminent)
        .tint(edit.color())
        .keyboardShortcut(.return, modifiers: [])
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(edit.color(0.10))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(edit.color(0.4), lineWidth: 1)
        )
    )
  }

  /// Removed lines struck through in red with a `−` gutter; additions
  /// highlighted green with a `+`. Uses the shared `LineDiff`.
  private func editDiffView(from before: String, to after: String) -> some View {
    let removed = OKLCH(0.6, 0.17, 25)
    let added = QuillDesign.ModePalette.resolved
    return ScrollView {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(LineDiff.rows(from: before, to: after)) { row in
          if row.text.trimmingCharacters(in: .whitespaces).isEmpty {
            Color.clear.frame(height: 7)
          } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(row.kind == .removed ? "−" : (row.kind == .added ? "+" : " "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.kind == .removed ? removed.color()
                  : (row.kind == .added ? added.lightnessCapped(at: 0.5).color() : .secondary))
                .frame(width: 12, alignment: .leading)
              Text(row.text.replacingOccurrences(of: "**", with: ""))
                .font(.system(size: NSFont.systemFontSize + 1, weight: row.text.hasPrefix("**") ? .bold : .regular))
                .foregroundStyle(row.kind == .removed ? removed.color() : Color.primary)
                .strikethrough(row.kind == .removed)
                .opacity(row.kind == .removed ? 0.7 : 1)
                .padding(.horizontal, row.kind == .added ? 4 : 0)
                .padding(.vertical, row.kind == .added ? 1 : 0)
                .background(
                  RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(row.kind == .added ? added.color(0.16) : .clear)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - AI Edit actions

  private func submitEditDraft() {
    let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    editDraft = ""
    runEdit(text)
  }

  private func runEdit(_ command: String) {
    Task { await performEdit(command) }
  }

  @MainActor
  private func performEdit(_ command: String) async {
    let body = editingBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      editError = "Nothing to edit yet — add something to the note first."
      return
    }
    editError = nil
    editUsageData = NoteEditCommands.recordUsage(command, in: editUsageData)

    isEditingWithAI = true
    defer { isEditingWithAI = false }

    @Dependency(\.aiProcessing) var aiProcessing
    @Dependency(\.keychain) var keychain
    let provider = hexSettings.aiProvider
    let isPro = hexSettings.selectedPlan == "pro"

    // Pre-check the key: `AIProcessingClient.process` returns the input
    // UNCHANGED on a missing key, which for an edit would paste the raw
    // prompt over the note. Pro routes through the proxy, no local key.
    if !isPro {
      let keychainKey = provider == .openAI ? KeychainKey.openAIAPIKey : KeychainKey.anthropicAPIKey
      guard let apiKey = await keychain.read(keychainKey), !apiKey.isEmpty else {
        editError = "Add an API key in Settings → AI to use AI editing."
        return
      }
    }

    do {
      let userMessage = InlineEditPrompt.userMessage(instruction: command, selection: body)
      // skipTranscriptWrapping = true: the message is already an instruction
      // + selection, not a raw transcript to wrap in <transcript> tags.
      let revised = try await aiProcessing.process(
        userMessage, .clean, provider, nil, InlineEditPrompt.systemPrompt, true
      )
      let cleaned = revised.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty, cleaned != body else {
        editError = "The model returned the note unchanged. Try rewording the command."
        return
      }
      // Stash the pre-edit body for a lossless Undo, then apply. Setting
      // `editingBody` runs the editor's onChange → note.body + dirty + sync.
      pendingEdit = PendingNoteEdit(previousBody: editingBody, label: NoteEditCommands.label(for: command))
      editingBody = cleaned
    } catch {
      editError = "Edit failed: \(error.localizedDescription)"
    }
  }

  private func keepEdit() {
    // The new body is already applied + marked dirty; just drop the review.
    pendingEdit = nil
  }

  private func undoEdit() {
    guard let pending = pendingEdit else { return }
    editingBody = pending.previousBody  // onChange reverts note.body + re-syncs
    pendingEdit = nil
  }

  @ViewBuilder
  private var editorToolbar: some View {
    HStack(spacing: 8) {
      // Formatting buttons (require selection via NSTextView)
      Group {
        Button { wrapSelection(prefix: "**", suffix: "**") } label: {
          Image(systemName: "bold")
        }
        .help("Bold")
        .keyboardShortcut("b", modifiers: .command)

        Button { wrapSelection(prefix: "_", suffix: "_") } label: {
          Image(systemName: "italic")
        }
        .help("Italic")
        .keyboardShortcut("i", modifiers: .command)

        Button { wrapSelection(prefix: "~~", suffix: "~~") } label: {
          Image(systemName: "strikethrough")
        }
        .help("Strikethrough")

        Button { wrapSelection(prefix: "`", suffix: "`") } label: {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .help("Inline Code")

        Divider().frame(height: 16)

        Button { insertAtLineStart("# ") } label: {
          Image(systemName: "number")
        }
        .help("Heading")

        Button { insertAtLineStart("- ") } label: {
          Image(systemName: "list.bullet")
        }
        .help("Bullet List")

        Button { insertAtLineStart("- [ ] ") } label: {
          Image(systemName: "checklist")
        }
        .help("Checkbox")

        Button { insertAtLineStart("1. ") } label: {
          Image(systemName: "list.number")
        }
        .help("Numbered List")

        Button { insertAtLineStart("> ") } label: {
          Image(systemName: "text.quote")
        }
        .help("Quote")
      }
      .buttonStyle(.borderless)

      Spacer()

      // ── Dictation ──
      if let error = dictation.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
      if dictation.isProcessing {
        ProgressView()
          .controlSize(.small)
      }
      if let start = dictation.startTime {
        TimelineView(.periodic(from: start, by: 1)) { ctx in
          let elapsed = max(0, Int(ctx.date.timeIntervalSince(start)))
          Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.red)
        }
      }
      Toggle(isOn: $cleanupDictation) {
        Image(systemName: "sparkles")
      }
      .toggleStyle(.button)
      .buttonStyle(.borderless)
      .help(cleanupDictation
        ? "AI cleanup on: dictations are structured into tidy notes before inserting"
        : "AI cleanup off: raw transcript is inserted as spoken")

      Button {
        dictation.toggle(cleanup: cleanupDictation) { text in
          insertDictation(text)
        }
      } label: {
        Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
          .foregroundStyle(dictation.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
          .symbolEffect(.pulse, isActive: dictation.isRecording)
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .help(dictation.isRecording ? "Stop and insert (⌘⇧D)" : "Dictate into this note (⌘⇧D)")

      Divider().frame(height: 16)

      Text(wordCountLabel)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .monospacedDigit()

      if isDirty {
        Button {
          onSync()
        } label: {
          Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption.bold())
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.small)
      }

      Button(role: .destructive) {
        onDelete()
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Delete this note")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }

  /// Inserts a finished dictation at the caret (or appends when the text
  /// view isn't available), with sensible separation from surrounding text.
  private func insertDictation(_ text: String) {
    if let tv = textViewRef {
      let ns = tv.string as NSString
      let sel = tv.selectedRange()
      var payload = text
      if sel.location > 0 {
        let prevChar = Character(UnicodeScalar(ns.character(at: sel.location - 1)) ?? " ")
        if prevChar.isNewline {
          // At a fresh line — no separator needed.
        } else if sel.location == ns.length {
          payload = "\n\n" + payload
        } else if !prevChar.isWhitespace {
          payload = " " + payload
        }
      }
      tv.insertText(payload, replacementRange: sel)
    } else {
      editingBody = editingBody.isEmpty ? text : editingBody + "\n\n" + text
    }
  }

  private var wordCountLabel: String {
    let words = NoteContent.stripPhotos(from: editingBody)
      .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .count
    return words == 1 ? "1 word" : "\(words) words"
  }

  // MARK: - Helpers

  private func loadFields() {
    hasInitialized = false
    editingTitle = note.title
    editingBody = note.body
    // Reset the AI-edit review state — a pending diff belongs to the note
    // it was made on, not whatever note we're switching to.
    pendingEdit = nil
    editDraft = ""
    editError = nil
    // Delay flipping the flag so the onChange handlers triggered by
    // the assignments above don't mark the note dirty on load.
    DispatchQueue.main.async {
      hasInitialized = true
    }
  }
}

// MARK: - NSTextView wrapper with live markdown highlighting

/// A SwiftUI wrapper around `NSTextView` that exposes the underlying
/// text view reference so the formatting toolbar can access the
/// selection range, and applies live syntax highlighting so markdown
/// renders visually: bold text appears bold, italic text appears
/// italic, strikethrough renders with a line, and the markdown
/// markers themselves fade to near-invisible.
///
/// Storage stays as plain text (markdown). The visual formatting is
/// applied via `NSTextStorage` attributes after every edit and is
/// purely cosmetic — it doesn't affect the string content.
private struct MarkdownTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var textView: NSTextView?

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    guard let tv = scrollView.documentView as? NSTextView else {
      return scrollView
    }

    tv.delegate = context.coordinator
    tv.isRichText = false
    tv.allowsUndo = true
    tv.usesFontPanel = false
    tv.font = MarkdownHighlighter.baseFont
    tv.textColor = .labelColor
    tv.backgroundColor = .clear
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.textContainerInset = NSSize(width: 0, height: 8)
    tv.defaultParagraphStyle = MarkdownHighlighter.paragraphStyle

    // Publish the reference so the toolbar can use it
    DispatchQueue.main.async {
      self.textView = tv
    }

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tv = scrollView.documentView as? NSTextView else { return }
    // Only update if the source of truth changed externally (e.g. note switch)
    if tv.string != text {
      let savedSelection = tv.selectedRange()
      tv.string = text
      // Clamp selection to new string length
      let clamped = NSRange(
        location: min(savedSelection.location, text.count),
        length: 0
      )
      tv.setSelectedRange(clamped)
      Self.applyHighlight(tv)
    }
  }

  /// Runs the shared HexCore highlighter over the view's storage with
  /// undo registration suspended — highlighting is cosmetic, not an edit.
  static func applyHighlight(_ tv: NSTextView) {
    guard let storage = tv.textStorage else { return }
    let undoManager = tv.undoManager
    undoManager?.disableUndoRegistration()
    MarkdownHighlighter.highlight(storage)
    undoManager?.enableUndoRegistration()
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MarkdownTextEditor

    init(_ parent: MarkdownTextEditor) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let tv = notification.object as? NSTextView else { return }
      parent.text = tv.string
      MarkdownTextEditor.applyHighlight(tv)
    }

    /// Auto-continue markdown lists on Enter — shared logic in HexCore's
    /// `MarkdownListContinuation` (same behavior on iOS).
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
      let sel = textView.selectedRange()
      guard sel.length == 0 else { return false }

      switch MarkdownListContinuation.handleNewline(text: textView.string, caretLocation: sel.location) {
      case .exitList(let clearRange):
        textView.insertText("", replacementRange: clearRange)
        return true
      case .continueList(let insert):
        textView.insertText(insert, replacementRange: sel)
        return true
      case .none:
        return false
      }
    }
  }
}

// MARK: - AI Edit support types

/// A pending AI revision awaiting Undo / Keep. Local to the editor — never
/// synced (a review in progress on the Mac shouldn't follow you to iOS).
private struct PendingNoteEdit: Equatable {
  var previousBody: String
  var label: String
}

/// Minimal wrapping layout for the edit-command chips — flows children left
/// to right, wrapping to the next row when the current one is full.
private struct FlowLayout: Layout {
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

#endif
