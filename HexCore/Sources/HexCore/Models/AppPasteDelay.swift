import Foundation

public struct AppPasteDelay: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var bundleIdentifier: String
	public var appName: String
	public var delayMs: Int
	public var isEnabled: Bool

	public init(
		id: UUID = UUID(),
		bundleIdentifier: String,
		appName: String,
		delayMs: Int = 300,
		isEnabled: Bool = true
	) {
		self.id = id
		self.bundleIdentifier = bundleIdentifier
		self.appName = appName
		self.delayMs = delayMs
		self.isEnabled = isEnabled
	}

	public static let defaults: [AppPasteDelay] = [
		.init(bundleIdentifier: "com.citrix.receiver.nomas", appName: "Citrix Workspace", delayMs: 500, isEnabled: true),
		.init(bundleIdentifier: "com.citrix.XenAppViewer", appName: "Citrix Viewer", delayMs: 500, isEnabled: true),
		.init(bundleIdentifier: "com.microsoft.rdc.macos", appName: "Microsoft Remote Desktop", delayMs: 300, isEnabled: true),
		.init(bundleIdentifier: "com.vmware.horizon", appName: "VMware Horizon", delayMs: 300, isEnabled: true),
		.init(bundleIdentifier: "com.parallels.desktop.console", appName: "Parallels Desktop", delayMs: 300, isEnabled: true),
	]

	/// Known remote desktop bundle IDs that need an extra clipboard sync
	/// delay. Used as a fallback when the user hasn't explicitly configured
	/// a per-app delay — remote desktops synchronize the macOS clipboard to
	/// the remote session asynchronously, so Cmd+V arriving before the sync
	/// finishes produces a stale or empty paste.
	private static let remoteDesktopDefaults: [String: Int] = [
		"com.citrix.receiver.nomas": 500,
		"com.citrix.XenAppViewer": 500,
		"com.microsoft.rdc.macos": 300,
		"com.vmware.horizon": 300,
		"com.parallels.desktop.console": 300,
	]

	public static func delayMs(for bundleID: String, in delays: [AppPasteDelay]) -> Int {
		// Check user-configured delays first.
		if let match = delays.first(where: { $0.bundleIdentifier == bundleID && $0.isEnabled }) {
			return match.delayMs
		}
		// Fall back to built-in remote desktop defaults so Citrix/RDP/etc.
		// get a delay even for users who haven't touched the settings.
		return remoteDesktopDefaults[bundleID] ?? 0
	}
}
