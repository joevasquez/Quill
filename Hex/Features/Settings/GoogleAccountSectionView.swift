//
//  GoogleAccountSectionView.swift
//  Hex (macOS)
//
//  Top-of-tab "Google Account" panel that surfaces the existing
//  GoogleOAuthClient state outside of the per-integration rows. The
//  per-row Connect buttons in IntegrationsSectionView still work, but
//  this section is the canonical place to see "am I signed in?" and to
//  disconnect — clicking Disconnect here clears tokens and de-toggles
//  every Google-backed integration.
//

import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI

struct GoogleAccountSectionView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  @AppStorage(IntegrationConnectionStore.userDefaultsKey)
  private var connectedData: Data = Data()

  @Dependency(\.googleOAuth) private var googleOAuth

  /// Three-state UI: nil = still loading, false = signed out, true = signed in.
  /// Avoids a flash of the "Sign in" button on tab switch when the user is
  /// already authenticated.
  @State private var isAuthorized: Bool?
  @State private var connectedEmail: String?
  @State private var showingOAuthSheet = false

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
          .padding(.vertical, 2)
        case .some(true):
          connectedRow
        case .some(false):
          signedOutRow
        }
      } header: {
        Text("Google Account")
      } footer: {
        Text("One sign-in unlocks Gmail drafts and Google Calendar events in Action mode. Quill never reads your inbox or modifies events you didn't dictate.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showingOAuthSheet) {
      GoogleOAuthSheet(onConnected: {
        // The sheet has already cached the email and stored tokens. Refresh
        // our local UI state so the row flips to "Connected" without a
        // round-trip on dismiss.
        Task { await refreshAuthorizationState() }
      })
    }
    .task {
      await refreshAuthorizationState()
    }
    .enableInjection()
  }

  // MARK: - Rows

  private var connectedRow: some View {
    HStack(alignment: .center, spacing: 12) {
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(Color(red: 0.263, green: 0.522, blue: 0.957)) // Google blue
        .frame(width: 32, height: 32)
        .overlay(
          Image(systemName: "checkmark")
            .foregroundStyle(.white)
            .font(.system(size: 16, weight: .bold))
        )

      VStack(alignment: .leading, spacing: 2) {
        Text("Signed in")
          .font(.body.weight(.semibold))
        Text(connectedEmail ?? "Connected to Google")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button("Disconnect", role: .destructive) {
        disconnect()
      }
      .controlSize(.small)
    }
    .padding(.vertical, 2)
  }

  private var signedOutRow: some View {
    HStack(alignment: .center, spacing: 12) {
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(Color(red: 0.263, green: 0.522, blue: 0.957))
        .frame(width: 32, height: 32)
        .overlay(
          Image(systemName: "globe")
            .foregroundStyle(.white)
            .font(.system(size: 16, weight: .semibold))
        )

      VStack(alignment: .leading, spacing: 2) {
        Text("Not signed in")
          .font(.body.weight(.semibold))
        Text("Sign in to enable Gmail and Google Calendar in Action mode.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      Button("Sign in") { showingOAuthSheet = true }
        .controlSize(.small)
    }
    .padding(.vertical, 2)
  }

  // MARK: - Actions

  private func refreshAuthorizationState() async {
    let authorized = await googleOAuth.isAuthorized()
    isAuthorized = authorized
    if authorized {
      if let cached = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey) {
        connectedEmail = cached
      } else {
        connectedEmail = await googleOAuth.fetchUserEmail()
      }
      var current = IntegrationConnectionStore.decode(connectedData)
      if !current.contains(.gmail) || !current.contains(.googleCalendar) {
        current.insert(.gmail)
        current.insert(.googleCalendar)
        connectedData = IntegrationConnectionStore.encode(current)
      }
    } else {
      connectedEmail = nil
    }
  }

  private func disconnect() {
    Task {
      await googleOAuth.disconnect()
      // Also pop Gmail + Google Calendar out of the integration set so the
      // per-row Connect buttons are accurate. Disconnecting one Google
      // service implicitly disconnects both because they share OAuth.
      var updated = IntegrationConnectionStore.decode(connectedData)
      updated.remove(.gmail)
      updated.remove(.googleCalendar)
      connectedData = IntegrationConnectionStore.encode(updated)
      await refreshAuthorizationState()
    }
  }
}
