import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI

struct TodoistTokenSheet: View {
  @ObserveInjection var inject
  @Environment(\.dismiss) private var dismiss

  @State private var token: String = ""
  @State private var isValidating = false
  @State private var errorMessage: String?
  @State private var hasExistingToken = false

  let onConnected: () -> Void

  @Dependency(\.keychain) private var keychain
  @Dependency(\.todoist) private var todoist

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      VStack(alignment: .leading, spacing: 6) {
        Text("API Token")
          .font(.subheadline.weight(.semibold))
        SecureField("Paste token", text: $token)
          .textFieldStyle(.roundedBorder)
          .onSubmit { validateAndSave() }

        Text("Get a token at todoist.com → Settings → Integrations → Developer.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Spacer(minLength: 0)

      HStack {
        if hasExistingToken {
          Button("Disconnect", role: .destructive) {
            disconnect()
          }
          .controlSize(.regular)
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button {
          validateAndSave()
        } label: {
          if isValidating {
            ProgressView().controlSize(.small)
          } else {
            Text("Connect")
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(token.isEmpty || isValidating)
      }
    }
    .padding(20)
    .frame(width: 380)
    .task {
      hasExistingToken = (await keychain.read(KeychainKey.todoistAPIToken)?.isEmpty == false)
    }
    .enableInjection()
  }

  private var header: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(Color(red: 0.894, green: 0.263, blue: 0.196)) // Todoist red #E44332
        .frame(width: 32, height: 32)
        .overlay(
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.white)
            .font(.system(size: 16, weight: .semibold))
        )
      VStack(alignment: .leading, spacing: 2) {
        Text("Connect Todoist")
          .font(.headline)
        Text("Send dictated tasks to Todoist with natural-language due dates.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func validateAndSave() {
    guard !token.isEmpty else { return }
    isValidating = true
    errorMessage = nil

    Task {
      let result = await todoist.validateToken(token: token)
      if result.isValid {
        try? await keychain.save(KeychainKey.todoistAPIToken, token)
        onConnected()
        dismiss()
      } else {
        errorMessage = "That token didn't work. Double-check it and try again."
      }
      isValidating = false
    }
  }

  private func disconnect() {
    Task {
      await keychain.delete(KeychainKey.todoistAPIToken)
      dismiss()
    }
  }
}
