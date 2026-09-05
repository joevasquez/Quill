//
//  AskQuillView.swift
//  Quill (iOS)
//
//  Conversational retrieval over one note or the user's notebook.
//

import HexCore
import SwiftUI

struct AskQuillView: View {
  let notes: [Note]
  let focusedNoteID: UUID?
  let provider: AIProvider
  var onOpenCitation: (UUID) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  @State private var question = ""
  @State private var answer: NoteAnswer?
  @State private var isSearching = false
  @State private var errorMessage: String?
  @State private var scope: Scope

  private enum Scope: String, CaseIterable, Identifiable {
    case current = "This Note"
    case all = "All Notes"
    var id: String { rawValue }
  }

  init(
    notes: [Note],
    focusedNoteID: UUID?,
    provider: AIProvider,
    onOpenCitation: @escaping (UUID) -> Void
  ) {
    self.notes = notes
    self.focusedNoteID = focusedNoteID
    self.provider = provider
    self.onOpenCitation = onOpenCitation
    _scope = State(initialValue: focusedNoteID == nil ? .all : .current)
  }

  private var searchableNotes: [Note] {
    guard scope == .current, let focusedNoteID,
          let note = notes.first(where: { $0.id == focusedNoteID }) else { return notes }
    return [note]
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        if focusedNoteID != nil {
          Picker("Search", selection: $scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 16)
        }

        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if let answer {
              answerCard(answer)
            } else {
              intro
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
        }

        composer
          .padding(.horizontal, 16)
          .padding(.bottom, 8)
      }
      .background(theme.page.ignoresSafeArea())
      .navigationTitle("Ask Quill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .alert("Ask Quill", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: "sparkle.magnifyingglass")
        .font(.system(size: 34))
        .foregroundStyle(QuillDesign.brand.color())
      Text("Ask about anything you've captured")
        .font(.title3.bold())
      Text("Quill answers from your notes and shows which notes support the answer.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 24)
  }

  private func answerCard(_ answer: NoteAnswer) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(answer.answer)
        .font(.body)
        .textSelection(.enabled)

      if !answer.citations.isEmpty {
        Text("Sources")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(answer.citations) { citation in
          Button {
            dismiss()
            onOpenCitation(citation.noteID)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Label(citation.noteTitle, systemImage: "note.text")
                .font(.subheadline.weight(.semibold))
              Text(citation.excerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.chip))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(theme.card)
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .strokeBorder(theme.hair, lineWidth: 0.5)
        )
    )
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Ask about your notes", text: $question, axis: .vertical)
        .lineLimit(1...4)
        .submitLabel(.send)
        .onSubmit { submit() }

      Button(action: submit) {
        Group {
          if isSearching { ProgressView().tint(.white) }
          else { Image(systemName: "arrow.up") }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(width: 36, height: 36)
        .background(Circle().fill(QuillDesign.brand.color()))
      }
      .disabled(isSearching || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel("Ask")
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(theme.card)
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .strokeBorder(theme.hair, lineWidth: 0.5)
        )
    )
  }

  private func submit() {
    let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !submitted.isEmpty, !isSearching else { return }
    isSearching = true
    Task {
      do {
        answer = try await TextAIClient.answerQuestion(
          submitted,
          notes: searchableNotes,
          provider: provider
        )
        question = ""
      } catch {
        errorMessage = error.localizedDescription
      }
      isSearching = false
    }
  }
}
