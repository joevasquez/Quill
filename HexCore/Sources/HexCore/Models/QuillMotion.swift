//
//  QuillMotion.swift
//  HexCore
//
//  Reduce Motion, for the imperative call sites.
//
//  SwiftUI's `\.accessibilityReduceMotion` environment value only reaches
//  view bodies, but most of Quill's animation is driven from button actions
//  and effect callbacks via `withAnimation` — which has no environment. This
//  reads the system setting directly so those sites can honour it too.
//
//  Quill leans on motion to carry meaning (the orb's phase, the chip's
//  feather→orb morph, a suggestion staggering in), so "reduced" here means
//  the state change lands immediately rather than that it stops happening.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum QuillMotion {
  /// Whether the user has asked for reduced motion, read from the system
  /// rather than the view environment.
  public static var isReduced: Bool {
    #if os(macOS)
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #else
    UIAccessibility.isReduceMotionEnabled
    #endif
  }

  /// `animation`, or nil when the user asked for less motion.
  public static func animation(_ animation: Animation?) -> Animation? {
    isReduced ? nil : animation
  }

  /// Drop-in for `withAnimation(_:_:)` that respects Reduce Motion.
  @MainActor
  public static func run<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
  ) rethrows -> Result {
    try withAnimation(isReduced ? nil : animation, body)
  }
}

// MARK: - Declarative

private struct MotionAwareAnimation<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let animation: Animation?
  let value: V

  func body(content: Content) -> some View {
    content.animation(reduceMotion ? nil : animation, value: value)
  }
}

public extension View {
  /// `.animation(_:value:)` that respects Reduce Motion.
  func quillAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
    modifier(MotionAwareAnimation(animation: animation, value: value))
  }
}
