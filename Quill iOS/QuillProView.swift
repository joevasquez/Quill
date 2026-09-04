//
//  QuillProView.swift
//  Quill (iOS)
//
//  The dedicated subscription surface: Free vs Pro comparison (from the
//  shared `PlanCatalog`) plus plan activation. No payments exist yet —
//  activation is the test toggle, mirroring the macOS Plan tab. When
//  StoreKit lands, only the activation affordance changes.
//

import HexCore
import SwiftUI

struct QuillProView: View {
  var body: some View {
    List {
      QuillPlanSections()
    }
    .navigationTitle("Quill Pro")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Reusable plan controls. Settings embeds these beside the Google account
/// and sync controls so plan choice and the account that powers Pro live in
/// one place; `QuillProView` still uses them for contextual upgrade links.
struct QuillPlanSections: View {
  @AppStorage(QuillIOSSettingsKey.selectedPlan) private var selectedPlanRaw: String = ""
  @Environment(\.colorScheme) private var colorScheme

  private var isPro: Bool { selectedPlanRaw == "pro" }
  private var googleConnected: Bool { IOSGoogleOAuthClient.isAuthorized() }

  var body: some View {
    Group {
      Section {
        header
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      Section("What's included") {
        ForEach(PlanCatalog.rows) { row in
          featureRow(row)
        }
      }

      Section {
        if isPro {
          Label {
            Text("Pro is active" + (googleConnected ? "" : " — sign in to Google to use it"))
              .fontWeight(.medium)
          } icon: {
            Image(systemName: googleConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
              .foregroundStyle(googleConnected ? .green : .orange)
          }
          Button("Switch to Free", role: .destructive) {
            selectedPlanRaw = ""
          }
        } else {
          Button {
            selectedPlanRaw = "pro"
          } label: {
            Text("Activate Pro")
              .font(.headline)
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 6)
          }
          .listRowBackground(QuillDesign.brand.color())
        }
      } footer: {
        Text(
          isPro
            ? "Pro routes AI through Quill's servers using your Google sign-in — no API key to manage."
            : "During the beta, Pro is free to activate. Requires a Google sign-in for AI without an API key."
        )
      }
    }
  }

  private var header: some View {
    VStack(spacing: 10) {
      Image(systemName: "crown.fill")
        .quillFont(30, weight: .semibold)
        .foregroundStyle(QuillDesign.brand.color())
        .frame(width: 64, height: 64)
        .background(Circle().fill(QuillDesign.brand.color(0.14)))
      HStack(spacing: 8) {
        Text("Quill Pro")
          .font(.title2.bold())
        if isPro {
          Text("ACTIVE")
            .quillFont(10, weight: .heavy)
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Capsule().fill(QuillDesign.brand.color()))
        }
      }
      Text("Built-in AI and a copilot that watches your day — no API keys, no setup.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
  }

  private func featureRow(_ row: PlanFeatureRow) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: row.systemImage)
        .quillFont(15, weight: .medium)
        .foregroundStyle(QuillDesign.brand.color())
        .frame(width: 24)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        Text(row.name)
          .font(.subheadline.weight(.semibold))
        HStack(alignment: .top, spacing: 6) {
          tierChip("FREE", dimmed: false)
          Text(row.free ?? "Not included")
            .font(.caption)
            .foregroundStyle(row.free == nil ? .tertiary : .secondary)
        }
        HStack(alignment: .top, spacing: 6) {
          tierChip("PRO", dimmed: false, tinted: true)
          Text(row.pro)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 3)
  }

  private func tierChip(_ label: String, dimmed: Bool, tinted: Bool = false) -> some View {
    Text(label)
      .quillFont(8.5, weight: .heavy)
      .tracking(0.4)
      .foregroundStyle(tinted ? Color.white : Color.secondary)
      .padding(.vertical, 1)
      .padding(.horizontal, 4)
      .background(
        Capsule().fill(tinted ? QuillDesign.brand.color() : Color.secondary.opacity(0.15))
      )
      .frame(width: 34, alignment: .leading)
  }
}
