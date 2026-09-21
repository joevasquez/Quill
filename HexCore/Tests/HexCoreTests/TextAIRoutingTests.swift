import Testing
@testable import HexCore

@Suite("Text AI routing")
struct TextAIRoutingTests {
  @Test("automatic prefers on-device for free users")
  func automaticFree() {
    #expect(TextAIRouteResolver.resolve(
      preference: .automatic, isPro: false, onDeviceAvailable: true
    ) == .onDevice)
  }

  @Test("automatic keeps Pro on cloud")
  func automaticPro() {
    #expect(TextAIRouteResolver.resolve(
      preference: .automatic, isPro: true, onDeviceAvailable: true
    ) == .cloud)
  }

  @Test("automatic falls back to cloud when the local model is unavailable")
  func automaticUnavailable() {
    #expect(TextAIRouteResolver.resolve(
      preference: .automatic, isPro: false, onDeviceAvailable: false
    ) == .cloud)
  }

  @Test("explicit choices are honored")
  func explicitChoices() {
    #expect(TextAIRouteResolver.resolve(
      preference: .onDevice, isPro: true, onDeviceAvailable: false
    ) == .onDevice)
    #expect(TextAIRouteResolver.resolve(
      preference: .cloud, isPro: false, onDeviceAvailable: true
    ) == .cloud)
  }
}

@Suite("Note edit output validation")
struct NoteEditOutputValidationTests {
  @Test("one bullet is rejected when the source has several ideas")
  func rejectsCollapsedBullets() {
    let source = "First we should email Melissa. Then schedule the launch. Finally update the website."
    #expect(NoteEditOutputValidator.needsBulletRetry(
      command: "Make it bullets",
      source: source,
      output: "- Email Melissa, schedule the launch, and update the website."
    ))
  }

  @Test("multiple bullets pass")
  func acceptsMultipleBullets() {
    let source = "First we should email Melissa. Then schedule the launch."
    #expect(!NoteEditOutputValidator.needsBulletRetry(
      command: "Make it bullets",
      source: source,
      output: "- Email Melissa\n- Schedule the launch"
    ))
  }

  @Test("non-list edits are not subject to bullet validation")
  func ignoresOtherEdits() {
    #expect(!NoteEditOutputValidator.needsBulletRetry(
      command: "Make it warmer",
      source: "One thought. Another thought.",
      output: "A warmer paragraph."
    ))
  }
}
