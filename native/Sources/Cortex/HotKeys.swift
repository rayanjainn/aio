import AppKit
import Carbon.HIToolbox

/// The same shortcut table the old app used (ids, labels and default accelerators), so
/// existing `~/.cortex/config.json → shortcuts` overrides keep working.
enum ShortcutTable {
    struct Entry { let id: String; let label: String; let group: String; let accel: String }

    static let all: [Entry] = [
        Entry(id: "palette", label: "Open Cortex", group: "General", accel: "CommandOrControl+K"),
        Entry(id: "pause", label: "Pause / resume screen memory", group: "General", accel: "CommandOrControl+Shift+P"),
        Entry(id: "island", label: "Expand the Island", group: "General", accel: "Control+Alt+Space"),
        Entry(id: "switcher", label: "Switch windows (all apps and Spaces)", group: "General", accel: "Alt+Tab"),
        Entry(id: "act", label: "Act on the selection (summarise, translate, reply…)", group: "General", accel: "Control+Alt+KeyA"),
        Entry(id: "clip.plain", label: "Paste as plain text", group: "General", accel: "Control+Alt+Shift+KeyV"),
        Entry(id: "window.left", label: "Left Half", group: "Windows", accel: "Control+Alt+ArrowLeft"),
        Entry(id: "window.right", label: "Right Half", group: "Windows", accel: "Control+Alt+ArrowRight"),
        Entry(id: "window.top", label: "Top Half", group: "Windows", accel: "Control+Alt+ArrowUp"),
        Entry(id: "window.bottom", label: "Bottom Half", group: "Windows", accel: "Control+Alt+ArrowDown"),
        Entry(id: "window.topLeft", label: "Top Left", group: "Windows", accel: "Control+Alt+KeyU"),
        Entry(id: "window.topRight", label: "Top Right", group: "Windows", accel: "Control+Alt+KeyI"),
        Entry(id: "window.bottomLeft", label: "Bottom Left", group: "Windows", accel: "Control+Alt+KeyJ"),
        Entry(id: "window.bottomRight", label: "Bottom Right", group: "Windows", accel: "Control+Alt+KeyK"),
        Entry(id: "window.leftThird", label: "Left Third", group: "Windows", accel: "Control+Alt+KeyD"),
        Entry(id: "window.centerThird", label: "Center Third", group: "Windows", accel: "Control+Alt+KeyF"),
        Entry(id: "window.rightThird", label: "Right Third", group: "Windows", accel: "Control+Alt+KeyG"),
        Entry(id: "window.leftTwoThirds", label: "Left Two Thirds", group: "Windows", accel: "Control+Alt+KeyE"),
        Entry(id: "window.rightTwoThirds", label: "Right Two Thirds", group: "Windows", accel: "Control+Alt+KeyT"),
        Entry(id: "window.max", label: "Maximize", group: "Windows", accel: "Control+Alt+Enter"),
        Entry(id: "window.almostMax", label: "Almost Maximize", group: "Windows", accel: "Control+Alt+Shift+Enter"),
        Entry(id: "window.center", label: "Center", group: "Windows", accel: "Control+Alt+KeyC"),
        Entry(id: "window.fullscreen", label: "Toggle Fullscreen", group: "Windows", accel: "Control+Alt+KeyF11"),
        Entry(id: "window.restore", label: "Restore", group: "Windows", accel: "Control+Alt+Backspace"),
        Entry(id: "window.nextDisplay", label: "Next Display", group: "Windows", accel: "Control+Alt+Command+ArrowRight"),
    ]

    /// Accelerator per action: user override from config.json, else the default ("" = off).
    static func effective() -> [(id: String, accel: String)] {
        let overrides = ConfigFile.shortcuts()
        return all.map { (id: $0.id, accel: overrides[$0.id] ?? $0.accel) }
    }
}

enum Accelerator {
    /// "Control+Alt+KeyU" → (keyCode, Carbon modifiers). Nil if it can't be parsed.
    static func parse(_ text: String) -> (key: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for raw in text.split(separator: "+").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            switch raw.lowercased() {
            case "commandorcontrol", "cmdorctrl", "command", "cmd", "super", "meta": modifiers |= UInt32(cmdKey)
            case "control", "ctrl": modifiers |= UInt32(controlKey)
            case "alt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default:
                guard let code = keyCode(raw) else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (key, modifiers)
    }

    private static let letters: [Character: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
    ]
    private static let digits: [Character: Int] = [
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
    private static let functionKeys: [String: Int] = [
        "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7,
        "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
    ]
    private static let named: [String: Int] = [
        "arrowleft": kVK_LeftArrow, "arrowright": kVK_RightArrow, "arrowup": kVK_UpArrow, "arrowdown": kVK_DownArrow,
        "enter": kVK_Return, "return": kVK_Return, "space": kVK_Space, "backspace": kVK_Delete,
        "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
    ]

    /// The accelerator text for a key press ("Control+Alt+KeyU"), for the shortcut recorder.
    static func format(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("Command") }
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        guard !parts.isEmpty else { return nil }   // a global shortcut needs at least one modifier
        let code = Int(keyCode)
        if let l = letters.first(where: { $0.value == code }) { parts.append("Key\(l.key)") }
        else if let d = digits.first(where: { $0.value == code }) { parts.append(String(d.key)) }
        else if let f = functionKeys.first(where: { $0.value == code }) { parts.append(f.key) }
        else {
            let special: [Int: String] = [kVK_LeftArrow: "ArrowLeft", kVK_RightArrow: "ArrowRight", kVK_UpArrow: "ArrowUp",
                                          kVK_DownArrow: "ArrowDown", kVK_Return: "Enter", kVK_Space: "Space",
                                          kVK_Delete: "Backspace", kVK_Tab: "Tab"]
            guard let name = special[code] else { return nil }
            parts.append(name)
        }
        return parts.joined(separator: "+")
    }

    /// Human-readable form: "⌃⌥K".
    static func display(_ accel: String) -> String {
        guard !accel.isEmpty else { return "Not set" }
        return accel.split(separator: "+").map { part -> String in
            switch part.lowercased() {
            case "command", "cmd", "commandorcontrol", "cmdorctrl", "super", "meta": return "⌘"
            case "control", "ctrl": return "⌃"
            case "alt", "option": return "⌥"
            case "shift": return "⇧"
            case "arrowleft": return "←"
            case "arrowright": return "→"
            case "arrowup": return "↑"
            case "arrowdown": return "↓"
            case "enter", "return": return "↩"
            case "backspace": return "⌫"
            case "space": return "Space"
            default: return String(part).hasPrefix("Key") ? String(part.dropFirst(3)) : String(part)
            }
        }.joined()
    }

    private static func keyCode(_ name: String) -> UInt32? {
        let lower = name.lowercased()
        if let v = named[lower] { return UInt32(v) }
        var n = name
        if n.hasPrefix("Key") { n.removeFirst(3) }
        if n.hasPrefix("Digit") { n.removeFirst(5) }
        if let f = functionKeys[n.uppercased()] { return UInt32(f) }
        if n.count == 1, let c = n.uppercased().first {
            if let v = letters[c] { return UInt32(v) }
            if let v = digits[c] { return UInt32(v) }
        }
        return nil
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    if status == noErr {
        let fired = id.id
        DispatchQueue.main.async { HotKeyCenter.shared.fire(fired) }
    }
    return noErr
}

/// Global hotkeys via Carbon (no permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private(set) var errors: [String: String] = [:]
    var onAction: ((String) -> Void)?

    func registerAll() {
        install()
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll(); actions.removeAll(); errors.removeAll()
        var entries = ShortcutTable.effective()
        // "Open this app" shortcuts the user added in Settings (stored as "app:<bundle id>").
        for (id, accel) in ConfigFile.shortcuts() where id.hasPrefix("app:") { entries.append((id: id, accel: accel)) }
        for entry in entries {
            guard !entry.accel.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let parsed = Accelerator.parse(entry.accel) else {
                errors[entry.id] = "“\(entry.accel)” isn't a valid shortcut"
                continue
            }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x434F5254), id: id)   // 'CORT'
            let status = RegisterEventHotKey(parsed.key, parsed.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                actions[id] = entry.id
            } else {
                errors[entry.id] = "In use by another app"
                Log.warn("hotkey \(entry.id) (\(entry.accel)) not registered: status \(status)")
            }
        }
        Log.info("hotkeys: \(refs.count) registered, \(errors.count) failed")
    }

    fileprivate func fire(_ id: UInt32) {
        if let action = actions[id] { onAction?(action) }
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }
}
