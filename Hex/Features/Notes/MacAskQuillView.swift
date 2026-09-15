#if os(macOS)
import HexCore
import SwiftUI

struct MacAskQuillView: View {
  let notes: [SyncableNote]
  let focusedNoteID: UUID?
  let provider: AIProvider
  var onOpenCitation: (UUID) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var question = ""
  @State private var answer: MacNoteAnswer?
  @State private var isSearching = false
  @State private var errorMessage: String?
  @State private var scope: Scope

  private enum Scope: String, CaseIterable, Identifiable {
    case current = "This Note"
    case all = "All Notes"
    var id: String { rawValue }
  }

  init(notes: [SyncableNote], focusedNoteID: UUID?, provider: AIProvider, onOpenCitation: @escaping (UUID) -> Void) {
    self.notes = notes
    self.focusedNoteID = focusedNoteID
    self.provider = provider
    self.onOpenCitation = onOpenCitation
    _scope = State(initialValue: focusedNoteID == nil ? .all : .current)
  }

  private var searchableNotes: [SyncableNote] {
    guard scope == .current, let focusedNoteID,
          let note = notes.first(where: { $0.id == focusedNoteID }) else { return notes }
    return [note]
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Ask Quill", systemImage: "sparkle.magnifyingglass").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(20)
      Divider()

      if focusedNoteID != nil {
        Picker("Search", selection: $scope) {
          ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)
        .padding(.top, 16)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let answer { answerCard(answer) }
          else {
            Image(systemName: "sparkle.magnifyingglass")
              .font(.system(size: 34)).foregroundStyle(QuillDesign.brand.color())
            Text("Ask about anything you've captured").font(.title3.bold())
            Text("Quill answers from your notes and shows which notes support the answer.")
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Ask about your notes", text: $question, axis: .vertical)
          .lineLimit(1...4).onSubmit { submit() }
        Button(action: submit) {
          if isSearching { ProgressView().controlSize(.small) }
          else { Image(systemName: "arrow.up") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSearching || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Ask")
      }
      .padding(16)
      .background(.bar)
    }
    .frame(width: 650, height: 560)
    .alert("Ask Quill", isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
  }

  private func answerCard(_ answer: MacNoteAnswer) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(answer.answer).textSelection(.enabled)
      if !answer.citations.isEmpty {
        Text("Sources").font(.caption.bold()).foregroundStyle(.secondary)
        ForEach(answer.citations) { citation in
          Button {
            onOpenCitation(citation.noteID)
            dismiss()
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Label(citation.noteTitle, systemImage: "note.text").font(.headline)
              Text(citation.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: QuillDesign.Radius.card))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func submit() {
    let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !submitted.isEmpty, !isSearching else { return }
    isSearching = true
    Task {
      do {
        answer = try await MacNoteQuestionClient.answer(submitted, notes: searchableNotes, provider: provider)
        question = ""
      } catch { errorMessage = error.localizedDescription }
      isSearching = false
    }
  }
}
#endif
