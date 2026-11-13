import Carbon
import AppKit
import Foundation

/// Global callback registry keyed by hotkey ID
private var hotkeyCallbacks: [UInt32: () -> Void] = [:]

/// Whether the global Carbon event handler has been installed
private var eventHandlerInstalled = false

class HotkeyManager {
    static let shared = HotkeyManager()
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    private func ensureEventHandler() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                DiagnosticLog.shared.info("HotkeyManager: fired id=\(hotkeyID.id)")
                hotkeyCallbacks[hotkeyID.id]?()
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    /// Register a single global hotkey with a given ID, key code, and Carbon modifier mask
    @discardableResult
    func registerSingle(id: UInt32, keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> Bool {
        ensureEventHandler()

        if let existing = hotKeyRefs[id] {
            UnregisterEventHotKey(existing)
            hotKeyRefs.removeValue(forKey: id)
        }

        hotkeyCallbacks[id] = callback

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x444D5558),  // "DMUX"
            id: id
        )

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref {
            hotKeyRefs[id] = ref
            DiagnosticLog.shared.info("HotkeyManager: registered id=\(id) keyCode=\(keyCode) mods=\(modifiers)")
        } else {
            DiagnosticLog.shared.warn("HotkeyManager: failed to register id=\(id) keyCode=\(keyCode) mods=\(modifiers) status=\(status)")
        }
        return status == noErr && ref != nil
    }

    /// Unregister one global hotkey and clear its active callback.
    func unregisterSingle(id: UInt32) {
        if let existing = hotKeyRefs[id] {
            UnregisterEventHotKey(existing)
            hotKeyRefs.removeValue(forKey: id)
        }
        hotkeyCallbacks.removeValue(forKey: id)
        DiagnosticLog.shared.info("HotkeyManager: unregistered id=\(id)")
    }
}
