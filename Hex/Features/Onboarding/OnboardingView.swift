//
//  OnboardingView.swift
//  Hex (macOS)
//
//  First-launch walk-through with a light paper/cream theme and a
//  branching plan-choice flow. Steps:
//
//    1. Welcome — feather floats in, serif title.
//    2. Permissions — Microphone, Accessibility, Input Monitoring.
//    3. Plan choice — side-by-side BYOK vs Pro cards.
//    4a. Pro trial (branch A — placeholder during beta).
//    4b. BYOK provider → get key → verify (branch B, 3 sub-steps).
//    5. Google sign-in (optional).
//    6. First dictation — visual HUD mock.
//    7. Done — quick-start cards + "Open Quill".
//
//  Navigation branches at step 3: Pro goes through proTrial then
//  rejoins at googleSignIn; BYOK goes through provider → getKey →
//  verify then rejoins at googleSignIn.
//
//  Completion is persisted in `HexSettings.hasCompletedOnboarding`.
//  A "Replay Tutorial" entry in Settings → General resets the flag.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

// MARK: - Color palette

private enum OB {
  static let purple = Color(red: 0.486, green: 0.227, blue: 0.929)
  static let purpleLight = Color(red: 0.961, green: 0.941, blue: 1.0)
  static let purpleMid = Color(red: 0.706, green: 0.553, blue: 1.0)
  static let purpleDark = Color(red: 0.357, green: 0.129, blue: 0.714)
  static let paper = Color(red: 0.957, green: 0.945, blue: 0.925)
  static let paperElev = Color(red: 0.984, green: 0.976, blue: 0.961)
  static let ink = Color(red: 0.110, green: 0.110, blue: 0.118)
  static let inkSoft = Color(red: 0.294, green: 0.286, blue: 0.318)
  static let inkMute = Color(red: 0.502, green: 0.490, blue: 0.525)
  static let line = Color.black.opacity(0.10)
  static let proGreen = Color(red: 0.122, green: 0.478, blue: 0.227)
  static let conRed = Color(red: 0.757, green: 0.271, blue: 0.137)
}

// MARK: - Step enum + navigation

private enum OnboardingStep: Int {
  case welcome = 0
  case permissions = 1
  case planChoice = 2
  case proTrial = 3      // branch A
  case byokProvider = 4  // branch B 1/3
  case byokGetKey = 5    // branch B 2/3
  case byokVerify = 6    // branch B 3/3
  case googleSignIn = 7
  case firstDictation = 8
  case done = 9
}

private enum PlanChoice {
  case pro, byok
}

/// Maps each step to one of 7 logical dot positions so the dots
/// reflect the conceptual flow without exposing branching.
private func dotPosition(for step: OnboardingStep) -> Int {
  switch step {
  case .welcome:        return 0
  case .permissions:    return 1
  case .planChoice:     return 2
  case .proTrial:       return 3
  case .byokProvider:   return 3
  case .byokGetKey:     return 3
  case .byokVerify:     return 3
  case .googleSignIn:   return 4
  case .firstDictation: return 5
  case .done:           return 6
  }
}

private func nextStep(from step: OnboardingStep, plan: PlanChoice?) -> OnboardingStep? {
  switch step {
  case .welcome:        return .permissions
  case .permissions:    return .planChoice
  case .planChoice:
    switch plan {
    case .pro:  return .proTrial
    case .byok: return .byokProvider
    case .none: return nil
    }
  case .proTrial:       return .googleSignIn
  case .byokProvider:   return .byokGetKey
  case .byokGetKey:     return .byokVerify
  case .byokVerify:     return .googleSignIn
  case .googleSignIn:   return .firstDictation
  case .firstDictation: return .done
  case .done:           return nil
  }
}

private func previousStep(from step: OnboardingStep, plan: PlanChoice?) -> OnboardingStep? {
  switch step {
  case .welcome:        return nil
  case .permissions:    return .welcome
  case .planChoice:     return .permissions
  case .proTrial:       return .planChoice
  case .byokProvider:   return .planChoice
  case .byokGetKey:     return .byokProvider
  case .byokVerify:     return .byokGetKey
  case .googleSignIn:
    switch plan {
    case .pro:  return .proTrial
    case .byok: return .byokVerify
    case .none: return .planChoice
    }
  case .firstDictation: return .googleSignIn
  case .done:           return .firstDictation
  }
}

// MARK: - Main view

struct OnboardingView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let inputMonitoringPermission: PermissionStatus
  let onDismiss: () -> Void

  @State private var step: OnboardingStep = .welcome
  @State private var selectedPlan: PlanChoice?
  @State private var selectedProvider: AIProvider = .anthropic

  var body: some View {
    ZStack {
      OnboardingBackground()

      Group {
        switch step {
        case .welcome:
          WelcomeStep(onContinue: { advance() })

        case .permissions:
          PermissionsStep(
            store: store,
            microphonePermission: microphonePermission,
            accessibilityPermission: accessibilityPermission,
            inputMonitoringPermission: inputMonitoringPermission,
            onContinue: { advance() }
          )

        case .planChoice:
          PlanChoiceStep(
            onChoosePro: {
              selectedPlan = .pro
              advance()
            },
            onChooseBYOK: {
              selectedPlan = .byok
              advance()
            }
          )

        case .proTrial:
          ProTrialStep(
            onContinue: { advance() },
            onBack: { goBack() }
          )

        case .byokProvider:
          BYOKProviderStep(
            selectedProvider: $selectedProvider,
            onContinue: { advance() },
            onBack: { goBack() }
          )

        case .byokGetKey:
          BYOKGetKeyStep(
            provider: selectedProvider,
            onContinue: { advance() },
            onBack: { goBack() }
          )

        case .byokVerify:
          BYOKVerifyStep(
            store: store,
            provider: selectedProvider,
            onContinue: { advance() },
            onBack: { goBack() }
          )

        case .googleSignIn:
          GoogleSignInStep(
            onContinue: { advance() },
            onSkip: { advance() }
          )

        case .firstDictation:
          FirstDictationStep(
            onContinue: { advance() },
            onSkip: { advance() }
          )

        case .done:
          DoneStep(onFinish: complete)
        }
      }
      .id(step)
      .transition(.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      ))
      .animation(.spring(duration: 0.45, bounce: 0.2), value: step)

      // Skip button — top-right, visible on every step
      VStack {
        HStack {
          Spacer()
          Button("Skip", action: complete)
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(OB.inkMute)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
              Capsule().fill(OB.ink.opacity(0.06))
            )
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        Spacer()
      }
    }
    .frame(minWidth: 720, minHeight: 540)
  }

  private func advance() {
    if let next = nextStep(from: step, plan: selectedPlan) {
      step = next
    } else {
      complete()
    }
  }

  private func goBack() {
    if let prev = previousStep(from: step, plan: selectedPlan) {
      step = prev
    }
  }

  private func complete() {
    store.send(.markOnboardingComplete)
    onDismiss()
  }
}

// MARK: - Background

private struct OnboardingBackground: View {
  var body: some View {
    ZStack {
      OB.paper

      RadialGradient(
        colors: [OB.purpleLight, OB.paper],
        center: .init(x: 0.5, y: 0.3),
        startRadius: 0,
        endRadius: 400
      )
      .opacity(0.6)
    }
  }
}

// MARK: - Step dots

private struct StepDots: View {
  let currentPosition: Int
  let total: Int

  init(step: OnboardingStep) {
    self.currentPosition = dotPosition(for: step)
    self.total = 7
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(0 ..< total, id: \.self) { idx in
        Capsule()
          .fill(idx == currentPosition ? OB.purple : Color.black.opacity(0.15))
          .frame(width: idx == currentPosition ? 22 : 6, height: 6)
          .animation(.spring(duration: 0.4, bounce: 0.3), value: currentPosition)
      }
    }
  }
}

// MARK: - Shared button

private struct OnboardingButton: View {
  enum Variant { case primary, secondary, ghost, dark }

  let label: String
  var variant: Variant = .primary
  var isDisabled: Bool = false
  var fullWidth: Bool = false
  let action: () -> Void

  init(
    _ label: String,
    variant: Variant = .primary,
    isDisabled: Bool = false,
    fullWidth: Bool = false,
    action: @escaping () -> Void
  ) {
    self.label = label
    self.variant = variant
    self.isDisabled = isDisabled
    self.fullWidth = fullWidth
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: 13.5, weight: .semibold))
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .padding(.vertical, 11)
        .padding(.horizontal, fullWidth ? 0 : 20)
        .foregroundStyle(foregroundColor)
        .background(backgroundView)
        .overlay(borderView)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.5 : 1)
  }

  private var foregroundColor: Color {
    switch variant {
    case .primary: .white
    case .secondary: OB.ink
    case .ghost: OB.inkSoft
    case .dark: .white
    }
  }

  @ViewBuilder
  private var backgroundView: some View {
    switch variant {
    case .primary:
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(
          LinearGradient(
            colors: [OB.purple, OB.purpleDark],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .shadow(color: OB.purple.opacity(0.30), radius: 9, y: 3)
    case .secondary:
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(Color.white)
        .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
    case .ghost:
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(Color.clear)
    case .dark:
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(OB.ink)
    }
  }

  @ViewBuilder
  private var borderView: some View {
    switch variant {
    case .secondary:
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .stroke(OB.line, lineWidth: 1)
    default:
      EmptyView()
    }
  }
}

// MARK: - Pip

private struct Pip: View {
  enum Tone { case purple, green, grey, dark }
  let tone: Tone
  let text: String

  init(_ text: String, tone: Tone = .purple) {
    self.text = text
    self.tone = tone
  }

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .bold))
      .tracking(0.6)
      .textCase(.uppercase)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .foregroundStyle(fgColor)
      .background(Capsule().fill(bgColor))
  }

  private var bgColor: Color {
    switch tone {
    case .purple: OB.purpleLight
    case .green: Color(red: 0.906, green: 0.969, blue: 0.922)
    case .grey: OB.paperElev
    case .dark: OB.ink
    }
  }

  private var fgColor: Color {
    switch tone {
    case .purple: OB.purpleDark
    case .green: OB.proGreen
    case .grey: OB.inkSoft
    case .dark: .white
    }
  }
}

// MARK: - Kbd (keyboard chip)

private struct Kbd: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 12, weight: .semibold, design: .monospaced))
      .foregroundStyle(OB.inkSoft)
      .padding(.horizontal, 7)
      .frame(minWidth: 24, minHeight: 24)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .fill(Color.white)
          .shadow(color: Color.black.opacity(0.08), radius: 0, y: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .stroke(OB.line, lineWidth: 1)
      )
  }
}

// MARK: - Permission row

private struct PermissionRow: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let state: PermissionStatus
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(OB.purpleDark)
          .frame(width: 32, height: 32)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(OB.purpleLight)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(OB.ink)
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(OB.inkMute)
        }
        Spacer()
        statusGlyph
      }
      .padding(14)
      .padding(.horizontal, 2)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .stroke(state == .granted ? OB.proGreen.opacity(0.3) : OB.line, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(state == .granted)
  }

  @ViewBuilder
  private var statusGlyph: some View {
    switch state {
    case .granted:
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(OB.proGreen)
        Text("Granted")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(OB.proGreen)
      }
    case .denied:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
    case .notDetermined:
      OnboardingButton("Grant", variant: .secondary) {}
        .allowsHitTesting(false) // The outer button handles the tap
    }
  }
}

// MARK: - Cached feather

/// Cache of pre-rendered purple-tinted feather NSImages keyed by
/// pixel side length. Each entry is rendered once via lockFocus +
/// drawn-on-source-in purpleDark fill, then reused across body
/// recomputations and animation frames.
private enum OnboardingFeather {
  nonisolated(unsafe) private static var cache: [CGFloat: NSImage] = [:]

  static func image(side: CGFloat) -> NSImage {
    if let cached = cache[side] { return cached }
    guard let source = NSImage(named: "Feather") else { return NSImage() }
    let scaled = NSImage(size: NSSize(width: side, height: side))
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    scaled.lockFocus()
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    // Use purpleDark tint for the light theme
    NSColor(red: 0.357, green: 0.129, blue: 0.714, alpha: 1).setFill()
    rect.fill(using: .sourceIn)
    scaled.unlockFocus()
    cache[side] = scaled
    return scaled
  }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
  let onContinue: () -> Void
  @State private var featherOffset: CGFloat = -80
  @State private var featherOpacity: Double = 0
  @State private var contentOpacity: Double = 0

  var body: some View {
    VStack(spacing: 18) {
      Spacer()

      Image(nsImage: OnboardingFeather.image(side: 64))
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 64, height: 64)
        .offset(y: featherOffset)
        .opacity(featherOpacity)
        .onAppear {
          QuillMotion.run(.spring(duration: 1.0, bounce: 0.3)) {
            featherOffset = 0
            featherOpacity = 1
          }
          QuillMotion.run(.easeIn(duration: 0.4).delay(0.5)) {
            contentOpacity = 1
          }
        }

      VStack(spacing: 10) {
        // "Welcome to *Quill*." — serif, italic Quill in purpleDark
        (Text("Welcome to ")
          .font(.system(size: 48, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        + Text("Quill")
          .font(.system(size: 48, weight: .regular, design: .serif).italic())
          .foregroundStyle(OB.purpleDark)
        + Text(".")
          .font(.system(size: 48, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        )
        .tracking(-0.96)

        Text("Voice-first AI for your Mac. Speak to write. Highlight to transform. Talk to act \u{2014} anywhere on your desktop.")
          .font(.system(size: 16))
          .foregroundStyle(OB.inkSoft)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
          .lineSpacing(4)
      }
      .opacity(contentOpacity)

      OnboardingButton("Get started \u{2192}", action: onContinue)
        .opacity(contentOpacity)
        .padding(.top, 14)

      Text("Takes about 90 seconds.")
        .font(.system(size: 11))
        .foregroundStyle(OB.inkMute)
        .opacity(contentOpacity)

      Spacer()
    }
    .padding(.horizontal, 60)
  }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let inputMonitoringPermission: PermissionStatus
  let onContinue: () -> Void

  private var requiredGranted: Bool {
    microphonePermission == .granted && accessibilityPermission == .granted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 6) {
        StepDots(step: .permissions)

        Text("Grant access")
          .font(.system(size: 30, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
          .tracking(-0.45)
          .padding(.top, 8)

        Text("Quill needs three things to work. We'll never record without you holding the hotkey.")
          .font(.system(size: 14))
          .foregroundStyle(OB.inkSoft)
          .frame(maxWidth: 480, alignment: .leading)
      }

      VStack(spacing: 8) {
        PermissionRow(
          title: "Microphone",
          subtitle: "So Quill can hear you.",
          systemImage: "mic.fill",
          state: microphonePermission,
          action: { store.send(.requestMicrophone) }
        )
        PermissionRow(
          title: "Accessibility",
          subtitle: "To insert text into any app.",
          systemImage: "hand.point.up.left",
          state: accessibilityPermission,
          action: { store.send(.requestAccessibility) }
        )
        PermissionRow(
          title: "Input Monitoring",
          subtitle: "Optional \u{2014} only needed for global hotkeys. Quill may need to quit and reopen after granting.",
          systemImage: "keyboard",
          state: inputMonitoringPermission,
          action: { store.send(.requestInputMonitoring) }
        )
        .opacity(0.85)
      }
      .padding(.top, 4)

      Spacer()

      HStack {
        Spacer()
        OnboardingButton(
          requiredGranted ? "Continue \u{2192}" : "Grant Microphone + Accessibility to continue",
          isDisabled: !requiredGranted,
          action: onContinue
        )
      }
    }
    .padding(.horizontal, 80)
    .padding(.top, 48)
    .padding(.bottom, 40)
  }
}

// MARK: - Step 3: Plan choice

private struct PlanChoiceStep: View {
  let onChoosePro: () -> Void
  let onChooseBYOK: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      StepDots(step: .planChoice)

      VStack(spacing: 6) {
        (Text("How would you like to ")
          .font(.system(size: 30, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        + Text("pay for the AI?")
          .font(.system(size: 30, weight: .regular, design: .serif).italic())
          .foregroundStyle(OB.purpleDark)
        )
        .tracking(-0.45)
        .multilineTextAlignment(.center)
        .padding(.top, 8)

        Text("Quill itself is the same on both plans. The difference is who pays for the AI calls behind the scenes.")
          .font(.system(size: 13.5))
          .foregroundStyle(OB.inkSoft)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 460)
      }

      // Side-by-side cards
      HStack(spacing: 14) {
        // BYOK card
        byokCard

        // Pro card
        proCard
      }
      .padding(.top, 4)

      Text("You can switch between plans anytime in Settings.")
        .font(.system(size: 11.5))
        .foregroundStyle(OB.inkMute)

      Spacer().frame(height: 0)
    }
    .padding(.horizontal, 60)
    .padding(.top, 32)
    .padding(.bottom, 24)
  }

  private var byokCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Pip("One-time", tone: .grey)
        Spacer()
        Text("Power users")
          .font(.system(size: 11))
          .foregroundStyle(OB.inkMute)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Bring Your Own Keys")
          .font(.system(size: 22, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)

        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("$50")
            .font(.system(size: 36, weight: .regular, design: .serif))
            .foregroundStyle(OB.ink)
            .tracking(-0.72)
          Text("once \u{00B7} forever")
            .font(.system(size: 12))
            .foregroundStyle(OB.inkMute)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        proConRow("+", "Pay AI providers directly, often pennies/month", isPositive: true)
        proConRow("+", "Pick any model: Claude or GPT-4o", isPositive: true)
        proConRow("+", "Data goes straight to the provider", isPositive: true)
        proConRow("\u{2212}", "2 minutes of setup \u{2014} we'll guide you", isPositive: false)
        proConRow("\u{2212}", "No cross-device sync (Mac & iPhone stay separate)", isPositive: false)
        proConRow("\u{2212}", "Apple-only actions (Calendar, Reminders, Mail)", isPositive: false)
      }
      .padding(.top, 4)

      Spacer(minLength: 0)

      OnboardingButton("Use my own keys", variant: .secondary, fullWidth: true, action: onChooseBYOK)
    }
    .padding(18)
    .padding(.horizontal, 2)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(Color.white)
    )
    .overlay(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .stroke(OB.line, lineWidth: 1)
    )
  }

  private var proCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Pip("\u{2605} Recommended", tone: .dark)
        Spacer()
        Text("10-day free trial")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(OB.purpleDark)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Quill Pro")
          .font(.system(size: 22, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)

        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("$10")
            .font(.system(size: 36, weight: .regular, design: .serif))
            .foregroundStyle(OB.purpleDark)
            .tracking(-0.72)
          Text("/ month")
            .font(.system(size: 12))
            .foregroundStyle(OB.inkMute)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        proConRow("+", "Zero setup \u{2014} works the instant you finish", isPositive: true)
        proConRow("+", "Unlimited dictation, edits, & actions", isPositive: true)
        proConRow("+", "Cross-device sync between Mac & iPhone", isPositive: true)
        proConRow("+", "3rd-party actions: Gmail, Calendar, Linear, Todoist\u{2026}", isPositive: true)
        proConRow("\u{2212}", "Recurring monthly charge", isPositive: false)
      }
      .padding(.top, 4)

      Spacer(minLength: 0)

      OnboardingButton("Start 10-day free trial", fullWidth: true, action: onChoosePro)
    }
    .padding(18)
    .padding(.horizontal, 2)
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color.white, OB.purpleLight],
              startPoint: .top,
              endPoint: .bottom
            )
          )

        // Decorative glow
        Circle()
          .fill(
            RadialGradient(
              colors: [OB.purpleMid.opacity(0.25), Color.clear],
              center: .center,
              startRadius: 0,
              endRadius: 100
            )
          )
          .frame(width: 200, height: 200)
          .offset(x: 60, y: -80)
      }
      .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous))
    )
    .overlay(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .stroke(OB.purpleMid, lineWidth: 1)
    )
    .shadow(color: OB.purple.opacity(0.18), radius: 16, y: 6)
  }

  private func proConRow(_ symbol: String, _ text: String, isPositive: Bool) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(symbol)
        .font(.system(size: 12.5, weight: .bold))
        .foregroundStyle(isPositive ? OB.proGreen : OB.conRed)
        .frame(width: 12)
      Text(text)
        .font(.system(size: 12.5))
        .foregroundStyle(OB.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Step 4a: Pro trial (placeholder)

private struct ProTrialStep: View {
  let onContinue: () -> Void
  let onBack: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        StepDots(step: .proTrial)
        Text("QUILL PRO \u{00B7} 10-DAY FREE TRIAL")
          .font(.system(size: 11, weight: .bold))
          .tracking(0.66)
          .foregroundStyle(OB.inkMute)
      }

      VStack(alignment: .leading, spacing: 6) {
        (Text("Start your ")
          .font(.system(size: 30, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        + Text("10-day trial")
          .font(.system(size: 30, weight: .regular, design: .serif).italic())
          .foregroundStyle(OB.purpleDark)
        )
        .tracking(-0.45)

        Text("Full Quill Pro for ten days. We'll remind you two days before it ends \u{2014} cancel anytime, no charge if you bail before day 10.")
          .font(.system(size: 13.5))
          .foregroundStyle(OB.inkSoft)
          .frame(maxWidth: 540, alignment: .leading)
      }

      // Email + card preview mock
      VStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("EMAIL")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.44)
            .foregroundStyle(OB.inkMute)
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .stroke(OB.purple, lineWidth: 1.5)
            .frame(height: 42)
            .overlay(
              Text("your.email@example.com")
                .font(.system(size: 13.5))
                .foregroundStyle(OB.inkMute)
                .padding(.horizontal, 14),
              alignment: .leading
            )
        }

        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 6) {
            Text("CARD ON FILE")
              .font(.system(size: 11, weight: .semibold))
              .tracking(0.44)
              .foregroundStyle(OB.inkMute)
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(OB.paperElev)
              .frame(height: 42)
              .overlay(
                RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                  .stroke(OB.line, lineWidth: 1)
              )
              .overlay(
                Text("\u{2022}\u{2022}\u{2022}\u{2022} \u{2022}\u{2022}\u{2022}\u{2022} \u{2022}\u{2022}\u{2022}\u{2022} 4242")
                  .font(.system(size: 13, design: .monospaced))
                  .foregroundStyle(OB.inkMute)
                  .padding(.horizontal, 14),
                alignment: .leading
              )
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("FIRST CHARGE")
              .font(.system(size: 11, weight: .semibold))
              .tracking(0.44)
              .foregroundStyle(OB.inkMute)
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(OB.paperElev)
              .frame(height: 42)
              .overlay(
                RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                  .stroke(OB.line, lineWidth: 1)
              )
              .overlay(
                Text("After trial \u{00B7} $10.00")
                  .font(.system(size: 13))
                  .foregroundStyle(OB.inkSoft)
                  .padding(.horizontal, 14),
                alignment: .leading
              )
          }
        }
      }
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .stroke(OB.line, lineWidth: 1)
      )

      // Beta notice
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "info.circle.fill")
          .foregroundStyle(OB.purple)
          .frame(width: 22, height: 22)

        Text("Payment processing coming soon. Quill will use BYOK mode during the beta \u{2014} you'll need to add an API key in Settings after onboarding.")
          .font(.system(size: 12.5))
          .foregroundStyle(OB.inkSoft)
          .lineSpacing(3)
      }
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(OB.purpleLight)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .stroke(OB.purpleMid.opacity(0.2), lineWidth: 1)
      )

      Spacer()

      HStack {
        OnboardingButton("\u{2190} Back", variant: .ghost, action: onBack)
        Spacer()
        OnboardingButton("Continue \u{2192}", action: onContinue)
      }
    }
    .padding(.horizontal, 80)
    .padding(.top, 32)
    .padding(.bottom, 40)
  }
}

// MARK: - Step 4b-1: BYOK Provider

private struct BYOKProviderStep: View {
  @Binding var selectedProvider: AIProvider
  let onContinue: () -> Void
  let onBack: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        StepDots(step: .byokProvider)
        Text("WALKTHROUGH \u{00B7} STEP 1 OF 3")
          .font(.system(size: 11, weight: .bold))
          .tracking(0.66)
          .foregroundStyle(OB.inkMute)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Pick a provider")
          .font(.system(size: 28, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
          .tracking(-0.42)

        (Text("You'll create an API key from one of these providers. ")
          .font(.system(size: 13.5))
          .foregroundStyle(OB.inkSoft)
        + Text("If you've never done this \u{2014} pick Anthropic. We'll walk you through it.")
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(OB.inkSoft)
        )
        .frame(maxWidth: 540, alignment: .leading)
      }

      VStack(spacing: 8) {
        providerCard(
          provider: .anthropic,
          name: "Anthropic",
          model: "Claude Sonnet 4.5",
          note: "Best for writing & long context",
          color: Color(red: 0.80, green: 0.47, blue: 0.36),
          recommended: true
        )

        providerCard(
          provider: .openAI,
          name: "OpenAI",
          model: "GPT-4o & GPT-4 Turbo",
          note: "Great all-rounder, fast",
          color: Color(red: 0.063, green: 0.639, blue: 0.498),
          recommended: false
        )
      }

      Spacer()

      HStack {
        OnboardingButton("\u{2190} Back", variant: .ghost, action: onBack)
        Spacer()
        OnboardingButton(
          "Continue with \(selectedProvider.displayName) \u{2192}",
          action: onContinue
        )
      }
    }
    .padding(.horizontal, 60)
    .padding(.top, 32)
    .padding(.bottom, 40)
  }

  private func providerCard(
    provider: AIProvider,
    name: String,
    model: String,
    note: String,
    color: Color,
    recommended: Bool
  ) -> some View {
    let isSelected = selectedProvider == provider
    return Button { selectedProvider = provider } label: {
      HStack(spacing: 14) {
        // Provider icon
        Text(String(name.prefix(1)))
          .font(.system(size: 18, weight: .semibold, design: .serif))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(color)
          )

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(name)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(OB.ink)
            if recommended {
              Pip("Recommended")
            }
          }
          Text("\(model) \u{00B7} \(note)")
            .font(.system(size: 12))
            .foregroundStyle(OB.inkMute)
        }

        Spacer()

        // Radio button
        Circle()
          .strokeBorder(isSelected ? OB.purple : OB.line, lineWidth: isSelected ? 5 : 1.5)
          .frame(width: 18, height: 18)
          .background(Circle().fill(Color.white))
      }
      .padding(14)
      .padding(.horizontal, 2)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .stroke(
            isSelected ? OB.purple : OB.line,
            lineWidth: isSelected ? 1.5 : 1
          )
      )
      .shadow(
        color: isSelected ? OB.purple.opacity(0.08) : .clear,
        radius: isSelected ? 8 : 0
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Step 4b-2: BYOK Get Key

private struct BYOKGetKeyStep: View {
  let provider: AIProvider
  let onContinue: () -> Void
  let onBack: () -> Void

  private var consoleURL: URL {
    provider == .anthropic
      ? URL(string: "https://console.anthropic.com/settings/keys")!
      : URL(string: "https://platform.openai.com/api-keys")!
  }

  private var consoleDomain: String {
    provider == .anthropic
      ? "console.anthropic.com"
      : "platform.openai.com"
  }

  private var keyPrefix: String {
    provider == .anthropic ? "sk-ant-api03-\u{2026}" : "sk-proj-\u{2026}"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        StepDots(step: .byokGetKey)
        Text("WALKTHROUGH \u{00B7} STEP 2 OF 3")
          .font(.system(size: 11, weight: .bold))
          .tracking(0.66)
          .foregroundStyle(OB.inkMute)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Create your key on \(provider.displayName)")
          .font(.system(size: 26, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
          .tracking(-0.39)

        Text("We'll open the right page for you. Follow the three highlighted steps, then come back here.")
          .font(.system(size: 13))
          .foregroundStyle(OB.inkSoft)
      }

      // Two-column layout: steps + browser mock
      HStack(alignment: .top, spacing: 14) {
        // Left: instruction cards
        VStack(alignment: .leading, spacing: 8) {
          instructionCard(number: 1, title: "Sign in", subtitle: "or create a free account")
          instructionCard(number: 2, title: "Click \"Create Key\"", subtitle: "in the top-right")
          instructionCard(number: 3, title: "Copy the key", subtitle: "starts with \(keyPrefix)")

          OnboardingButton("Open \(consoleDomain)", variant: .dark) {
            NSWorkspace.shared.open(consoleURL)
          }
          .padding(.top, 6)
        }
        .frame(width: 200)

        // Right: mini browser mock
        VStack(spacing: 0) {
          // Browser chrome
          HStack(spacing: 4) {
            Circle().fill(Color(red: 1.0, green: 0.373, blue: 0.341)).frame(width: 8, height: 8)
            Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.18)).frame(width: 8, height: 8)
            Circle().fill(Color(red: 0.157, green: 0.784, blue: 0.251)).frame(width: 8, height: 8)

            Spacer().frame(width: 6)

            Text(consoleDomain + "/settings/keys")
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(OB.inkMute)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
                  .fill(Color.white)
              )
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(Color(red: 0.945, green: 0.929, blue: 0.898))

          Divider().foregroundStyle(OB.line)

          // Page content mock
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("API Keys")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(OB.ink)
              Spacer()
              Text("+ Create Key")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                  RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                    .fill(OB.ink)
                )
            }

            VStack(spacing: 6) {
              mockKeyRow(name: "my-quill-key", key: "sk-ant-api03-\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
              mockKeyRow(name: "laptop", key: "sk-ant-api03-\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
            }
            .padding(.top, 4)
          }
          .padding(16)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
      }

      Spacer(minLength: 0)

      HStack {
        OnboardingButton("\u{2190} Back", variant: .ghost, action: onBack)
        Spacer()
        OnboardingButton("I have my key \u{2192}", action: onContinue)
      }
    }
    .padding(.horizontal, 56)
    .padding(.top, 28)
    .padding(.bottom, 24)
  }

  private func instructionCard(number: Int, title: String, subtitle: String) -> some View {
    HStack(spacing: 10) {
      Text("\(number)")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(Circle().fill(OB.purple))

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(OB.ink)
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(OB.inkMute)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(Color.white)
    )
    .overlay(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .stroke(OB.line, lineWidth: 1)
    )
  }

  private func mockKeyRow(name: String, key: String) -> some View {
    HStack {
      Text(name)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(OB.ink)
      Spacer()
      Text(key)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(OB.inkMute)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(Color(red: 0.98, green: 0.98, blue: 0.965))
    )
    .overlay(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .stroke(OB.line, lineWidth: 1)
    )
  }
}

// MARK: - Step 4b-3: BYOK Verify

private struct BYOKVerifyStep: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let provider: AIProvider
  let onContinue: () -> Void
  let onBack: () -> Void

  @State private var apiKey: String = ""
  @State private var isVerified = false
  @State private var showTrouble = false

  private var keyPrefix: String {
    provider == .anthropic ? "sk-ant-api03-\u{2026}" : "sk-proj-\u{2026}"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        StepDots(step: .byokVerify)
        Text("WALKTHROUGH \u{00B7} STEP 3 OF 3")
          .font(.system(size: 11, weight: .bold))
          .tracking(0.66)
          .foregroundStyle(OB.inkMute)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Paste your key")
          .font(.system(size: 28, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
          .tracking(-0.42)

        (Text("Quill will test it once with a tiny request, then save it to your Mac's ")
          .font(.system(size: 13.5))
          .foregroundStyle(OB.inkSoft)
        + Text("Keychain")
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(OB.inkSoft)
        + Text(". It never touches our servers.")
          .font(.system(size: 13.5))
          .foregroundStyle(OB.inkSoft)
        )
        .frame(maxWidth: 540, alignment: .leading)
      }

      // Key input card
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Pip(provider.displayName)
          Spacer()
          Text("Format: ")
            .font(.system(size: 11))
            .foregroundStyle(OB.inkMute)
          + Text(keyPrefix)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(OB.inkSoft)
        }

        if isVerified {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(OB.proGreen)
            Text("Key saved and verified")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(OB.proGreen)
            Spacer()
          }
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(Color(red: 0.941, green: 0.980, blue: 0.953))
          )
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .stroke(OB.proGreen.opacity(0.4), lineWidth: 1.5)
          )
        } else {
          SecureField("Paste your API key", text: $apiKey)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(OB.ink)
            .padding(12)
            .background(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                .fill(Color.white)
            )
            .overlay(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                .stroke(OB.purple, lineWidth: 1.5)
            )
        }

        if isVerified {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            verifiedRow("Stored in Keychain")
            verifiedRow("$0.34 / mo estimated usage")
            verifiedRow("Tested with a 12-token ping")
            verifiedRow("Default model: \(provider == .anthropic ? "Claude Sonnet 4.5" : "GPT-4o")")
          }
          .padding(.top, 2)
        }

        if !isVerified && !apiKey.isEmpty {
          OnboardingButton("Verify & save", fullWidth: true) {
            saveKey()
          }
        }
      }
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .stroke(OB.line, lineWidth: 1)
      )

      // Troubleshooting disclosure
      DisclosureGroup(isExpanded: $showTrouble) {
        Text("Most often it's billing. Anthropic requires at least $5 of credit before keys are active. Check your billing settings on the provider's dashboard.")
          .font(.system(size: 12))
          .foregroundStyle(OB.inkSoft)
          .lineSpacing(3)
          .padding(.top, 8)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "lock.fill")
            .font(.system(size: 10))
          Text("What if my key doesn't work?")
            .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(OB.inkSoft)
      }
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(OB.paperElev)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .stroke(OB.line, lineWidth: 1)
      )

      Spacer()

      HStack {
        OnboardingButton("\u{2190} Back", variant: .ghost, action: onBack)
        Spacer()
        OnboardingButton(
          "You're set \u{2192}",
          isDisabled: !isVerified,
          action: onContinue
        )
      }
    }
    .padding(.horizontal, 60)
    .padding(.top, 32)
    .padding(.bottom, 40)
  }

  private func saveKey() {
    store.send(.saveAPIKey(apiKey, forProvider: provider))
    store.send(.setAIProvider(provider))
    QuillMotion.run(.spring(duration: 0.4)) {
      isVerified = true
    }
  }

  private func verifiedRow(_ text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 10))
        .foregroundStyle(OB.proGreen)
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(OB.inkSoft)
    }
  }
}

// MARK: - Step 5: Google sign-in

private struct GoogleSignInStep: View {
  let onContinue: () -> Void
  let onSkip: () -> Void

  @Dependency(\.googleOAuth) private var googleOAuth

  @State private var isAuthenticating = false
  @State private var connectedEmail: String?
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      StepDots(step: .googleSignIn)

      VStack(alignment: .leading, spacing: 6) {
        Text("Connect Google")
          .font(.system(size: 30, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
          .tracking(-0.45)
          .padding(.top, 8)

        Text("Lets you say \"email Mike about the deck\" or \"add a meeting to my Google Calendar\" \u{2014} Quill drafts the email or creates the event for you.")
          .font(.system(size: 13.5))
          .foregroundStyle(OB.inkSoft)
          .frame(maxWidth: 520, alignment: .leading)
      }

      Spacer().frame(height: 8)

      if let connectedEmail {
        // Connected state card
        VStack(spacing: 10) {
          HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(OB.proGreen)
              .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
              Text("Connected as \(connectedEmail)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OB.ink)
              Text("Gmail drafts and Google Calendar events are now available in Action mode.")
                .font(.system(size: 12))
                .foregroundStyle(OB.inkMute)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .stroke(OB.proGreen.opacity(0.3), lineWidth: 1)
        )
        .transition(.opacity)
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.system(size: 12))
          .foregroundStyle(.orange)
          .padding(.horizontal, 4)
      }

      Spacer()

      HStack {
        if connectedEmail != nil {
          Spacer()
          OnboardingButton("Continue \u{2192}", action: onContinue)
        } else {
          OnboardingButton("I'll add it later", variant: .ghost, action: onSkip)
          Spacer()
          OnboardingButton(
            isAuthenticating ? "Opening browser\u{2026}" : "Sign in with Google",
            isDisabled: isAuthenticating,
            action: signIn
          )
        }
      }
    }
    .padding(.horizontal, 80)
    .padding(.top, 48)
    .padding(.bottom, 40)
    .task {
      if let cached = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey) {
        connectedEmail = cached
      } else if await googleOAuth.isAuthorized() {
        connectedEmail = await googleOAuth.fetchUserEmail()
      }
    }
  }

  private func signIn() {
    isAuthenticating = true
    errorMessage = nil

    Task {
      do {
        _ = try await googleOAuth.authorize(scopes: GoogleOAuthClient.defaultScopes)
        let email = await googleOAuth.fetchUserEmail()
        QuillMotion.run { connectedEmail = email ?? "your Google account" }
      } catch {
        errorMessage = error.localizedDescription
      }
      isAuthenticating = false
    }
  }
}

// MARK: - Step 6: First dictation

private struct FirstDictationStep: View {
  let onContinue: () -> Void
  let onSkip: () -> Void

  // Animated waveform
  @State private var wavePhase = false

  var body: some View {
    VStack(spacing: 18) {
      StepDots(step: .firstDictation)

      VStack(spacing: 6) {
        (Text("How ")
          .font(.system(size: 30, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        + Text("dictation")
          .font(.system(size: 30, weight: .regular, design: .serif).italic())
          .foregroundStyle(OB.purpleDark)
        + Text(" works")
          .font(.system(size: 30, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        )
        .tracking(-0.45)
        .padding(.top, 4)

        Text("Hold your recording hotkey, speak naturally, then release. Quill transcribes and pastes the text into whatever app you're using.")
          .font(.system(size: 13.5))
          .foregroundStyle(OB.inkSoft)
          .frame(maxWidth: 460)
          .multilineTextAlignment(.center)
      }

      Text("You can configure your hotkey in Settings after setup.")
        .font(.system(size: 12))
        .foregroundStyle(OB.inkMute)
        .padding(.top, 6)

      // HUD mock card
      VStack(spacing: 0) {
        // Header
        HStack(spacing: 10) {
          Circle()
            .fill(Color(red: 1.0, green: 0.263, blue: 0.227))
            .frame(width: 8, height: 8)
            .shadow(color: Color(red: 1.0, green: 0.263, blue: 0.227), radius: 5)
          Text("00:03")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
          Spacer()
          Text("Listening")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                .fill(.white.opacity(0.06))
            )
        }
        .padding(.bottom, 12)

        // Transcript
        HStack(spacing: 0) {
          Text("\u{201C}This is Quill \u{2014} hi mom\u{201D}")
            .font(.system(size: 18, weight: .regular, design: .serif).italic())
            .foregroundStyle(.white)
          Rectangle()
            .fill(OB.purpleMid)
            .frame(width: 2, height: 18)
            .padding(.leading, 4)
          Spacer()
        }
        .padding(.vertical, 6)

        Spacer().frame(height: 14)

        // Waveform bars
        HStack(spacing: 3) {
          ForEach(0 ..< 16, id: \.self) { i in
            let baseHeight: CGFloat = [8, 16, 6, 20, 10, 18, 8, 14, 10, 22, 12, 8, 18, 10, 6, 16][i]
            RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
              .fill(OB.purpleMid)
              .frame(width: 3, height: wavePhase ? baseHeight : baseHeight * 0.6)
              .animation(
                .easeInOut(duration: 0.5)
                  .repeatForever(autoreverses: true)
                  .delay(Double(i) * 0.05),
                value: wavePhase
              )
          }
        }
        .frame(height: 22)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 20)
      .frame(width: 420)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
          .fill(
            LinearGradient(
              colors: [OB.ink, Color(red: 0.086, green: 0.086, blue: 0.094)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
      )
      .shadow(color: OB.purple.opacity(0.30), radius: 22, y: 9)
      .shadow(color: .white.opacity(0.08), radius: 0.25, y: -0.5)
      .padding(.top, 8)
      .onAppear {
        wavePhase = true
      }

      Spacer()

      HStack {
        OnboardingButton("Skip for now", variant: .ghost, action: onSkip)
        Spacer()
        OnboardingButton("Looks good \u{2014} finish setup \u{2192}", action: onContinue)
      }
      .padding(.horizontal, 60)
    }
    .padding(.horizontal, 60)
    .padding(.top, 32)
    .padding(.bottom, 40)
  }
}

// MARK: - Step 7: Done

private struct DoneStep: View {
  let onFinish: () -> Void
  @State private var burst = false

  var body: some View {
    ZStack {
      // Custom background for done screen
      LinearGradient(
        colors: [OB.purpleLight, OB.paper],
        startPoint: .top,
        endPoint: .bottom
      )

      VStack(spacing: 18) {
        Spacer()

        // Feather with decorative ring
        ZStack {
          Circle()
            .strokeBorder(OB.purpleMid.opacity(0.4), lineWidth: 2)
            .frame(width: 104, height: 104)
            .scaleEffect(burst ? 1 : 0.5)
            .opacity(burst ? 1 : 0)
            .animation(.spring(duration: 0.8, bounce: 0.3), value: burst)

          Image(nsImage: OnboardingFeather.image(side: 72))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 72, height: 72)
            .scaleEffect(burst ? 1 : 0.6)
            .animation(.spring(duration: 0.7, bounce: 0.45), value: burst)
        }

        // Title
        (Text("You're ")
          .font(.system(size: 44, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        + Text("ready")
          .font(.system(size: 44, weight: .regular, design: .serif).italic())
          .foregroundStyle(OB.purpleDark)
        + Text(".")
          .font(.system(size: 44, weight: .regular, design: .serif))
          .foregroundStyle(OB.ink)
        )
        .tracking(-0.88)

        Text("Quill lives in your menu bar. Set a recording hotkey in Settings, then hold it anywhere on your Mac to start dictating.")
          .font(.system(size: 15))
          .foregroundStyle(OB.inkSoft)
          .frame(maxWidth: 420)
          .multilineTextAlignment(.center)

        // Quick-start cards
        HStack(spacing: 8) {
          quickStartCard(
            title: "Try dictation",
            shortcut: "Hold your hotkey"
          )
          quickStartCard(
            title: "Try Edit",
            shortcut: "Select text + hotkey"
          )
          quickStartCard(
            title: "Try Act",
            shortcut: "Say \"remind me\u{2026}\""
          )
        }
        .frame(maxWidth: 480)
        .padding(.top, 10)

        OnboardingButton("Open Quill", action: onFinish)
          .padding(.top, 10)

        Spacer()
      }
      .padding(.horizontal, 60)
    }
    .onAppear { QuillMotion.run { burst = true } }
  }

  private func quickStartCard(title: String, shortcut: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(OB.ink)
      Text(shortcut)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(OB.inkMute)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(Color.white)
    )
    .overlay(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .stroke(OB.line, lineWidth: 1)
    )
  }
}
