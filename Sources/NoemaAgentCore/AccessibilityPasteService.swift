import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import NoemaClipboardCore

/// How a paste-back ended. Every case except `.pasted` and `.abortedPasteboardChanged`
/// leaves the entry on the pasteboard for the user to paste with ⌘V.
public enum ClipboardPasteOutcome: Sendable, Hashable {
    case pasted
    /// Accessibility is not granted: no keystroke is synthesized.
    case copiedNeedsAccessibility
    /// No app to paste into was recorded.
    case copiedNoTarget
    /// The target did not become frontmost within the timeout, or another app did.
    case abortedFocusLost
    /// Secure input came on after the target was reactivated.
    case abortedSecureInput
    /// Another process (or a newer paste-back) replaced the pasteboard before ⌘V was posted.
    case abortedPasteboardChanged
}

/// The system calls a paste-back makes; tests substitute a spy.
@MainActor
public protocol AccessibilityPasteDriver: AnyObject {
    func isAXTrusted() -> Bool
    @discardableResult func activate(pid: pid_t) -> Bool
    func frontmostPID() -> pid_t?
    func isSecureInputActive() -> Bool
    /// Posts ⌘V (key down and up).
    func postCommandV()
    func sleep(milliseconds: Int) async
}

/// `AXIsProcessTrusted()`, `NSRunningApplication.activate()`, `IsSecureEventInputEnabled()`,
/// and `kVK_ANSI_V` with `.maskCommand` from a `.combinedSessionState` source posted at
/// `.cgAnnotatedSessionEventTap`.
@MainActor
public final class SystemAccessibilityPasteDriver: AccessibilityPasteDriver {
    public init() {}

    public func isAXTrusted() -> Bool { AXIsProcessTrusted() }

    public func activate(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    }

    public func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    public func isSecureInputActive() -> Bool { IsSecureEventInputEnabled() }

    public func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    public func sleep(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// Pastes the entry already on the pasteboard into the app that was frontmost before the
/// panel opened. Without Accessibility it only reactivates that app. With it, it waits up
/// to `focusTimeoutMilliseconds` for the app to be frontmost, aborts if another app comes
/// forward or secure input turns on, and only then posts ⌘V.
@MainActor
public final class AccessibilityPasteService {
    public static let focusTimeoutMilliseconds = 150
    public static let focusPollMilliseconds = 15
    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let driver: any AccessibilityPasteDriver
    private let ownPID: pid_t

    public init(driver: any AccessibilityPasteDriver, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.driver = driver
        self.ownPID = ownPID
    }

    public var isTrusted: Bool { driver.isAXTrusted() }

    public func paste(into target: ClipboardSourceApp?, verifyOwnership: @MainActor () -> Bool = { true }) async -> ClipboardPasteOutcome {
        guard let pid = target?.pid, pid > 0 else { return .copiedNoTarget }
        guard verifyOwnership() else { return .abortedPasteboardChanged }
        driver.activate(pid: pid)
        guard driver.isAXTrusted() else { return .copiedNeedsAccessibility }
        var waited = 0
        while true {
            guard verifyOwnership() else { return .abortedPasteboardChanged }
            let front = driver.frontmostPID()
            if front == pid { break }
            if let front, front != ownPID { return .abortedFocusLost }
            guard waited < Self.focusTimeoutMilliseconds else { return .abortedFocusLost }
            await driver.sleep(milliseconds: Self.focusPollMilliseconds)
            waited += Self.focusPollMilliseconds
        }
        guard !driver.isSecureInputActive() else { return .abortedSecureInput }
        guard driver.frontmostPID() == pid else { return .abortedFocusLost }
        guard verifyOwnership() else { return .abortedPasteboardChanged }
        driver.postCommandV()
        return .pasted
    }

    /// Shows the system Accessibility prompt; call only from an explicit user action.
    @discardableResult
    public static func requestAccessibilityPrompt() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(accessibilitySettingsURL)
    }
}
