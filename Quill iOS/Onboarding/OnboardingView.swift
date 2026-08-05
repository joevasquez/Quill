//
//  OnboardingView.swift
//  Quill (iOS)
//
//  Seven-step onboarding flow with a branching plan choice.
//  Light paper/cream theme with purple accents.
//
//  Steps:
//    1. Welcome       — feather + tagline
//    2. Permissions    — mic (required) + speech recognition (optional)
//    3. Plan choice    — Pro trial vs BYOK
//    4a. Pro trial     — subscription info (branch A)
//    4b. BYOK phone   — provider picker + API key entry (branch B)
//    5. Google sign-in — optional Google OAuth
//    6. First dictation — visual HUD mock
//    7. Done           — celebration + try-it cards
//

import AVFoundation
import Combine
import HexCore
import Speech
import SwiftUI

// MARK: - Color Palette

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

// MARK: - Step & Plan Enums

private enum OnboardingStep: Int {
  case welcome = 0
  case permissions = 1
  case planChoice = 2
  case proTrial = 3   // branch A
  case byokPhone = 4  // branch B (single consolidated screen)
  case googleSignIn = 5
  case firstDictation = 6
  case done = 7

  /// Map to dot position (0-6) for the 7-position indicator.
  var dotIndex: Int {
    switch self {
    case .welcome: return 0
    case .permissions: return 1
    case .planChoice: return 2
    case .proTrial, .byokPhone: return 3
    case .googleSignIn: return 4
    case .firstDictation: return 5
    case .done: return 6
    }
  }
}

private enum PlanChoice {
  case pro, byok
}

// MARK: - Root View

struct OnboardingView: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var hasCompletedOnboarding: Bool

  @State private var step: OnboardingStep = .welcome
  @State private var selectedPlan: PlanChoice?
  @State private var selectedProvider: AIProvider = .anthropic
  @AppStorage(QuillIOSSettingsKey.selectedPlan) private var persistedPlan: String?

  var body: some View {
    ZStack {
      OnboardingBackground()

      Group {
        switch step {
        case .welcome:
          WelcomeStep(onContinue: { advance(to: .permissions) })
        case .permissions:
          PermissionsStep(onContinue: { advance(to: .planChoice) })
        case .planChoice:
          PlanChoiceStep(
            onProTrial: {
              selectedPlan = .pro
              persistedPlan = "pro"
              advance(to: .proTrial)
            },
            onBYOK: {
              selectedPlan = .byok
              persistedPlan = "byok"
              advance(to: .byokPhone)
            }
          )
        case .proTrial:
          ProTrialStep(
            onContinue: { advance(to: .googleSignIn) },
            onSwitchBYOK: {
              selectedPlan = .byok
              persistedPlan = "byok"
              advance(to: .byokPhone)
            }
          )
        case .byokPhone:
          BYOKPhoneStep(
            selectedProvider: $selectedProvider,
            onContinue: { advance(to: .googleSignIn) }
          )
        case .googleSignIn:
          GoogleSignInStep(
            onContinue: { advance(to: .firstDictation) },
            onSkip: { advance(to: .firstDictation) }
          )
        case .firstDictation:
          FirstDictationStep(onContinue: { advance(to: .done) })
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

      // Skip button + Step dots overlay
      VStack {
        HStack {
          Spacer()
          Button("Skip", action: complete)
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(OB.inkSoft)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(OB.ink.opacity(0.06)))
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        Spacer()
        StepDots(currentStep: step.dotIndex, total: 7)
          .padding(.bottom, 28)
      }
    }
    .interactiveDismissDisabled()
  }

  private func advance(to next: OnboardingStep) {
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    QuillMotion.run {
      step = next
    }
  }

  private func complete() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    hasCompletedOnboarding = true
    dismiss()
  }
}

// MARK: - Background

private struct OnboardingBackground: View {
  var body: some View {
    ZStack {
      OB.paper.ignoresSafeArea()
      RadialGradient(
        colors: [OB.purpleLight, OB.paper],
        center: .init(x: 0.5, y: 0.25),
        startRadius: 0,
        endRadius: 400
      )
      .ignoresSafeArea()
    }
  }
}

// MARK: - Step Dots

private struct StepDots: View {
  let currentStep: Int
  let total: Int

  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<total, id: \.self) { idx in
        Capsule()
          .fill(idx == currentStep ? OB.purple : Color.black.opacity(0.15))
          .frame(width: idx == currentStep ? 22 : 6, height: 6)
          .animation(.spring(duration: 0.4, bounce: 0.3), value: currentStep)
      }
    }
  }
}

// MARK: - Onboarding Button

private enum ButtonVariant {
  case primary, secondary, ghost, dark
}

private struct OnboardingButton: View {
  let label: String
  var variant: ButtonVariant = .primary
  var isDisabled: Bool = false
  var fullWidth: Bool = true
  let action: () -> Void

  init(
    _ label: String,
    variant: ButtonVariant = .primary,
    isDisabled: Bool = false,
    fullWidth: Bool = true,
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
        .font(.body.weight(.semibold))
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .padding(.vertical, 14)
        .padding(.horizontal, fullWidth ? 0 : 24)
        .foregroundStyle(foregroundColor)
        .background(backgroundShape)
        .overlay(borderOverlay)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.5 : 1)
  }

  private var foregroundColor: Color {
    switch variant {
    case .primary, .dark: return .white
    case .secondary: return OB.ink
    case .ghost: return OB.inkSoft
    }
  }

  @ViewBuilder
  private var backgroundShape: some View {
    switch variant {
    case .primary:
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(LinearGradient(
          colors: [OB.purple, OB.purpleDark],
          startPoint: .top,
          endPoint: .bottom
        ))
        .shadow(color: OB.purple.opacity(0.30), radius: 9, y: 6)
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
  private var borderOverlay: some View {
    switch variant {
    case .secondary:
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .stroke(OB.line, lineWidth: 1)
    default:
      EmptyView()
    }
  }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
  /// Display type in a `Text` concatenation — see QuillFont.
  @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 38
  let onContinue: () -> Void
  @State private var featherOpacity: Double = 0
  @State private var contentOpacity: Double = 0

  var body: some View {
    VStack(spacing: 16) {
      Spacer()

      Image("Feather")
        .resizable()
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(OB.purpleDark)
        .frame(width: 56, height: 56)
        .opacity(featherOpacity)

      VStack(spacing: 8) {
        (Text("Welcome to\n")
          .font(.system(size: displaySize, weight: .medium, design: .serif))
          .foregroundStyle(OB.ink)
        + Text("Quill")
          .font(.system(size: displaySize, weight: .regular, design: .serif).italic())
          .foregroundStyle(OB.purpleDark)
        + Text(".")
          .font(.system(size: displaySize, weight: .medium, design: .serif))
          .foregroundStyle(OB.ink))
          .multilineTextAlignment(.center)
          .lineSpacing(2)

        Text("Voice-first AI in your pocket.\nSpeak. Edit. Act.")
          .font(.subheadline)
          .foregroundStyle(OB.inkSoft)
          .multilineTextAlignment(.center)
          .lineSpacing(2)
      }
      .opacity(contentOpacity)

      Spacer()

      VStack(spacing: 8) {
        OnboardingButton("Get started", action: onContinue)
        OnboardingButton("I already have an account", variant: .ghost, action: onContinue)
      }
      .opacity(contentOpacity)
      .padding(.horizontal, 24)

      Text("~90 seconds")
        .font(.caption2)
        .foregroundStyle(OB.inkMute)
        .padding(.bottom, 60)
        .opacity(contentOpacity)
    }
    .padding(.horizontal, 22)
    .onAppear {
      QuillMotion.run(.easeOut(duration: 0.8)) {
        featherOpacity = 1
      }
      QuillMotion.run(.easeIn(duration: 0.5).delay(0.4)) {
        contentOpacity = 1
      }
    }
  }
}

// MARK: - Permissions Model

@MainActor
private final class OnboardingPermissions: ObservableObject {
  enum PermState { case pending, requesting, granted, denied }
  @Published var micState: PermState = .pending
  @Published var speechState: PermState = .pending

  var canContinue: Bool { micState == .granted }

  init() {
    micState = AVAudioApplication.shared.recordPermission == .granted ? .granted : .pending
    speechState = SFSpeechRecognizer.authorizationStatus() == .authorized ? .granted : .pending
  }

  func requestMic() {
    guard micState != .granted, micState != .requesting else { return }
    micState = .requesting
    AVAudioApplication.requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        self?.micState = granted ? .granted : .denied
      }
    }
  }

  func requestSpeech() {
    guard speechState != .granted, speechState != .requesting else { return }
    speechState = .requesting
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        self?.speechState = status == .authorized ? .granted : .denied
      }
    }
  }
}

// MARK: - Permission Row

private struct PermissionRow: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let state: OnboardingPermissions.PermState
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 12) {
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .fill(OB.purpleLight)
          .frame(width: 32, height: 32)
          .overlay(
            Image(systemName: systemImage)
              .quillFont(14, weight: .semibold)
              .foregroundStyle(OB.purpleDark)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OB.ink)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(OB.inkMute)
        }

        Spacer()
        statusGlyph
      }
      .padding(12)
      .padding(.horizontal, 2)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .stroke(OB.line, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(state == .granted || state == .requesting)
  }

  @ViewBuilder
  private var statusGlyph: some View {
    switch state {
    case .pending:
      Text("Grant")
        .font(.caption.weight(.semibold))
        .foregroundStyle(OB.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .fill(Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )
    case .requesting:
      ProgressView()
        .controlSize(.small)
        .tint(OB.purple)
    case .granted:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(OB.proGreen)
        .font(.title3)
        .symbolEffect(.bounce, value: state)
    case .denied:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
        .font(.title3)
    }
  }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
  let onContinue: () -> Void
  @StateObject private var permissions = OnboardingPermissions()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Grant access")
          .quillFont(26, weight: .medium, design: .serif)
          .foregroundStyle(OB.ink)
        Text("Quill never records without you holding the button.")
          .font(.subheadline)
          .foregroundStyle(OB.inkSoft)
      }
      .padding(.top, 72)

      VStack(spacing: 8) {
        PermissionRow(
          title: "Microphone",
          subtitle: "Hear what you say.",
          systemImage: "mic.fill",
          state: permissions.micState,
          action: { permissions.requestMic() }
        )
        PermissionRow(
          title: "Speech Recognition",
          subtitle: "On-device transcription.",
          systemImage: "waveform",
          state: permissions.speechState,
          action: { permissions.requestSpeech() }
        )
      }
      .padding(.top, 18)

      Spacer()

      OnboardingButton(
        "Continue",
        isDisabled: !permissions.canContinue,
        action: onContinue
      )
      .padding(.bottom, 60)
    }
    .padding(.horizontal, 22)
  }
}

// MARK: - Step 3: Plan Choice

private struct PlanChoiceStep: View {
  /// Display type in a `Text` concatenation — see QuillFont.
  @ScaledMetric(relativeTo: .title2) private var displaySize: CGFloat = 24
  let onProTrial: () -> Void
  let onBYOK: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          (Text("How will you ")
            .font(.system(size: displaySize, weight: .medium, design: .serif))
            .foregroundStyle(OB.ink)
          + Text("pay for AI?")
            .font(.system(size: displaySize, weight: .medium, design: .serif).italic())
            .foregroundStyle(OB.purpleDark))
          Text("Two ways. You can switch later.")
            .font(.subheadline)
            .foregroundStyle(OB.inkSoft)
        }
        .padding(.top, 72)

        // Pro card
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            PipView("Recommended", tone: .dark)
            Spacer()
            Text("10-day free trial")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(OB.purpleDark)
          }

          Text("Quill Pro")
            .quillFont(19, weight: .medium, design: .serif)
            .foregroundStyle(OB.ink)

          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("$10")
              .quillFont(28, weight: .medium, design: .serif)
              .foregroundStyle(OB.purpleDark)
            Text("/ month")
              .font(.caption)
              .foregroundStyle(OB.inkMute)
          }

          VStack(alignment: .leading, spacing: 3) {
            ProConRow(text: "Zero setup, works immediately", isPro: true)
            ProConRow(text: "Cross-device sync & 3rd-party actions", isPro: true)
            ProConRow(text: "Monthly subscription", isPro: false)
          }
          .padding(.top, 2)
        }
        .padding(16)
        .background(
          LinearGradient(
            colors: [.white, OB.purpleLight],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(OB.purpleMid, lineWidth: 1.5)
        )
        .shadow(color: OB.purple.opacity(0.15), radius: 12, y: 8)
        .padding(.top, 16)

        // BYOK card
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            PipView("One-time", tone: .grey)
            Spacer()
            Text("Power users")
              .font(.caption2)
              .foregroundStyle(OB.inkMute)
          }

          Text("Bring Your Own Keys")
            .quillFont(19, weight: .medium, design: .serif)
            .foregroundStyle(OB.ink)

          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("$50")
              .quillFont(28, weight: .medium, design: .serif)
              .foregroundStyle(OB.ink)
            Text("once \u{00B7} forever")
              .font(.caption)
              .foregroundStyle(OB.inkMute)
          }

          VStack(alignment: .leading, spacing: 3) {
            ProConRow(text: "Pay providers directly (pennies/mo)", isPro: true)
            ProConRow(text: "Choose Claude or GPT-4o", isPro: true)
            ProConRow(text: "2 min of setup, no cross-device sync", isPro: false)
            ProConRow(text: "Apple-only actions (no Gmail, Linear...)", isPro: false)
          }
          .padding(.top, 2)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )
        .padding(.top, 10)

        VStack(spacing: 8) {
          OnboardingButton("Start free trial", action: onProTrial)
          OnboardingButton("Use my own keys", variant: .ghost, action: onBYOK)
        }
        .padding(.top, 16)
        .padding(.bottom, 60)
      }
      .padding(.horizontal, 22)
    }
    .scrollIndicators(.hidden)
  }
}

private struct ProConRow: View {
  let text: String
  let isPro: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(isPro ? "+" : "\u{2212}")
        .font(.caption.weight(.bold))
        .foregroundStyle(isPro ? OB.proGreen : OB.conRed)
        .frame(width: 12, alignment: .center)
      Text(text)
        .font(.caption)
        .foregroundStyle(OB.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private enum PipTone {
  case purple, green, grey, dark
}

private struct PipView: View {
  let text: String
  let tone: PipTone

  init(_ text: String, tone: PipTone = .purple) {
    self.text = text
    self.tone = tone
  }

  private var bg: Color {
    switch tone {
    case .purple: return OB.purpleLight
    case .green: return Color(red: 0.906, green: 0.969, blue: 0.922)
    case .grey: return OB.paperElev
    case .dark: return OB.ink
    }
  }

  private var fg: Color {
    switch tone {
    case .purple: return OB.purpleDark
    case .green: return OB.proGreen
    case .grey: return OB.inkSoft
    case .dark: return .white
    }
  }

  var body: some View {
    Text(text)
      .quillFont(10, weight: .bold)
      .tracking(0.6)
      .textCase(.uppercase)
      .foregroundStyle(fg)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .background(Capsule().fill(bg))
  }
}

// MARK: - Step 4a: Pro Trial

private struct ProTrialStep: View {
  /// Display type in a `Text` concatenation — see QuillFont.
  @ScaledMetric(relativeTo: .title2) private var displaySize: CGFloat = 24
  let onContinue: () -> Void
  let onSwitchBYOK: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          (Text("Start your ")
            .font(.system(size: displaySize, weight: .medium, design: .serif))
            .foregroundStyle(OB.ink)
          + Text("10-day trial")
            .font(.system(size: displaySize, weight: .medium, design: .serif).italic())
            .foregroundStyle(OB.purpleDark))
          Text("Cancel anytime. No charge if you stop before day 10.")
            .font(.subheadline)
            .foregroundStyle(OB.inkSoft)
        }
        .padding(.top, 72)

        // Price + timeline card
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
              Text("$10")
                .quillFont(30, weight: .medium, design: .serif)
                .foregroundStyle(OB.purpleDark)
              Text("/mo")
                .font(.subheadline)
                .foregroundStyle(OB.inkMute)
            }
            Spacer()
            PipView("10 days free", tone: .purple)
          }

          Divider()
            .overlay(OB.line)

          VStack(spacing: 8) {
            TimelineRow(date: "Today", event: "Free trial starts")
            TimelineRow(date: "Day 8", event: "Reminder email")
            TimelineRow(date: "Day 10", event: "Your card is charged $10")
          }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )
        .padding(.top, 16)

        // Apple pay info note
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "apple.logo")
            .font(.caption)
            .foregroundStyle(OB.inkSoft)
          Text("Pay via Apple \u{2014} uses your iCloud payment method.")
            .font(.caption)
            .foregroundStyle(OB.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(OB.purpleLight)
        )
        .padding(.top, 12)

        // Beta note
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "hammer.fill")
            .font(.caption)
            .foregroundStyle(OB.inkMute)
          Text("Payment coming soon. Quill will run in BYOK mode during the beta.")
            .font(.caption)
            .foregroundStyle(OB.inkMute)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(OB.paperElev)
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )
        .padding(.top, 8)

        VStack(spacing: 8) {
          OnboardingButton("Subscribe with Apple", action: onContinue)
          OnboardingButton("Use my own keys instead", variant: .ghost, action: onSwitchBYOK)
        }
        .padding(.top, 20)
        .padding(.bottom, 60)
      }
      .padding(.horizontal, 22)
    }
    .scrollIndicators(.hidden)
  }
}

private struct TimelineRow: View {
  let date: String
  let event: String

  var body: some View {
    HStack {
      Text(date)
        .font(.caption)
        .foregroundStyle(OB.inkMute)
        .frame(width: 60, alignment: .leading)
      Spacer()
      Text(event)
        .font(.caption.weight(.medium))
        .foregroundStyle(OB.ink)
    }
  }
}

// MARK: - Step 4b: BYOK Phone (Consolidated)

private struct BYOKPhoneStep: View {
  @Binding var selectedProvider: AIProvider
  let onContinue: () -> Void

  @State private var apiKey: String = ""
  @State private var savedFlash = false
  @State private var isVerifying = false
  @State private var errorMessage: String?

  private var hostURL: String {
    selectedProvider == .anthropic
      ? "console.anthropic.com"
      : "platform.openai.com"
  }

  private var keyPrefix: String {
    selectedProvider == .anthropic ? "sk-ant-api03-..." : "sk-proj-..."
  }

  private var steps: [(Int, String, String)] {
    switch selectedProvider {
    case .anthropic:
      return [
        (1, "Tap to open Anthropic", "Sign in or create an account"),
        (2, "Create an API key", "Starts with sk-ant-api03-"),
        (3, "Long-press to copy", "Then come back here"),
      ]
    case .openAI:
      return [
        (1, "Tap to open OpenAI", "Sign in or create an account"),
        (2, "Create an API key", "Starts with sk-proj-"),
        (3, "Long-press to copy", "Then come back here"),
      ]
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Header
        HStack(spacing: 10) {
          Text("BYOK")
            .quillFont(10, weight: .bold)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(OB.inkMute)
        }
        .padding(.top, 72)

        Text("Set up your key")
          .quillFont(22, weight: .medium, design: .serif)
          .foregroundStyle(OB.ink)
          .padding(.top, 8)

        Text("Pick a provider, paste your key.")
          .font(.subheadline)
          .foregroundStyle(OB.inkSoft)
          .padding(.top, 4)

        // Segmented control
        Picker("Provider", selection: Binding(
          get: { selectedProvider.rawValue },
          set: { selectedProvider = AIProvider(rawValue: $0) ?? .anthropic }
        )) {
          HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: QuillDesign.Radius.badge)
              .fill(Color(red: 0.80, green: 0.47, blue: 0.36))
              .frame(width: 14, height: 14)
              .overlay(
                Text("A")
                  .quillFont(8, weight: .bold, design: .serif)
                  .foregroundStyle(.white)
              )
            Text("Anthropic")
          }
          .tag(AIProvider.anthropic.rawValue)

          HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: QuillDesign.Radius.badge)
              .fill(Color(red: 0.063, green: 0.639, blue: 0.498))
              .frame(width: 14, height: 14)
              .overlay(
                Text("O")
                  .quillFont(8, weight: .bold, design: .serif)
                  .foregroundStyle(.white)
              )
            Text("OpenAI")
          }
          .tag(AIProvider.openAI.rawValue)
        }
        .pickerStyle(.segmented)
        .padding(.top, 12)

        // Steps card
        VStack(spacing: 10) {
          ForEach(steps, id: \.0) { step in
            HStack(alignment: .top, spacing: 10) {
              Text("\(step.0)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(OB.purple))

              VStack(alignment: .leading, spacing: 1) {
                Text(step.1)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(OB.ink)
                Text(step.2)
                  .font(.caption)
                  .foregroundStyle(OB.inkMute)
              }
            }
          }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )
        .padding(.top, 12)

        // Open host button
        OnboardingButton("Open \(hostURL)", variant: .dark) {
          if let url = URL(string: "https://\(hostURL)") {
            UIApplication.shared.open(url)
          }
        }
        .padding(.top, 10)

        // Paste key
        VStack(alignment: .leading, spacing: 6) {
          Text("Paste key here")
            .quillFont(10, weight: .semibold)
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(OB.inkMute)

          SecureField(keyPrefix, text: $apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(OB.ink)
            .padding(12)
            .background(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
                .fill(Color.white)
            )
            .overlay(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
                .stroke(OB.purple, lineWidth: 1.5)
            )
        }
        .padding(.top, 12)

        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(OB.conRed)
            .padding(.top, 6)
        }

        if savedFlash {
          Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
            .foregroundStyle(OB.proGreen)
            .font(.caption.weight(.medium))
            .padding(.top, 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        // Warning
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color(red: 0.85, green: 0.60, blue: 0.10))
          Text("BYOK keys live on this device only \u{2014} no Mac\u{2194}iPhone sync, and actions are limited to Apple apps.")
            .font(.caption)
            .foregroundStyle(OB.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(Color(red: 1.0, green: 0.96, blue: 0.90))
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .stroke(Color(red: 0.99, green: 0.89, blue: 0.75), lineWidth: 1)
        )
        .padding(.top, 10)

        OnboardingButton(
          isVerifying ? "Verifying..." : "Verify & finish",
          isDisabled: apiKey.isEmpty || isVerifying,
          action: saveAndContinue
        )
        .padding(.top, 16)
        .padding(.bottom, 60)
      }
      .padding(.horizontal, 22)
    }
    .scrollIndicators(.hidden)
  }

  private func saveAndContinue() {
    errorMessage = nil
    isVerifying = true

    let account: String
    switch selectedProvider {
    case .anthropic: account = KeychainKey.anthropicAPIKey
    case .openAI: account = KeychainKey.openAIAPIKey
    }

    let status = KeychainStore.save(account: account, value: apiKey)
    if status == errSecSuccess {
      QuillMotion.run { savedFlash = true }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        isVerifying = false
        onContinue()
      }
    } else {
      isVerifying = false
      errorMessage = "Failed to save key (status \(status)). Continuing anyway."
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        onContinue()
      }
    }
  }
}

// MARK: - Step 5: Google Sign-In

private struct GoogleSignInStep: View {
  let onContinue: () -> Void
  let onSkip: () -> Void

  @State private var isAuthenticating = false
  @State private var connectedEmail: String?
  @State private var errorMessage: String?

  @AppStorage(IntegrationConnectionStore.userDefaultsKey)
  private var connectedData: Data = Data()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Connect Google")
          .quillFont(26, weight: .medium, design: .serif)
          .foregroundStyle(OB.ink)
        Text("Optional — everything else works without it. You can do this later in Settings.")
          .font(.subheadline)
          .foregroundStyle(OB.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 72)

      Spacer().frame(height: 24)

      // What the sign-in unlocks (shared copy with the Pro screens).
      if connectedEmail == nil {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(PlanCatalog.googleBenefits) { benefit in
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: benefit.systemImage)
                .quillFont(15, weight: .semibold)
                .foregroundStyle(OB.purple)
                .frame(width: 26)
              VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(OB.ink)
                Text(benefit.detail)
                  .font(.caption)
                  .foregroundStyle(OB.inkSoft)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .fill(Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )

        Spacer().frame(height: 16)
      }

      if let connectedEmail {
        VStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .font(.title)
            .foregroundStyle(OB.proGreen)
          Text("Connected as \(connectedEmail)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OB.ink)
          Text("Gmail drafts and Google Calendar events are now available in Action mode.")
            .font(.caption)
            .foregroundStyle(OB.inkSoft)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .fill(Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(OB.line, lineWidth: 1)
        )
        .transition(.opacity)
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(OB.conRed)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.top, 12)
      }

      Spacer()

      VStack(spacing: 8) {
        if connectedEmail != nil {
          OnboardingButton("Continue", action: onContinue)
        } else {
          OnboardingButton(
            isAuthenticating ? "Opening Safari..." : "Sign in with Google",
            isDisabled: isAuthenticating,
            action: signIn
          )
          OnboardingButton("I'll add it later", variant: .ghost, action: onSkip)
        }
      }
      .padding(.bottom, 60)
    }
    .padding(.horizontal, 22)
    .task {
      if let cached = UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) {
        connectedEmail = cached
      } else if IOSGoogleOAuthClient.isAuthorized() {
        connectedEmail = await IOSGoogleOAuthClient.fetchUserEmail()
      }
    }
  }

  private func signIn() {
    isAuthenticating = true
    errorMessage = nil
    Task {
      do {
        _ = try await IOSGoogleOAuthClient.authorize()
        let email = await IOSGoogleOAuthClient.fetchUserEmail()
        var current = IntegrationConnectionStore.decode(connectedData)
        current.insert(.gmail)
        current.insert(.googleCalendar)
        connectedData = IntegrationConnectionStore.encode(current)
        QuillMotion.run { connectedEmail = email ?? "your Google account" }
      } catch {
        errorMessage = error.localizedDescription
      }
      isAuthenticating = false
    }
  }
}

// MARK: - Step 6: First Dictation

private struct FirstDictationStep: View {
  /// Display type in a `Text` concatenation — see QuillFont.
  @ScaledMetric(relativeTo: .title2) private var displaySize: CGFloat = 24
  let onContinue: () -> Void
  @State private var barHeights: [CGFloat] = (0..<20).map { _ in CGFloat.random(in: 4...18) }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        (Text("Press & hold to ")
          .font(.system(size: displaySize, weight: .medium, design: .serif))
          .foregroundStyle(OB.ink)
        + Text("speak")
          .font(.system(size: displaySize, weight: .medium, design: .serif).italic())
          .foregroundStyle(OB.purpleDark))
        Text("Hold the mic, talk, release. We'll show you the text.")
          .font(.subheadline)
          .foregroundStyle(OB.inkSoft)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 72)
      .padding(.horizontal, 22)

      Spacer().frame(height: 24)

      // Dark HUD mock
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .shadow(color: .red.opacity(0.7), radius: 5)
          Text("00:02")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
          Spacer()
          Text("Listening")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                .fill(.white.opacity(0.06))
            )
        }
        .padding(.bottom, 12)

        HStack(spacing: 0) {
          Text("\u{201C}hi mom calling to say hi\u{201D}")
            .quillFont(15, weight: .regular, design: .serif).italic()
            .foregroundStyle(.white)
          Rectangle()
            .fill(OB.purpleMid)
            .frame(width: 2, height: 14)
            .padding(.leading, 2)
        }
        .padding(.bottom, 14)

        // Waveform bars
        HStack(spacing: 2) {
          ForEach(0..<20, id: \.self) { i in
            RoundedRectangle(cornerRadius: 1.5)
              .fill(OB.purpleMid)
              .frame(width: 2.5, height: barHeights[i])
          }
        }
        .frame(height: 18, alignment: .bottom)
      }
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
          .fill(
            LinearGradient(
              colors: [OB.ink, Color(red: 0.086, green: 0.086, blue: 0.094)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .shadow(color: OB.purple.opacity(0.30), radius: 22, y: 18)
      )
      .padding(.horizontal, 22)

      Spacer()

      // Big mic button (visual only)
      ZStack {
        Circle()
          .stroke(OB.purpleMid.opacity(0.4), lineWidth: 2)
          .frame(width: 92, height: 92)

        Circle()
          .fill(
            LinearGradient(
              colors: [OB.purpleMid, OB.purpleDark],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: 76, height: 76)
          .shadow(color: OB.purple.opacity(0.40), radius: 14, y: 10)
          .overlay(
            Image(systemName: "mic.fill")
              .quillFont(30)
              .foregroundStyle(.white)
          )
      }

      Spacer()

      OnboardingButton("Continue", action: onContinue)
        .padding(.horizontal, 22)
        .padding(.bottom, 60)
    }
    .onAppear {
      // Animate waveform bars
      QuillMotion.run(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
        barHeights = (0..<20).map { _ in CGFloat.random(in: 4...18) }
      }
    }
  }
}

// MARK: - Step 7: Done

private struct DoneStep: View {
  /// Display type in a `Text` concatenation — see QuillFont.
  @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 36
  let onFinish: () -> Void
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 14) {
      Spacer()

      // Feather with decorative ring
      ZStack {
        Circle()
          .stroke(OB.purpleMid.opacity(0.4), lineWidth: 2)
          .frame(width: 92, height: 92)

        Image("Feather")
          .resizable()
          .renderingMode(.template)
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(OB.purpleDark)
          .frame(width: 64, height: 64)
      }
      .scaleEffect(appeared ? 1 : 0.7)
      .opacity(appeared ? 1 : 0)

      (Text("You're ")
        .font(.system(size: displaySize, weight: .medium, design: .serif))
        .foregroundStyle(OB.ink)
      + Text("set")
        .font(.system(size: displaySize, weight: .regular, design: .serif).italic())
        .foregroundStyle(OB.purpleDark)
      + Text(".")
        .font(.system(size: displaySize, weight: .medium, design: .serif))
        .foregroundStyle(OB.ink))
      .opacity(appeared ? 1 : 0)

      Text("Tap the big purple button anywhere in Quill to dictate.")
        .font(.subheadline)
        .foregroundStyle(OB.inkSoft)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 260)
        .opacity(appeared ? 1 : 0)

      // Try cards
      VStack(spacing: 8) {
        TryCard(
          title: "Try Dictation",
          subtitle: "Hold the mic, say anything"
        )
        TryCard(
          title: "Try Actions",
          subtitle: "\"Remind me to call mom Friday\""
        )
      }
      .padding(.top, 12)
      .opacity(appeared ? 1 : 0)

      Spacer()

      OnboardingButton("Open Quill", action: onFinish)
        .padding(.horizontal, 22)
        .padding(.bottom, 60)
        .opacity(appeared ? 1 : 0)
    }
    .padding(.horizontal, 22)
    .onAppear {
      QuillMotion.run(.spring(duration: 0.7, bounce: 0.3)) {
        appeared = true
      }
    }
  }
}

private struct TryCard: View {
  let title: String
  let subtitle: String

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(OB.ink)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(OB.inkMute)
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(OB.inkMute)
    }
    .padding(14)
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

// MARK: - Preview

#Preview {
  OnboardingView(hasCompletedOnboarding: .constant(false))
}
