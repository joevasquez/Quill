//
//  PasteboardClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Sauce
import SwiftUI

private let pasteboardLogger = HexLog.pasteboard

@DependencyClient
struct PasteboardClient {
    /// Paste `text` into the user's target application.
    ///
    /// `sourceAppBundleID` is the bundle identifier of the app that was
    /// frontmost when the user started recording — captured in
    /// `TranscriptionFeature.startRecording`. If provided, the paste
    /// flow re-activates that app and waits briefly for focus to
    /// settle before inserting text, so pastes reliably land in the
    /// user's intended app even when they've Cmd-Tabbed to a different
    /// window while Whisper / AI post-processing was running.
    var paste: @Sendable (String, String?) async -> Void
    var copy: @Sendable (String) async -> Void
    var sendKeyboardCommand: @Sendable (KeyboardCommand) async -> Void
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init(
            paste: { text, sourceAppBundleID in
                await live.paste(text: text, sourceAppBundleID: sourceAppBundleID)
            },
            copy: { text in
                await live.copy(text: text)
            },
            sendKeyboardCommand: { command in
                await live.sendKeyboardCommand(command)
            }
        )
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

struct PasteboardClientLive {
    @Shared(.hexSettings) var hexSettings: HexSettings
    
    private struct PasteboardSnapshot {
        let items: [[String: Any]]
        
        init(pasteboard: NSPasteboard) {
            var saved: [[String: Any]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var itemDict: [String: Any] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemDict[type.rawValue] = data
                    }
                }
                saved.append(itemDict)
            }
            self.items = saved
        }
        
        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            for itemDict in items {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    if let data = data as? Data {
                        item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                    }
                }
                pasteboard.writeObjects([item])
            }
        }
    }

    @MainActor
    func paste(text: String, sourceAppBundleID: String?) async {
        // Before doing anything, bring the user's intended target app
        // back to front. Without this, a paste that lands 1-3s after
        // the hotkey release (Whisper + AI post-processing take time)
        // goes to whichever app the user Cmd-Tabbed to during the
        // wait — not the app they were dictating into. See the file's
        // `reactivateSourceApp` for the full rationale.
        await reactivateSourceApp(bundleID: sourceAppBundleID)

        // Hard refuse to paste into Quill itself. If the user has our
        // Settings / History / menu bar popover frontmost when the
        // paste fires, we'd write the transcription into one of our
        // own text fields instead of the intended app. Both the AX
        // path and the Cmd+V path will happily do this if we don't
        // guard against it — and the result is the transcription
        // silently vanishing from the user's perspective.
        let ourBundleID = Bundle.main.bundleIdentifier ?? ""
        if let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontBundle == ourBundleID {
            pasteboardLogger.warning(
                "Frontmost app is Quill itself; refusing to paste into ourselves. Leaving transcription in the clipboard."
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let pasteDelay = AppPasteDelay.delayMs(for: targetBundleID, in: hexSettings.appPasteDelays)
        if pasteDelay > 0 {
            pasteboardLogger.info("Using \(pasteDelay)ms clipboard paste delay for \(targetBundleID, privacy: .public)")
        }

        if hexSettings.useClipboardPaste {
            await pasteWithClipboard(text, clipboardPasteDelayMs: pasteDelay)
        } else {
            simulateTypingWithAppleScript(text)
        }

        // After either path, make sure the clipboard contains the
        // transcription — not whatever the user had copied before.
        // Rationale: if our AX insertion landed in the wrong element
        // (or a silent failure we couldn't detect), the user will
        // naturally try Cmd+V in the real target app. That manual
        // paste must deliver the transcription, never a previously
        // copied API key, password, or unrelated text. Also, if the
        // user explicitly wants Quill to keep the transcription in
        // their clipboard (the default since 0.8.5), this is exactly
        // what they asked for.
        //
        // We only skip this if the user has explicitly opted to
        // restore the previous clipboard (`copyToClipboard = false`)
        // AND we went down the clipboard path — in that case the
        // existing 3 s restore timer owns the clipboard lifecycle.
        if hexSettings.copyToClipboard {
            let pb = NSPasteboard.general
            if pb.string(forType: .string) != text {
                pb.clearContents()
                pb.setString(text, forType: .string)
                pasteboardLogger.debug("Synced clipboard to transcription (post-paste safety)")
            }
        }
    }

    /// Bring the user's recording-time target app back to front so
    /// that both the Accessibility-focused-element query and the
    /// injected Cmd+V land in the intended app, not whichever window
    /// the user happened to have focused when the transcription
    /// finished. Especially important on slow-to-finish paths
    /// (long recordings + AI post-processing) where the user is very
    /// likely to have switched contexts during the wait.
    @MainActor
    private func reactivateSourceApp(bundleID: String?) async {
        guard let bundleID, !bundleID.isEmpty else {
            pasteboardLogger.debug("No source app bundle ID; skipping reactivation")
            return
        }
        // If we are the frontmost app (e.g. the user was recording
        // *into* Quill, or Settings is open), don't reactivate — any
        // paste should go to whatever is front. The Quill-refuse
        // guard above handles the pathological case.
        if bundleID == Bundle.main.bundleIdentifier { return }

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        )
        guard let app = running.first else {
            pasteboardLogger.info("Source app \(bundleID) no longer running; pasting into whatever is front")
            return
        }

        // Already frontmost? Still nudge focus + short wait — this
        // covers the case where the user Cmd-Tabbed away and back
        // rapidly, leaving the window layer technically right but the
        // focused-element AX state stale.
        let alreadyFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        if !alreadyFront {
            app.activate(options: [.activateIgnoringOtherApps])
            pasteboardLogger.debug("Reactivated source app \(bundleID)")
        }

        // Wait for focus to settle. 120ms is a lot longer than it
        // looks — it's what reliably works for Arc, Chrome, VS Code,
        // Slack, Notion, and native AppKit on an M-series Mac. Less
        // than ~80ms and AX frequently reads the stale focused
        // element.
        try? await Task.sleep(for: .milliseconds(120))
    }
    
    @MainActor
    func copy(text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    @MainActor
    func sendKeyboardCommand(_ command: KeyboardCommand) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // Convert modifiers to CGEventFlags and key codes for modifier keys
        var modifierKeyCodes: [CGKeyCode] = []
        var flags = CGEventFlags()
        
        for modifier in command.modifiers.sorted {
            switch modifier.kind {
            case .command:
                flags.insert(.maskCommand)
                modifierKeyCodes.append(55) // Left Cmd
            case .shift:
                flags.insert(.maskShift)
                modifierKeyCodes.append(56) // Left Shift
            case .option:
                flags.insert(.maskAlternate)
                modifierKeyCodes.append(58) // Left Option
            case .control:
                flags.insert(.maskControl)
                modifierKeyCodes.append(59) // Left Control
            case .fn:
                flags.insert(.maskSecondaryFn)
                // Fn key doesn't need explicit key down/up
            }
        }
        
        // Press modifiers down
        for keyCode in modifierKeyCodes {
            let modDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            modDown?.post(tap: .cghidEventTap)
        }
        
        // Press main key if present
        if let key = command.key {
            let keyCode = Sauce.shared.keyCode(for: key)
            
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            keyDown?.flags = flags
            keyDown?.post(tap: .cghidEventTap)
            
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            keyUp?.flags = flags
            keyUp?.post(tap: .cghidEventTap)
        }
        
        // Release modifiers in reverse order
        for keyCode in modifierKeyCodes.reversed() {
            let modUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            modUp?.post(tap: .cghidEventTap)
        }
        
        pasteboardLogger.debug("Sent keyboard command: \(command.displayName)")
    }

    /// Pastes current clipboard content to the frontmost application
    static func pasteToFrontmostApp() -> Bool {
        let script = """
        if application "System Events" is not running then
            tell application "System Events" to launch
            delay 0.1
        end if
        tell application "System Events"
            tell process (name of first application process whose frontmost is true)
                tell (menu item "Paste" of menu of menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        log (get properties of it)
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    end if
                end tell
                tell (menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    else
                        return false
                    end if
                end tell
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            if let error = error {
                pasteboardLogger.error("AppleScript paste failed: \(error)")
                return false
            }
            return result.booleanValue
        }
        return false
    }

    @MainActor
    func pasteWithClipboard(_ text: String, clipboardPasteDelayMs: Int = 0) async {
        // Check Accessibility permission once. Both the AX-insertion
        // path AND the Cmd+V injection path require it (CGEvent.post
        // silently fails without AX trust). If denied, we can still
        // write to the clipboard so the user can paste manually, but
        // we log a clear warning so the source of "nothing happened"
        // shows up in the logs.
        let hasAXPermission = AXIsProcessTrusted()

        if !hasAXPermission {
            pasteboardLogger.warning(
                "Accessibility permission not granted — auto-paste will not work. Text will be written to the clipboard as a fallback; user must press Cmd+V manually."
            )
        }

        // Path 1: Accessibility text insertion — NO CLIPBOARD INVOLVED.
        //
        // Write the text directly into the focused text field via
        // `AXUIElementSetAttributeValue` and verify it actually
        // landed by reading the element's value back. Skipped when
        // permission is missing. On success the clipboard is never
        // touched — no race against the target app's paste handler,
        // no risk of pasting whatever was previously copied.
        if hasAXPermission,
           (try? Self.insertTextAtCursor(text)) != nil {
            pasteboardLogger.debug("Pasted via Accessibility (verified, clipboard untouched)")
            return
        }

        if hasAXPermission {
            pasteboardLogger.info(
                "Accessibility paste failed or didn't verify; falling back to clipboard + Cmd+V"
            )
        }

        // Path 2: Clipboard + Cmd+V fallback.
        //
        // Write the transcription to the clipboard, then (if AX is
        // granted) fire Cmd+V. If AX is denied, Cmd+V won't fire —
        // but the text is in the clipboard so the user can paste it
        // manually and no dictation is lost.
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let targetChangeCount = writeAndTrackChangeCount(pasteboard: pasteboard, text: text)
        _ = await waitForPasteboardCommit(targetChangeCount: targetChangeCount)

        if hasAXPermission {
            _ = await postCmdV(delayMs: clipboardPasteDelayMs)
        } else {
            pasteboardLogger.notice(
                "Cmd+V injection skipped (no Accessibility permission). Transcription left in the clipboard."
            )
        }

        // Restore only when the user has explicitly asked us NOT to
        // leave the transcription in the clipboard. The default was
        // flipped to keep the transcription (`copyToClipboard = true`)
        // because losing clipboard retention is far less costly than
        // pasting the wrong content — an API key, a password, or any
        // other sensitive thing the user previously copied.
        //
        // We also skip the restore entirely if AX is missing (the
        // clipboard IS the paste at that point — the user will Cmd+V
        // manually — so we must not overwrite it).
        if !hexSettings.copyToClipboard && hasAXPermission {
            let savedSnapshot = snapshot
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(3000))
                let currentCount = pasteboard.changeCount
                guard currentCount == targetChangeCount else {
                    pasteboardLogger.info(
                        "Skipping clipboard restore: pasteboard changed after paste (count=\(currentCount), expected=\(targetChangeCount))"
                    )
                    return
                }
                pasteboard.clearContents()
                savedSnapshot.restore(to: pasteboard)
                pasteboardLogger.debug("Restored previous clipboard contents after paste")
            }
        }
    }

    @MainActor
    private func writeAndTrackChangeCount(pasteboard: NSPasteboard, text: String) -> Int {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let after = pasteboard.changeCount
        if after == before {
            // Ensure we always advance by at least one to avoid infinite waits if the system
            // coalesces writes (seen on Sonoma betas with zero-length strings).
            return after + 1
        }
        return after
    }

    @MainActor
    private func waitForPasteboardCommit(
        targetChangeCount: Int,
        timeout: Duration = .milliseconds(150),
        pollInterval: Duration = .milliseconds(5)
    ) async -> Bool {
        guard targetChangeCount > NSPasteboard.general.changeCount else { return true }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSPasteboard.general.changeCount >= targetChangeCount {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    // MARK: - Paste Orchestration

    @MainActor
    private enum PasteStrategy: CaseIterable {
        case cmdV
        case menuItem
        case accessibility
    }

    @MainActor
    private func performPaste(_ text: String) async -> Bool {
        for strategy in PasteStrategy.allCases {
            if await attemptPaste(text, using: strategy) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func attemptPaste(_ text: String, using strategy: PasteStrategy) async -> Bool {
        switch strategy {
        case .cmdV:
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let delay = AppPasteDelay.delayMs(for: bundleID, in: hexSettings.appPasteDelays)
            return await postCmdV(delayMs: delay)
        case .menuItem:
            return PasteboardClientLive.pasteToFrontmostApp()
        case .accessibility:
            return (try? Self.insertTextAtCursor(text)) != nil
        }
    }

    // MARK: - Helpers

    @MainActor
    private func postCmdV(delayMs: Int) async -> Bool {
        // Optional tiny wait before keystrokes
        try? await wait(milliseconds: delayMs)
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = vKeyCode()
        let cmdKey: CGKeyCode = 55
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    private func vKeyCode() -> CGKeyCode {
        if Thread.isMainThread { return Sauce.shared.keyCode(for: .v) }
        return DispatchQueue.main.sync { Sauce.shared.keyCode(for: .v) }
    }

    @MainActor
    private func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
    
    func simulateTypingWithAppleScript(_ text: String) {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"System Events\" to keystroke \"\(escapedText)\"")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            pasteboardLogger.error("Error executing AppleScript typing fallback: \(error)")
        }
    }

    enum PasteError: Error {
        case systemWideElementCreationFailed
        case focusedElementNotFound
        case elementDoesNotSupportTextEditing
        case failedToInsertText
    }
    
    /// Cap on every AX call below. AX is an inter-process API
    /// without a default timeout — by default, an unresponsive
    /// focused app can hang the calling thread for ~6 s. We're on
    /// the main thread here, so a hang freezes Quill's UI. 0.2 s
    /// is comfortably above normal AX response times (1–10 ms) but
    /// well below human-noticeable lag.
    private static let axMessagingTimeout: Float = 0.2

    static func insertTextAtCursor(_ text: String) throws {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, axMessagingTimeout)

        // Get the focused element
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)

        guard axError == .success, let focusedElementRef = focusedElementRef else {
            throw PasteError.focusedElementNotFound
        }

        let focusedElement = focusedElementRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focusedElement, axMessagingTimeout)

        // Verify if the focused element supports text insertion
        var probeValue: CFTypeRef?
        let supportsText = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &probeValue) == .success
        let supportsSelectedText = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &probeValue) == .success

        if !supportsText && !supportsSelectedText {
            throw PasteError.elementDoesNotSupportTextEditing
        }

        // Capture the element's value BEFORE the insert so we can
        // verify the text actually landed. Some apps (particularly
        // Electron-based inputs, custom-drawn text fields, and apps
        // with incomplete AX implementations) return `.success` from
        // `AXUIElementSetAttributeValue` but silently drop the write.
        // Without verification, the user sees "nothing happened".
        var beforeRef: CFTypeRef?
        let beforeStatus = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &beforeRef)
        let beforeValue = (beforeStatus == .success) ? (beforeRef as? String) : nil

        // Insert text at cursor position by replacing selected text (or empty selection)
        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)

        if insertResult != .success {
            throw PasteError.failedToInsertText
        }

        // Verify: read the value back. If the element exposes its
        // value via AX, the `afterValue` should have grown to include
        // our `text`. If it didn't change, the app accepted our set
        // call but didn't actually apply it — treat as failure so the
        // caller falls through to the clipboard path.
        //
        // Elements that didn't expose `kAXValueAttribute` for the
        // `before` read are given the benefit of the doubt (the
        // verification is skipped) — otherwise we'd break valid
        // inserts into elements that only expose selected text.
        if let before = beforeValue {
            var afterRef: CFTypeRef?
            let afterStatus = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &afterRef)
            let afterValue = (afterStatus == .success) ? (afterRef as? String) : nil
            // Treat an unreadable post-write value as failure too —
            // if the element exposed its value before but not after,
            // we can't confirm the text landed. Falling through to
            // clipboard+Cmd+V may double-paste in the rare case AX
            // did work, but that's visible and undoable — unlike the
            // silent no-paste when we optimistically return here.
            guard let after = afterValue, after != before else {
                throw PasteError.failedToInsertText
            }
        }
    }
}
