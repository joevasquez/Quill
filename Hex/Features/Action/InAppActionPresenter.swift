//
//  InAppActionPresenter.swift
//  Quill (macOS)
//
//  Routes an action confirmation into the main window instead of the
//  menu-bar popdown — but only for commands that originated in the window.
//
//  The rule is deliberately narrow: inline only for a command typed into
//  Home's input bar (or a suggestion reviewed there), and only while Home
//  is actually visible. The plan then appears right under where you typed.
//  A dictation comes from a global hotkey pressed while you're in some
//  other app, so it always drops down from the menu bar — Quill's window
//  being open behind it doesn't make the window the right place to answer.
//  Home reports its own visibility via `onAppear`/`onDisappear`, which
//  also covers the window being closed entirely.
//

import AppKit
import ComposableArchitecture
import Foundation
import HexCore

@MainActor
final class InAppActionPresenter: ObservableObject {
  static let shared = InAppActionPresenter()

  /// The live confirmation, when one is being hosted inline. Home renders
  /// this above its suggestions; nil means nothing is pending in-app.
  @Published private(set) var store: StoreOf<MultiActionConfirmationFeature>?

  /// Set by HomeView's `onAppear`/`onDisappear`.
  ///
  /// Deliberately NOT `@Published`: HomeView observes this object and writes
  /// this flag from `onAppear`, which SwiftUI runs inside its update pass —
  /// publishing there is "Publishing changes from within view updates is not
  /// allowed". Nothing renders off this value (only `store` does), so a plain
  /// stored property is both correct and quieter.
  var isHomeVisible = false

  private init() {}

  /// Whether a confirmation from `trigger` should render inline rather than
  /// in the popdown.
  ///
  /// The deciding factor is where the command came FROM, not what happens to
  /// be on screen. A command typed into Home, or a suggestion reviewed there,
  /// belongs in the window the user is looking at. A dictation is started by
  /// a global hotkey while the user is in some other app — Quill's window
  /// merely happening to be open behind it doesn't make the window the right
  /// place to answer, and pulling focus there interrupts what they were
  /// doing. Those always drop down from the menu bar.
  ///
  /// Still requires a window actually visible: a closed window can leave
  /// `isHomeVisible` stale if SwiftUI keeps the view alive, and a plan
  /// nobody can see is worse than a popdown.
  func canPresentInApp(trigger: ActionRun.Trigger) -> Bool {
    switch trigger {
    case .typed, .suggestion:
      return isHomeVisible && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    case .voice, .routine:
      return false
    }
  }

  func present(_ store: StoreOf<MultiActionConfirmationFeature>) {
    self.store = store
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
  }

  func dismiss() {
    store = nil
  }
}
