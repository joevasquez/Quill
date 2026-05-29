import AppKit
import SwiftUI

/// Lightweight DTO returned by ``AppPickerButton`` so we don't leak
/// AppKit types into reducers.
struct PickedApp: Equatable {
  let bundleIdentifier: String
  let appName: String
}

/// Shared "pick an app" button used by per-app AI mode rules and
/// per-app clipboard paste delay rows. Opens an NSOpenPanel scoped
/// to /Applications, reads the bundle identifier + display name,
/// and calls back with a ``PickedApp``.
struct AppPickerButton: View {
  let currentName: String
  let isEmpty: Bool
  let message: String
  let onPick: (PickedApp) -> Void

  init(
    currentName: String,
    isEmpty: Bool = false,
    message: String = "Choose an application",
    onPick: @escaping (PickedApp) -> Void
  ) {
    self.currentName = currentName
    self.isEmpty = isEmpty
    self.message = message
    self.onPick = onPick
  }

  var body: some View {
    Button {
      pickApp()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "app.badge")
          .foregroundStyle(.secondary)
        Text(isEmpty ? "Pick app\u{2026}" : currentName)
          .lineLimit(1)
          .foregroundStyle(isEmpty ? .secondary : .primary)
      }
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .help("Click to pick an application")
  }

  /// Open ``NSOpenPanel`` scoped to /Applications, read the picked
  /// bundle's `Info.plist` for the bundle identifier + display name.
  /// Falls back to the file basename if the plist read fails (rare,
  /// but possible for non-app bundles the user might pick by mistake).
  private func pickApp() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.message = message
    panel.prompt = "Select"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let bundle = Bundle(url: url)
    let bundleID = bundle?.bundleIdentifier ?? ""
    let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? url.deletingPathExtension().lastPathComponent

    onPick(PickedApp(bundleIdentifier: bundleID, appName: name))
  }
}
