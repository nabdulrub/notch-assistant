import AppKit
import Carbon.HIToolbox
import AssistantCore

/// Carbon hot keys, on purpose. They need no permission of any kind, they work
/// from any app, and the system swallows the keystroke so the combination never
/// leaks into whatever is focused. They also deliver a release event, which is
/// what makes hold to talk possible without an event tap.
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4E_41_53_54 // 'NAST'
    private static weak var active: HotkeyManager?

    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        guard combo.isUsable else { return false }

        HotkeyManager.active = self
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), carbonModifiers(combo.modifiers), id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            guard let event else { return noErr }
            switch Int(GetEventKind(event)) {
            case kEventHotKeyPressed: HotkeyManager.active?.onPress?()
            case kEventHotKeyReleased: HotkeyManager.active?.onRelease?()
            default: break
            }
            return noErr
        }, specs.count, &specs, nil, &eventHandler)
    }

    private func carbonModifiers(_ modifiers: ModifierSet) -> UInt32 {
        var out: UInt32 = 0
        if modifiers.contains(.command) { out |= UInt32(cmdKey) }
        if modifiers.contains(.option) { out |= UInt32(optionKey) }
        if modifiers.contains(.control) { out |= UInt32(controlKey) }
        if modifiers.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }

    deinit { unregister() }
}

/// Watches the key that hold to talk is bound to, as a backstop for a release
/// event that never arrives.
///
/// `CGEventSource.keyState` reads the live keyboard without an event tap, so it
/// costs no Accessibility permission. It only runs while a key is actually held,
/// so there is no idle cost, and `PushToTalkState` refuses to act on it until it
/// has proved it can see the key down.
final class KeyStateWatcher {
    private var timer: DispatchSourceTimer?
    private(set) var keyCode: UInt16 = 0

    var isKeyDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    func watch(_ keyCode: UInt16, interval: TimeInterval = 0.03, tick: @escaping (Bool) -> Void) {
        stop()
        self.keyCode = keyCode
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            tick(self.isKeyDown)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }
}
