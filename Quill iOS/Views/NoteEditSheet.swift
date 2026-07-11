//
//  NoteEditSheet.swift
//  Quill (iOS)
//
//  Modal editor for the active note's body. Sheet presentation so the
//  user can scroll through and revise the full note in a focused view.
//  Photo tokens (`![photo](<uuid>)`) are preserved verbatim so inline
//  photos still render after the edit lands. We don't try to render
//  photos inside the editor itself — that would require a custom
//  AttributedString-backed control. Instead we surface a small footer
//  hint and let the user see/edit the raw tokens.
//

import HexCore
import SwiftUI

struct NoteEditSheet: View {
  let note: Note
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var notesStore = NotesStore.shared

  @State private var draftBody: String
  @State private var draftTitle: String

  init(note: Note) {
    self.note = note
    self._draftBody = State(initialValue: note.body)
    self._draftTitle = State(initialValue: note.title)
  }

  private var hasPhotoTokens: Bool {
    !NoteContent.photoIDs(in: note.body).isEmpty
  }

  private var hasChanges: Bool {
    draftBody != note.body || draftTitle != note.title
  }

  var body: some View {
    NavigationStack {
      // The UITextView is the ONLY scroller — nesting it in a Form/
      // ScrollView makes the two fight over drag gestures (same lesson
      // as the macOS editor). Title + hints are fixed chrome around it.
      VStack(spacing: 0) {
        TextField("Title", text: $draftTitle)
          .textInputAutocapitalization(.sentences)
          .font(.headline)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)

        Divider()

        MarkdownTextEditorIOS(text: $draftBody)

        Divider()

        Group {
          if hasPhotoTokens {
            Text("This note has inline photos. Don't edit the `![photo](...)` markers — they tell Quill where each photo belongs.")
              .foregroundStyle(.orange)
          } else {
            Text("Markdown supported — use the keyboard toolbar for bold, lists, and headings. Changes sync to the cloud automatically when cloud sync is on.")
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
      .navigationTitle("Edit Note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            commit()
            dismiss()
          }
          .disabled(!hasChanges)
        }
      }
    }
  }

  private func commit() {
    let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTitle != note.title.trimmingCharacters(in: .whitespacesAndNewlines) {
      notesStore.renameNote(id: note.id, to: trimmedTitle)
    }
    if draftBody != note.body {
      // Clean up any photo tokens the user removed during the edit so
      // we don't leak orphaned JPEGs locally OR in the cloud. Compare
      // the BEFORE token set to the AFTER token set; anything that
      // disappeared gets purged from PhotoStore + GCS + the manifest.
      let before = Set(NoteContent.photoIDs(in: note.body))
      let after = Set(NoteContent.photoIDs(in: draftBody))
      let removed = before.subtracting(after)

      notesStore.updateBody(id: note.id, to: draftBody)

      for photoID in removed {
        let url = PhotoStore.shared.url(noteID: note.id, photoID: photoID)
        try? FileManager.default.removeItem(at: url)
        let analysisURL = PhotoStore.shared.analysisURL(noteID: note.id, photoID: photoID)
        try? FileManager.default.removeItem(at: analysisURL)
        notesStore.deletePhotoFromCloud(noteID: note.id, photoID: photoID)
      }
    }
  }
}
