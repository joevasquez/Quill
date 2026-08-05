import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI

struct GoogleOAuthSheet: View {
  @ObserveInjection var inject
  @Environment(\.dismiss) private var dismiss

  @State private var isAuthenticating = false
  @State private var isConnected = false
  @State private var errorMessage: String?

  let onConnected: () -> Void

  @Dependency(\.googleOAuth) private var googleOAuth

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      if isConnected {
        Label("Connected to Google", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.subheadline)
      } else {
        Text("Sign in with your Google account to create Gmail drafts and Google Calendar events from voice commands.")
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
        if isConnected {
          Button("Disconnect", role: .destructive) {
            disconnect()
          }
          .controlSize(.regular)
        }
        Spacer()
        Button(isConnected ? "Done" : "Cancel") { dismiss() }
          .keyboardShortcut(isConnected ? .defaultAction : .cancelAction)
        if !isConnected {
          Button {
            signIn()
          } label: {
            if isAuthenticating {
              ProgressView().controlSize(.small)
            } else {
              Text("Sign in with Google")
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isAuthenticating)
        }
      }
    }
    .padding(20)
    .frame(width: 400)
    .task {
      isConnected = await googleOAuth.isAuthorized()
    }
    .enableInjection()
  }

  private var header: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(Color(red: 0.263, green: 0.522, blue: 0.957)) // Google blue #4285F4
        .frame(width: 32, height: 32)
        .overlay(
          Image(systemName: "globe")
            .foregroundStyle(.white)
            .font(.system(size: 16, weight: .semibold))
        )
      VStack(alignment: .leading, spacing: 2) {
        Text("Connect Google")
          .font(.headline)
        Text("Gmail drafts and Google Calendar events from your dictation.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func signIn() {
    isAuthenticating = true
    errorMessage = nil

    Task {
      do {
        _ = try await googleOAuth.authorize(scopes: GoogleOAuthClient.defaultScopes)
        // Best-effort email cache so the GoogleAccountSectionView can show
        // "Connected as <email>" without an extra round-trip on first render.
        _ = await googleOAuth.fetchUserEmail()
        isConnected = true
        onConnected()
      } catch {
        errorMessage = error.localizedDescription
      }
      isAuthenticating = false
    }
  }

  private func disconnect() {
    Task {
      await googleOAuth.disconnect()
      isConnected = false
      dismiss()
    }
  }
}
