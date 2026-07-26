import AppKit
import Carbon.HIToolbox

// A system-wide shortcut to open the panel without reaching for the trackpad.
//
// Carbon's RegisterEventHotKey is used on purpose: NSEvent's global monitors need
// Accessibility permission, which this app otherwise doesn't require and which
// gets revoked every time the binary is rebuilt. The Carbon API is ancient but
// needs no permission at all.
final class Hotkey {
    static let shared = Hotkey()
    private init() {}

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func register(keyCode: Int, modifierNames: [String], action: @escaping () -> Void) {
        unregister()
        self.action = action

        var modifiers: UInt32 = 0
        for name in modifierNames.map({ $0.lowercased() }) {
            switch name {
            case "command", "cmd": modifiers |= UInt32(cmdKey)
            case "option", "alt":  modifiers |= UInt32(optionKey)
            case "control", "ctrl": modifiers |= UInt32(controlKey)
            case "shift":          modifiers |= UInt32(shiftKey)
            default: notchDebug("hotkey: unknown modifier '\(name)'")
            }
        }
        guard modifiers != 0 else {
            notchDebug("hotkey: refusing to bind a bare key with no modifier")
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData = userData else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.action?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1,
                            &eventType,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5443), id: 1)   // 'NOTC'
        let status = RegisterEventHotKey(UInt32(keyCode),
                                        modifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotKeyRef)
        if status == noErr {
            notchDebug("hotkey registered: keyCode=\(keyCode) modifiers=\(modifierNames)")
        } else {
            // Usually means another app already owns the combination.
            notchDebug("hotkey registration failed (status \(status)) — combination may be taken")
        }
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
