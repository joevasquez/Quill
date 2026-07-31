//
//  GoogleAccountView.swift
//  Quill (iOS)
//
//  Settings sub-screen for the Google sign-in state. Mirrors the macOS
//  `GoogleAccountSectionView` — one place to see "am I signed in to
//  Google?" and to disconnect, separate from the per-integration list.
//  Reached from `SettingsView` via NavigationLink.
//

import HexCore
import SwiftUI

struct GoogleAccountView: View {
  @Environment(\.dismiss) private var dismiss

  @AppStorage(IntegrationConnectionStore.userDefaultsKey)
  private var connectedData: Data = Data()

  /// Three-state UI: nil = loading, false = signed out, true = signed in.
  @State private var isAuthorized: Bool?
  @State private var connectedEmail: String?
  @State private var isAuthenticating = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        switch isAuthorized {
        case .none:
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking Google sign-in…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        case .some(true):
          connectedRow
        case .some(false):
          signedOutRow
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Google Account")
      } footer: {
        Text("One sign-in unlocks Gmail drafts and Google Calendar events in Action mode, plus cloud sync across your devices. Quill never reads your inbox or modifies events you didn't dictate.")
      }
    }
    .navigationTitle("Google Account")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { refreshAuthorizationState() }
  }

  // MARK: - Rows

  private var connectedRow: some View {
    HStack(alignment: .center, spacing: 12) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(red: 0.263, green: 0.522, blue: 0.957)) // Google blue
        .frame(width: 38, height: 38)
        .overlay(
          Image(systemName: "checkmark")
            .foregroundStyle(.white)
            .font(.system(size: 18, weight: .bold))
        )

      VStack(alignment: .leading, spacing: 2) {
        Text("Signed in")
          .font(.body.weight(.semibold))
        Text(connectedEmail ?? "Connected to Google")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      Button("Disconnect", role: .destructive) {
        disconnect()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .tint(.red)
    }
    .padding(.vertical, 4)
  }

  private var signedOutRow: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(red: 0.263, green: 0.522, blue: 0.957))
          .frame(width: 38, height: 38)
          .overlay(
            Image(systemName: "globe")
              .foregroundStyle(.white)
              .font(.system(size: 18, weight: .semibold))
          )

        VStack(alignment: .leading, spacing: 2) {
          Text("Not signed in")
            .font(.body.weight(.semibold))
          Text("Sign in to enable Google services in Action mode.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Button {
        signIn()
      } label: {
        HStack {
          if isAuthenticating {
            ProgressView().controlSize(.small)
          }
          Text(isAuthenticating ? "Opening Safari…" : "Sign in with Google")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.purple)
      .disabled(isAuthenticating)
    }
    .padding(.vertical, 4)
  }

  // MARK: - Actions

  private func refreshAuthorizationState() {
    Task {
      let authorized = IOSGoogleOAuthClient.isAuthorized()
      isAuthorized = authorized
      if authorized {
        if let cached = UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) {
          connectedEmail = cached
        } else {
          connectedEmail = await IOSGoogleOAuthClient.fetchUserEmail()
        }
      } else {
        connectedEmail = nil
      }
    }
  }

  private func signIn() {
    isAuthenticating = true
    errorMessage = nil

    Task {
      do {
        _ = try await IOSGoogleOAuthClient.authorize()
        _ = await IOSGoogleOAuthClient.fetchUserEmail()
        // Single sign-in connects both — mirrors disconnect() which
        // already removes them. Without this, the Integrations tab and
        // Action confirmation dropdown wouldn't reflect the new state.
        var current = IntegrationConnectionStore.decode(connectedData)
        current.insert(.gmail)
        current.insert(.googleCalendar)
        connectedData = IntegrationConnectionStore.encode(current)
        refreshAuthorizationState()
      } catch {
        errorMessage = error.localizedDescription
      }
      isAuthenticating = false
    }
  }

  private func disconnect() {
    IOSGoogleOAuthClient.disconnect()
    // Pop Gmail + Google Calendar out of the integration set so the
    // per-row Connect buttons in IntegrationsView reflect reality.
    var updated = IntegrationConnectionStore.decode(connectedData)
    updated.remove(.gmail)
    updated.remove(.googleCalendar)
    connectedData = IntegrationConnectionStore.encode(updated)
    refreshAuthorizationState()
  }
}
