import AppKit
import Carbon.HIToolbox

/// "Act on this": copy whatever is selected in the front app, then offer actions on it in the palette.
enum ActOnThis {
    /// Sends ⌘C to the front app and calls back once the clipboard changes (or after a short wait,
    /// in which case the existing clipboard is used).
    static func captureSelection(_ done: @escaping () -> Void) {
        guard WindowManager.isTrusted else { WindowManager.requestAccess(); done(); return }
        let before = NSPasteboard.general.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        var tries = 0
        func poll() {
            tries += 1
            if NSPasteboard.general.changeCount != before || tries > 8 { done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }

    /// Starts macOS dictation in the front app through its Edit → Start Dictation menu item.
    static func dictate() {
        guard WindowManager.isTrusted else { WindowManager.requestAccess(); return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        if let item = MenuItemService.entries(forPID: pid).first(where: { $0.title.localizedCaseInsensitiveContains("dictation") }) {
            MenuItemService.press(item)
        } else {
            Toast.show("mic.slash", "This app has no Start Dictation item. Turn on Dictation in System Settings → Keyboard.")
        }
    }

    /// Paste what is on the clipboard as plain text (no fonts, colours or links).
    static func pastePlain() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        PasteService.copy(s)
        PasteService.pasteIntoFront(after: 0.05)
    }
}

/// Snippets with `{ask:Label}` fields: asks for each value, then pastes into the app you were in.
enum SnippetForm {
    static func needsInput(_ text: String) -> Bool { text.contains("{ask:") }

    @MainActor
    static func fill(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\{ask:([^}]+)\\}") else { return text }
        let ns = text as NSString
        var labels: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let l = ns.substring(with: m.range(at: 1))
            if !labels.contains(l) { labels.append(l) }
        }
        var out = text
        NSApp.activate(ignoringOtherApps: true)
        for label in labels {
            let alert = NSAlert()
            alert.messageText = label
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            out = out.replacingOccurrences(of: "{ask:\(label)}", with: field.stringValue)
        }
        return out
    }
}
