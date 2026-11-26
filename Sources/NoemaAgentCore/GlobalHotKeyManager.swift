import Carbon.HIToolbox
import Foundation
import NoemaCore

/// System-wide hotkeys through Carbon `RegisterEventHotKey`: no Accessibility or Input
/// Monitoring permission, no event tap, no global `NSEvent` monitor. The event handler is
/// installed on the application event target once and removed with the last hotkey.
@MainActor
public final class GlobalHotKeyManager {
    public struct HotKey: Sendable, Hashable {
        public var keyCode: UInt32
        public var modifiers: UInt32

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// ⇧⌘V: the clipboard history panel.
        public static let clipboardPanel = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    }

    /// `'NOEM'`, the signature of every hotkey this manager registers.
    static let signature: OSType = 0x4E4F_454D

    private struct Registration {
        var ref: EventHotKeyRef
        var action: @MainActor () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private let log = NoemaLog.agent("hotkey")

    public init() {}

    public var registeredCount: Int { registrations.count }

    /// Registers `hotKey`; returns its id, or nil when the system refused it (for example,
    /// another app owns the combination).
    @discardableResult
    public func register(_ hotKey: HotKey, action: @escaping @MainActor () -> Void) -> UInt32? {
        guard installHandlerIfNeeded() else { return nil }
        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
            removeHandlerIfUnused()
            return nil
        }
        nextID += 1
        registrations[id] = Registration(ref: ref, action: action)
        return id
    }

    public func unregister(id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.ref)
        removeHandlerIfUnused()
    }

    /// Unregisters every hotkey and removes the event handler.
    public func unregisterAll() {
        for id in Array(registrations.keys) { unregister(id: id) }
        removeHandlerIfUnused()
    }

    func fire(id: UInt32) {
        registrations[id]?.action()
    }

    private func installHandlerIfNeeded() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr, hotKeyID.signature == GlobalHotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let id = hotKeyID.id
                // Carbon delivers application events on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue().fire(id: id)
                }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &installed)
        guard status == noErr, let installed else {
            log.error("InstallEventHandler failed: \(status, privacy: .public)")
            return false
        }
        handler = installed
        return true
    }

    private func removeHandlerIfUnused() {
        guard registrations.isEmpty, let handler else { return }
        RemoveEventHandler(handler)
        self.handler = nil
    }

    isolated deinit {
        unregisterAll()
    }
}
