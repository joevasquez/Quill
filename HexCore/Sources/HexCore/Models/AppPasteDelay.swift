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
		.init(bundleIdentifier: "com.citrix.receiver.nomas", appName: "Citrix Workspace", delayMs: 300, isEnabled: false),
		.init(bundleIdentifier: "com.citrix.XenAppViewer", appName: "Citrix Viewer", delayMs: 300, isEnabled: false),
		.init(bundleIdentifier: "com.microsoft.rdc.macos", appName: "Microsoft Remote Desktop", delayMs: 300, isEnabled: false),
		.init(bundleIdentifier: "com.vmware.horizon", appName: "VMware Horizon", delayMs: 300, isEnabled: false),
		.init(bundleIdentifier: "com.parallels.desktop.console", appName: "Parallels Desktop", delayMs: 300, isEnabled: false),
	]

	public static func delayMs(for bundleID: String, in delays: [AppPasteDelay]) -> Int {
		guard let match = delays.first(where: { $0.bundleIdentifier == bundleID && $0.isEnabled }) else {
			return 0
		}
		return match.delayMs
	}
}
