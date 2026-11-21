import AppKit
import Carbon.HIToolbox

/// A global shortcut: Carbon key code and modifier mask, plus a display label.
struct Shortcut: Codable, Equatable {
    var key: UInt32, mods: UInt32, label: String

    static let defaults = [
        // ⌃⌥: unlike ⌥ combinations, these don't type a special character if they ever reach another app.
        Shortcut(key: UInt32(kVK_ANSI_S), mods: UInt32(controlKey | optionKey), label: "⌃⌥S"),
        Shortcut(key: UInt32(kVK_ANSI_T), mods: UInt32(controlKey | optionKey), label: "⌃⌥T"),
    ]
}

extension Shortcut {
    /// Builds a shortcut from a key press. Needs ⌃, ⌥ or ⌘: ⇧ alone would take over typing a capital
    /// letter in every app. F-keys are fine with just ⇧.
    init?(_ e: NSEvent) {
        let pairs: [(NSEvent.ModifierFlags, Int, String)] =
            [(.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")]
        let held = pairs.filter { e.modifierFlags.contains($0.0) }
        let key = Self.keyName(e)
        let isFunctionKey = key.count > 1 && key.hasPrefix("F")
        guard !held.isEmpty, held.contains(where: { $0.0 != .shift }) || isFunctionKey else { return nil }
        self.init(key: UInt32(e.keyCode), mods: UInt32(held.reduce(0) { $0 | $1.1 }), label: held.map(\.2).joined() + key)
    }

    /// ⌘ on its own, or with ⇧, is how every app's menu shortcuts work (⌘W, ⌘C, ⌘⇧S…), so taking one
    /// globally would break it in every app. Pressing ⌘W to close Settings while recording would do that.
    var clashesWithMenus: Bool {
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        return mods & ~UInt32(shiftKey) == UInt32(cmdKey) && !functionKeys.contains(Int(key))
    }

    func sameKeys(as other: Shortcut) -> Bool { key == other.key && mods == other.mods }

    /// The key's own name, with no modifiers applied, so ⌘⇧2 reads "2", not "@".
    private static func keyName(_ e: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return named[Int(e.keyCode)] ?? (e.characters(byApplyingModifiers: []) ?? "?").uppercased()
    }
}

/// Global hotkeys via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor enum HotKeys {
    private static var refs: [EventHotKeyRef] = []
    private static var actions: [() -> Void] = []

    /// Registers the shortcuts. Returns the indices that couldn't be registered (taken by another app).
    static func set(_ list: [(Shortcut, () -> Void)]) -> Set<Int> {
        pause()
        actions = list.map(\.1)
        _ = handlerInstalled
        var failed = Set<Int>()
        for (i, (s, _)) in list.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(s.key, s.mods, EventHotKeyID(signature: 0x5043_5452, id: UInt32(i)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.insert(i) }
        }
        return failed
    }

    /// Unregisters every shortcut until the next `set`.
    static func pause() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    private static let handlerInstalled: Void = {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            MainActor.assumeIsolated {  // Carbon delivers on the main thread
                if HotKeys.actions.indices.contains(Int(id.id)) { HotKeys.actions[Int(id.id)]() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }()
}
