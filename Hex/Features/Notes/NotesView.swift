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
        Image(systemName: "note.text")
          .font(.system(size: 48))
          .foregroundStyle(.tertiary)
        Text("No notes yet")
          .font(.title3)
          .foregroundStyle(.secondary)
        Text("Create a note or sync from your iPhone.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        Image(systemName: "sidebar.left")
          .font(.system(size: 36))
          .foregroundStyle(.tertiary)
        Text("Select a note")
          .font(.title3)
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

  var body: some View {
    VStack(spacing: 0) {
      editorToolbar
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          titleField
          metadataRow
          Divider()
          photoSegments
          bodyEditor
        }
        .padding(24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    MarkdownTextEditor(
      text: $editingBody,
      textView: $textViewRef
    )
    .frame(minHeight: 300, maxHeight: .infinity)
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
      }
      .buttonStyle(.borderless)

      Spacer()

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
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: - Helpers

  private func loadFields() {
    hasInitialized = false
    editingTitle = note.title
    editingBody = note.body
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
    tv.font = .systemFont(ofSize: NSFont.systemFontSize)
    tv.textColor = .labelColor
    tv.backgroundColor = .clear
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.textContainerInset = NSSize(width: 0, height: 4)

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
      MarkdownHighlighter.highlight(tv)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MarkdownTextEditor

    init(_ parent: MarkdownTextEditor) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let tv = notification.object as? NSTextView else { return }
      parent.text = tv.string
      MarkdownHighlighter.highlight(tv)
    }
  }
}

// MARK: - Live markdown highlighter

/// Applies visual formatting to markdown syntax in an `NSTextView`
/// without changing the underlying text. Markers (`**`, `_`, `~~`,
/// `` ` ``) are rendered in a near-invisible color while the content
/// between them gets the appropriate typographic treatment (bold,
/// italic, strikethrough, monospace). Headings and bullets get
/// styled at the line level.
private enum MarkdownHighlighter {
  static let baseSize = NSFont.systemFontSize
  static let baseFont = NSFont.systemFont(ofSize: baseSize)

  static func highlight(_ textView: NSTextView) {
    guard let textStorage = textView.textStorage else { return }
    let string = textStorage.string
    let fullRange = NSRange(location: 0, length: (string as NSString).length)
    guard fullRange.length > 0 else { return }

    // Suspend undo registration — highlighting is cosmetic, not an edit.
    let undoManager = textView.undoManager
    undoManager?.disableUndoRegistration()
    textStorage.beginEditing()

    // 1. Reset everything to the base style.
    let baseAttrs: [NSAttributedString.Key: Any] = [
      .font: baseFont,
      .foregroundColor: NSColor.labelColor,
      .strikethroughStyle: 0,
    ]
    textStorage.setAttributes(baseAttrs, range: fullRange)

    let markerAttrs: [NSAttributedString.Key: Any] = [
      .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.35),
      .font: NSFont.systemFont(ofSize: baseSize * 0.85),
    ]

    // 2. Bold: **text**
    applyInline(
      pattern: #"\*\*(.+?)\*\*"#,
      storage: textStorage, string: string,
      contentAttrs: [.font: NSFont.boldSystemFont(ofSize: baseSize)],
      markerAttrs: markerAttrs, markerLen: 2
    )

    // 3. Italic: _text_ (word-boundary aware to avoid matching snake_case)
    applyInline(
      pattern: #"(?<![a-zA-Z0-9])_(.+?)_(?![a-zA-Z0-9])"#,
      storage: textStorage, string: string,
      contentAttrs: [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)],
      markerAttrs: markerAttrs, markerLen: 1
    )

    // 4. Strikethrough: ~~text~~
    applyInline(
      pattern: #"~~(.+?)~~"#,
      storage: textStorage, string: string,
      contentAttrs: [
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .strikethroughColor: NSColor.secondaryLabelColor,
      ],
      markerAttrs: markerAttrs, markerLen: 2
    )

    // 5. Inline code: `text`
    applyInline(
      pattern: #"`([^`]+)`"#,
      storage: textStorage, string: string,
      contentAttrs: [
        .font: NSFont.monospacedSystemFont(ofSize: baseSize * 0.93, weight: .regular),
        .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.3),
      ],
      markerAttrs: markerAttrs, markerLen: 1
    )

    // 6. Headings: # at line start
    applyLinePattern(
      pattern: #"^(#{1,3})\s+(.+)$"#,
      storage: textStorage, string: string
    ) { match in
      let hashRange = match.range(at: 1)
      let textRange = match.range(at: 2)
      let level = hashRange.length // 1, 2, or 3
      let headingSize = baseSize + CGFloat(4 - level) * 3 // #=+9, ##=+6, ###=+3
      textStorage.addAttributes(markerAttrs, range: hashRange)
      textStorage.addAttributes([
        .font: NSFont.boldSystemFont(ofSize: headingSize),
      ], range: textRange)
    }

    // 7. Bullets: - at line start
    applyLinePattern(
      pattern: #"^(-)\s+(.+)$"#,
      storage: textStorage, string: string
    ) { match in
      let dashRange = match.range(at: 1)
      textStorage.addAttributes([
        .foregroundColor: NSColor.tertiaryLabelColor,
      ], range: dashRange)
    }

    textStorage.endEditing()
    undoManager?.enableUndoRegistration()
  }

  /// Highlights an inline markdown pattern (e.g. `**bold**`). The
  /// markers get faded styling; the content between them gets the
  /// supplied attributes.
  private static func applyInline(
    pattern: String,
    storage: NSTextStorage,
    string: String,
    contentAttrs: [NSAttributedString.Key: Any],
    markerAttrs: [NSAttributedString.Key: Any],
    markerLen: Int
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    let nsString = string as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)

    regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
      guard let matchRange = match?.range, matchRange.length > markerLen * 2 else { return }

      // Leading marker
      let leading = NSRange(location: matchRange.location, length: markerLen)
      storage.addAttributes(markerAttrs, range: leading)

      // Content
      let contentStart = matchRange.location + markerLen
      let contentLength = matchRange.length - markerLen * 2
      let content = NSRange(location: contentStart, length: contentLength)
      storage.addAttributes(contentAttrs, range: content)

      // Trailing marker
      let trailing = NSRange(location: matchRange.location + matchRange.length - markerLen, length: markerLen)
      storage.addAttributes(markerAttrs, range: trailing)
    }
  }

  /// Runs a line-anchored regex and calls the handler for each match.
  private static func applyLinePattern(
    pattern: String,
    storage: NSTextStorage,
    string: String,
    handler: (NSTextCheckingResult) -> Void
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return }
    let fullRange = NSRange(location: 0, length: (string as NSString).length)
    regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
      guard let match else { return }
      handler(match)
    }
  }
}
#endif
