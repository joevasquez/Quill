//
//  PlanSectionView.swift
//  Quill (macOS)
//
//  The Subscription tab: Free and Pro side by side (shared `PlanCatalog`),
//  with one-click selection of either plan. No payments yet — activation
//  is the test toggle; when StoreKit lands, only the buttons change.
//

import ComposableArchitecture
import HexCore
import SwiftUI

struct PlanSectionView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  private var isPro: Bool { store.hexSettings.selectedPlan == "pro" }

  private var googleConnected: Bool {
    UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)?.isEmpty == false
  }

  var body: some View {
    Section {
      VStack(spacing: 6) {
        Image(systemName: "crown.fill")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(QuillDesign.brand.color())
          .frame(width: 52, height: 52)
          .background(Circle().fill(QuillDesign.brand.color(0.14)))
        Text("Your Plan")
          .font(.title3.bold())
        Text("Built-in AI and a copilot that watches your day — no API keys, no setup.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
      .listRowBackground(Color.clear)
    }

    Section {
      HStack(alignment: .top, spacing: 14) {
        planColumn(pro: false)
        planColumn(pro: true)
      }
      .padding(.vertical, 6)
      .listRowBackground(Color.clear)

      if isPro, !googleConnected {
        Label("Sign in to Google (Integrations tab) to use Pro's built-in AI.", systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
      }
    } footer: {
      Text("During the beta, Pro is free to activate. Pro routes AI through Quill's servers using your Google sign-in — no API key to manage.")
        .settingsCaption()
    }
  }

  // MARK: - Columns

  private func planColumn(pro: Bool) -> some View {
    let isCurrent = pro == isPro
    return VStack(alignment: .leading, spacing: 0) {
      // Header
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(pro ? "Pro" : "Free")
            .font(.headline)
          if isCurrent {
            Text("CURRENT")
              .font(.system(size: 9, weight: .heavy))
              .tracking(0.4)
              .foregroundStyle(pro ? .white : .secondary)
              .padding(.vertical, 1.5)
              .padding(.horizontal, 5)
              .background(
                Capsule().fill(pro ? QuillDesign.brand.color() : Color.secondary.opacity(0.18))
              )
          }
        }
        Text(pro ? "Free during the beta" : "$0")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.bottom, 10)

      // Feature rows
      VStack(alignment: .leading, spacing: 8) {
        ForEach(PlanCatalog.rows) { row in
          featureLine(row, pro: pro)
        }
      }

      Spacer(minLength: 12)

      // Selection
      Button {
        store.send(.setSelectedPlan(pro ? "pro" : nil))
      } label: {
        Text(isCurrent ? "Current Plan" : (pro ? "Upgrade to Pro" : "Switch to Free"))
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .buttonStyle(.borderedProminent)
      .tint(pro ? QuillDesign.brand.color() : .gray)
      .disabled(isCurrent)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(pro ? QuillDesign.brand.color(0.06) : Color.primary.opacity(0.03))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .strokeBorder(
              pro ? QuillDesign.brand.color(0.45) : Color.primary.opacity(0.1),
              lineWidth: pro ? 1.5 : 1
            )
        )
    )
  }

  private func featureLine(_ row: PlanFeatureRow, pro: Bool) -> some View {
    let value = pro ? row.pro : row.free
    return HStack(alignment: .top, spacing: 7) {
      Image(systemName: value == nil ? "xmark" : "checkmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(value == nil ? Color.secondary.opacity(0.5) : (pro ? QuillDesign.brand.color() : .green))
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 0) {
        Text(row.name)
          .font(.caption.weight(.semibold))
          .foregroundStyle(value == nil ? .secondary : .primary)
        Text(value ?? "Not included")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
