import ComposableArchitecture
import Inject
import Sparkle
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	/// Menu-bar-sized template NSImage built from the `Feather` asset.
	/// The source PNG is white-on-transparent at ~1024×1024; we redraw
	/// it into an 18pt canvas (standard macOS menu-bar glyph size) and
	/// mark it `isTemplate = true` so AppKit colours it with the
	/// current menu-bar foreground. Computed once at app launch.
	static let menuBarIcon: NSImage = {
		let side: CGFloat = 18
		guard let source = NSImage(named: "Feather") else {
			// Fall back to a visible SF Symbol so the status item is
			// never totally blank — signals "asset didn't load".
			return NSImage(
				systemSymbolName: "questionmark.square",
				accessibilityDescription: "Quill"
			) ?? NSImage()
		}
		let scaled = NSImage(size: NSSize(width: side, height: side))
		let rect = NSRect(x: 0, y: 0, width: side, height: side)
		scaled.lockFocus()
		// 1. Draw the feather (white-on-transparent) — this fills the
		//    alpha channel with the feather shape.
		source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
		// 2. Replace the RGB with pure black wherever alpha > 0. The
		//    canonical macOS template-image format is black + alpha;
		//    some AppKit rendering passes misrender white + alpha in
		//    menu-bar contexts.
		NSColor.black.setFill()
		rect.fill(using: .sourceIn)
		scaled.unlockFocus()
		scaled.isTemplate = true
		return scaled
	}()

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
  
    var body: some Scene {
		// The menu-bar presence (status item, app menu, and the Chip+Morph
		// live label) is AppKit-managed by QuillStatusItemController —
		// installed from HexAppDelegate. It replaced the SwiftUI
		// MenuBarExtra so the label can be a real animated view (the
		// feather↔orb morph) and so the Corner Bloom panel can anchor to
		// the status item's screen frame.
		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()

					Button("Settings...") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}

				CommandGroup(replacing: .help) {}
			}
	}
}
