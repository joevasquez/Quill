//
//  InAppActionPresenter.swift
//  Quill (macOS)
//
//  Routes an action confirmation into the main window instead of the
//  menu-bar popdown when the Home pane is on screen.
//
//  The rule is deliberately narrow: inline only when Home is actually
//  visible. A command typed into Home's input bar always satisfies it —
//  the plan appears right under where you typed — while a dictation
//  taken while you're deep in the Notes editor still gets the popdown
//  rather than yanking you to another tab. Home reports its own
//  visibility via `onAppear`/`onDisappear`, which also covers the window
//  being closed entirely.
//

import AppKit
import ComposableArchitecture
import Foundation

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

  /// Whether the next confirmation should render inline rather than in the
  /// popdown. Requires Home on screen AND a window actually visible — a
  /// closed window can leave `isHomeVisible` stale if SwiftUI keeps the
  /// view alive, and a plan nobody can see is worse than a popdown.
  var canPresentInApp: Bool {
    isHomeVisible && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
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
