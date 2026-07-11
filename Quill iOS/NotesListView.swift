//
//  NotesListView.swift
//  Quill (iOS)
//
//  Sheet that lists all saved notes, lets the user pick one to make
//  active, and supports swipe-to-delete. Card style mirrors the macOS
//  HistoryFeature's TranscriptView (rounded container, body preview,
//  divider, metadata footer).
//

import HexCore
import SwiftUI

struct NotesListView: View {
  @ObservedObject var store: NotesStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var renamingNoteID: UUID?
  @State private var renameDraft: String = ""
  @State private var searchQuery: String = ""
  /// Two-step delete confirm — set when the user taps the trash on a
  /// row, cleared when the alert resolves. Keeps the destructive
  /// action from firing on a single tap.
  @State private var pendingDeleteNoteID: UUID?

  // Shared deep-purple band colors. The toolbar gradient + the
  // custom search bar's background + the soft fade strip all derive
  // from these so the entire top band reads as one continuous region.
  private let bandTopColor = Color(red: 0.16, green: 0.06, blue: 0.32)
  private let bandBottomColor = Color(red: 0.22, green: 0.10, blue: 0.42)

  /// Notes filtered by the current search query. When the query is
  /// blank we return the full sorted list; otherwise we substring-match
  /// (case-insensitive) against title, body (with photo tokens stripped
  /// — otherwise raw UUIDs would match), and the cached location name.
  private var visibleNotes: [Note] {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return store.sortedNotes }
    return store.sortedNotes.filter { note in
      if note.displayTitle.localizedCaseInsensitiveContains(trimmed) { return true }
      let textBody = NoteContent.stripPhotos(from: note.body)
      if textBody.localizedCaseInsensitiveContains(trimmed) { return true }
      if let place = note.location?.placeName,
         place.localizedCaseInsensitiveContains(trimmed) { return true }
      return false
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Custom band — same shape, gradient, and button treatment as
        // QuillHeaderBar on the home screen. Built from scratch instead
        // of using NavigationStack's toolbar so iOS doesn't wrap our
        // buttons in its own frosted backdrop (which was washing the
        // glyphs out to lavender + magenta on the dark gradient).
        customHeaderBand

        notesContent
      }
      .background(
        (colorScheme == .dark
          ? Color(red: 0.11, green: 0.11, blue: 0.12)
          : Color(red: 0.957, green: 0.945, blue: 0.973))
          .ignoresSafeArea()
      )
      .toolbar(.hidden, for: .navigationBar)
      .alert("Rename Note", isPresented: Binding(
        get: { renamingNoteID != nil },
        set: { if !$0 { renamingNoteID = nil } }
      )) {
        TextField("Title", text: $renameDraft)
        Button("Save") {
          if let id = renamingNoteID {
            store.renameNote(id: id, to: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
          }
          renamingNoteID = nil
        }
        Button("Cancel", role: .cancel) { renamingNoteID = nil }
      } message: {
        Text("Leave blank to auto-derive from the first line of the note.")
      }
      .alert("Delete Note?", isPresented: Binding(
        get: { pendingDeleteNoteID != nil },
        set: { if !$0 { pendingDeleteNoteID = nil } }
      )) {
        Button("Delete", role: .destructive) {
          if let id = pendingDeleteNoteID {
            store.deleteNote(id: id)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
          }
          pendingDeleteNoteID = nil
        }
        Button("Cancel", role: .cancel) { pendingDeleteNoteID = nil }
      } message: {
        Text("This permanently removes the note and all attached photos. This can't be undone.")
      }
    }
  }

  /// The notes list / search-empty / no-notes states. Pulled out of
  /// the body so the surrounding band-and-content layout stays
  /// readable.
  @ViewBuilder
  private var notesContent: some View {
    if store.notes.isEmpty {
      ContentUnavailableView {
        Label("No Notes Yet", systemImage: "note.text")
      } description: {
        Text("Record something on the main screen to create your first note.")
      }
    } else if visibleNotes.isEmpty {
      ContentUnavailableView.search(text: searchQuery)
    } else {
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(visibleNotes) { note in
            NoteRow(
              note: note,
              isActive: note.id == store.activeNoteID,
              onTap: {
                store.setActiveNote(id: note.id)
                UISelectionFeedbackGenerator().selectionChanged()
                dismiss()
              },
              onRename: {
                renameDraft = note.title
                renamingNoteID = note.id
              },
              onDelete: {
                // Defer to the alert. The alert resolves the actual
                // delete + haptic so a stray tap doesn't lose work.
                pendingDeleteNoteID = note.id
              },
              onTogglePin: {
                store.togglePin(id: note.id)
                UISelectionFeedbackGenerator().selectionChanged()
              }
            )
          }
        }
        .padding()
      }
    }
  }

  /// Custom header band — purple gradient with rounded bottom corners
  /// (matches `QuillHeaderBar` on the home screen), with the New +
  /// Close buttons + "Notes" title on the top row and the search bar
  /// on the row below. The whole thing replaces the NavigationStack's
  /// native toolbar so iOS can't re-tint our buttons.
  private var customHeaderBand: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Button {
          let new = store.startNewNote(location: nil)
          _ = new
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          dismiss()
        } label: {
          headerStyleGlyph("square.and.pencil")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New note")

        Spacer()

        Text("Notes")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)

        Spacer()

        Button {
          dismiss()
        } label: {
          headerStyleGlyph("xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, 20)

      customSearchBar
        .padding(.horizontal, 16)
    }
    .padding(.top, 12)
    .padding(.bottom, 14)
    .background(headerBandBackground)
    .shadow(color: .purple.opacity(0.18), radius: 10, y: 6)
  }

  /// Purple gradient with rounded bottom corners that bleeds under
  /// the safe area at the top. Mirrors `QuillHeaderBar.headerBackground`
  /// so the two screens read as visually consistent.
  private var headerBandBackground: some View {
    UnevenRoundedRectangle(
      topLeadingRadius: 0,
      bottomLeadingRadius: 24,
      bottomTrailingRadius: 24,
      topTrailingRadius: 0,
      style: .continuous
    )
    .fill(
      LinearGradient(
        colors: [bandTopColor, bandBottomColor],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .overlay(alignment: .top) {
      // Faint inner highlight at the very top of the gradient — same
      // depth detail QuillHeaderBar uses.
      LinearGradient(
        colors: [Color.white.opacity(0.10), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 24)
      .allowsHitTesting(false)
    }
    .ignoresSafeArea(edges: .top)
  }

  // MARK: - Header-band components

  /// 36pt round glyph button matching `QuillHeaderBar.headerButton` —
  /// white-18% fill, white-25% hairline, 12pt semibold white glyph.
  /// Used for the Done (xmark) and New (pencil) toolbar items so they
  /// read as the same affordance family as the home-screen header
  /// buttons. Tap target is the toolbar's natural padding around it.
  private func headerStyleGlyph(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 36, height: 36)
      .background(Circle().fill(Color.white.opacity(0.18)))
      .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
  }

  /// Custom search bar that mirrors the header-button style — capsule
  /// with white-18% fill, white-25% hairline, white glyph + text on
  /// the deep-purple band. Replaces SwiftUI's `.searchable` so we get
  /// full control over the visual treatment; loses the system search
  /// drawer chrome (which we didn't really want anyway since it
  /// re-tinted with system colors).
  private var customSearchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))

      TextField(
        "",
        text: $searchQuery,
        prompt: Text("Search notes")
          .foregroundColor(.white.opacity(0.55))
      )
      .font(.subheadline)
      .foregroundStyle(.white)
      .tint(.white)
      .submitLabel(.search)
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)

      if !searchQuery.isEmpty {
        Button {
          searchQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Capsule().fill(Color.white.opacity(0.18)))
    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
  }
}

// MARK: - NoteRow

private struct NoteRow: View {
  let note: Note
  let isActive: Bool
  let onTap: () -> Void
  let onRename: () -> Void
  let onDelete: () -> Void
  var onTogglePin: (() -> Void)? = nil
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 0) {
        // Body preview + title
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            if note.isPinned {
              Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(.purple)
                .rotationEffect(.degrees(45))
            }
            Text(note.displayTitle)
              .font(.headline)
              .lineLimit(1)
              .foregroundStyle(.primary)
            if isActive {
              Text("Active")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                  Capsule().fill(Color.purple.opacity(0.18))
                )
                .foregroundStyle(.purple)
            }
            Spacer()
            // Visible edit + delete affordances — circular 38pt white
            // pills with soft shadows. Swipe-to-delete only works inside
            // a `List`, and our LazyVStack-in-ScrollView layout doesn't
            // support it — so visible buttons are the only reliable way
            // to surface the actions. Long-press contextMenu also still
            // works for the same actions.
            Button(action: onRename) {
              rowActionGlyph("pencil", tint: .purple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename note")

            Button(action: onDelete) {
              rowActionGlyph("trash", tint: .red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete note")
          }

          if !note.body.isEmpty {
            let preview = NoteContent.stripPhotos(from: note.body)
            if preview.isEmpty {
              Label("\(note.photoCount) photo\(note.photoCount == 1 ? "" : "s")",
                    systemImage: "photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
              Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            }
          } else {
            Text("Empty")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
              .italic()
          }
        }
        .padding(12)

        Divider()

        // Metadata footer — location · relative date · time · word count
        HStack(spacing: 6) {
          if let place = note.location?.placeName {
            Image(systemName: "location.fill")
            Text(place).lineLimit(1)
            Text("·")
          }
          Image(systemName: "clock")
          Text(note.updatedAt.quillRelativeFormatted())
          Text("·")
          Text(note.updatedAt.formatted(date: .omitted, time: .shortened))
          Text("·")
          Text("\(note.wordCount) words")
          if note.photoCount > 0 {
            Text("·")
            Image(systemName: "photo")
            Text("\(note.photoCount)")
          }
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      // Active row lifts off the lavender app bg with a fully white
      // fill and a brighter #c084fc border at 1.5px. Inactive rows
      // sit flush in the secondary system background.
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(isActive ? Color(.systemBackground) : Color(.secondarySystemBackground))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(
            isActive ? Color(red: 0.753, green: 0.518, blue: 0.988)
                     : Color.secondary.opacity(0.15),
            lineWidth: isActive ? 1.5 : 1
          )
      )
      .shadow(color: isActive ? Color.purple.opacity(0.10) : .clear, radius: 6, y: 2)
    }
    .buttonStyle(.plain)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive, action: onDelete) {
        Label("Delete", systemImage: "trash")
      }
    }
    // SwiftUI's swipeActions only work inside List, but VStack/ScrollView
    // users expect swipe-to-delete too. Fall back to a long-press menu for
    // consistent discoverability.
    .contextMenu {
      if let onTogglePin {
        Button(action: onTogglePin) {
          Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
        }
      }
      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
      }
      Button(role: .destructive, action: onDelete) {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  /// Shared style for the rename / delete pills at the top of every
  /// row. 38pt white circle, tinted glyph, soft drop shadow, faint
  /// tint hairline so each pill has a distinct edge against the row
  /// background regardless of the active state.
  private func rowActionGlyph(_ systemName: String, tint: Color) -> some View {
    Image(systemName: systemName)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(tint)
      .frame(width: 38, height: 38)
      .background(Circle().fill(Color(.systemBackground)))
      .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
      .overlay(
        Circle().stroke(tint.opacity(0.15), lineWidth: 0.5)
      )
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
