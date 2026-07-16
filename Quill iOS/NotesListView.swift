//
//  NotesListView.swift
//  Quill (iOS)
//
//  The notes list (design handoff §6): a compose/close header row, a
//  field-style search capsule, and a column of hairline note cards —
//  title, 2-line preview, per-card compose + delete buttons, meta row.
//
//  The old deep-purple gradient band is gone. The design language is flat
//  and material-first: the page carries the same `QuillTheme` gradient as
//  home and the note detail, and elevation is hairlines, not shadows.
//

import HexCore
import SwiftUI

struct NotesListView: View {
  @ObservedObject var store: NotesStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  @State private var renamingNoteID: UUID?
  @State private var renameDraft: String = ""
  @State private var searchQuery: String = ""
  /// Two-step delete confirm — set when the user taps the trash on a
  /// row, cleared when the alert resolves. Keeps the destructive
  /// action from firing on a single tap.
  @State private var pendingDeleteNoteID: UUID?

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
    VStack(spacing: 13) {
      header
      notesContent
    }
    .padding(.top, 4)
    .background(pageBackground.ignoresSafeArea())
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

  // MARK: - Header

  /// Compose left, "Notes" centred, close right — then the search field.
  private var header: some View {
    VStack(spacing: 13) {
      HStack {
        roundButton("square.and.pencil", "New note") {
          _ = store.startNewNote(location: nil)
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          dismiss()
        }

        Spacer()

        Text("Notes")
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(theme.text)

        Spacer()

        roundButton("xmark", "Close") { dismiss() }
      }

      searchField
    }
    .padding(.horizontal, 16)
  }

  private func roundButton(
    _ symbol: String,
    _ label: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(theme.text2)
        .frame(width: 40, height: 40)
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

  private var searchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 16))
        .foregroundStyle(theme.text3)

      TextField("", text: $searchQuery, prompt: Text("Search notes").foregroundColor(theme.text3))
        .font(.system(size: 16))
        .foregroundStyle(theme.text)
        .tint(QuillDesign.brand.color())
        .submitLabel(.search)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)

      if !searchQuery.isEmpty {
        Button {
          searchQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(theme.text3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 42)
    .background(
      Capsule()
        .fill(theme.field)
        .overlay(Capsule().strokeBorder(theme.fieldRing, lineWidth: 1))
    )
  }

  // MARK: - List

  @ViewBuilder
  private var notesContent: some View {
    if store.notes.isEmpty {
      emptyState(
        title: "No notes yet",
        message: "Tap the orb on the home screen to capture your first one."
      )
    } else if visibleNotes.isEmpty {
      emptyState(title: "No notes found", message: "Nothing matches “\(searchQuery)”.")
    } else {
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(visibleNotes) { note in
            NoteListCard(
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
              // Defer to the alert. The alert resolves the actual delete
              // + haptic so a stray tap doesn't lose work.
              onDelete: { pendingDeleteNoteID = note.id },
              onTogglePin: {
                store.togglePin(id: note.id)
                UISelectionFeedbackGenerator().selectionChanged()
              }
            )
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 20)
      }
    }
  }

  private func emptyState(title: String, message: String) -> some View {
    VStack(spacing: 6) {
      Spacer()
      Text(title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(theme.text2)
      Text(message)
        .font(.system(size: 15))
        .foregroundStyle(theme.text3)
        .multilineTextAlignment(.center)
      Spacer()
    }
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity)
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

// MARK: - Card

/// One note in the list. The prototype puts a capture-mode dot beside the
/// title; notes don't record how they were captured, so rather than tint
/// every card the same fake colour the dot is omitted — the Active pill
/// and pin carry the state that's actually real.
private struct NoteListCard: View {
  let note: Note
  let isActive: Bool
  let onTap: () -> Void
  let onRename: () -> Void
  let onDelete: () -> Void
  let onTogglePin: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  private var accent: Color { QuillDesign.brand.color() }

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
              titleRow
              preview
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
              cardButton("square.and.pencil", "Rename note", tint: accent, action: onRename)
              cardButton(
                "trash",
                "Delete note",
                tint: OKLCH(0.62, 0.19, 22).color(),
                action: onDelete
              )
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 13)

        Rectangle()
          .fill(theme.hair)
          .frame(height: 0.5)

        QuillNoteMeta(note: note)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
              .strokeBorder(
                isActive ? accent.opacity(0.7) : theme.hair,
                lineWidth: isActive ? 1.5 : 0.5
              )
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(QuillPressStyle())
    .contextMenu {
      Button(action: onTogglePin) {
        Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
      }
      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
      }
      Button(role: .destructive, action: onDelete) {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  private var titleRow: some View {
    HStack(spacing: 8) {
      if note.isPinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 11))
          .foregroundStyle(accent)
          .rotationEffect(.degrees(45))
      }

      Text(note.displayTitle)
        .font(.system(size: 17, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(theme.text)
        .lineLimit(1)

      if isActive {
        Text("ACTIVE")
          .font(.system(size: 10.5, weight: .bold))
          .tracking(0.3)
          .foregroundStyle(accent)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent.opacity(0.14)))
      }
    }
  }

  @ViewBuilder
  private var preview: some View {
    let text = NoteContent.stripPhotos(from: note.body)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !text.isEmpty {
      Text(text)
        .font(.system(size: 14.5))
        .foregroundStyle(theme.text2)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    } else if note.photoCount > 0 {
      Label(
        "\(note.photoCount) photo\(note.photoCount == 1 ? "" : "s")",
        systemImage: "photo"
      )
      .font(.system(size: 14.5))
      .foregroundStyle(theme.text2)
    } else {
      Text("Empty")
        .font(.system(size: 14.5))
        .italic()
        .foregroundStyle(theme.text3)
    }
  }

  private func cardButton(
    _ symbol: String,
    _ label: String,
    tint: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(tint)
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
}
