import AppKit
import ApplicationServices

/// Moves and resizes the frontmost app's focused window through the Accessibility API.
enum WindowManager {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static var restoreFrames: [String: CGRect] = [:]

    /// Space the Cortex Dock occupies, so snapping and maximising leave it clear.
    static var reserved: (screen: CGRect, edge: String, thickness: CGFloat)?

    static func perform(_ action: String) {
        guard isTrusted else { requestAccess(); Log.warn("window: Accessibility permission missing"); return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let window = focused as! AXUIElement
        guard let frame = frame(of: window) else { return }

        let key = "\(app.processIdentifier)"
        let screens = screensInAXSpace()
        guard let index = screens.firstIndex(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) ?? (screens.isEmpty ? nil : 0) else { return }
        var visible = screens[index].visible
        if let r = reserved, NSScreen.screens.indices.contains(index), NSScreen.screens[index].frame == r.screen {
            switch r.edge {
            case "left": visible = CGRect(x: visible.minX + r.thickness, y: visible.minY, width: visible.width - r.thickness, height: visible.height)
            case "right": visible = CGRect(x: visible.minX, y: visible.minY, width: visible.width - r.thickness, height: visible.height)
            default: visible = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height - r.thickness)
            }
        }

        var target: CGRect?
        switch action {
        case "restore": target = restoreFrames[key]
        case "fullscreen": toggleFullscreen(window); return
        case "nextDisplay":
            let next = screens[(index + 1) % screens.count].visible
            target = CGRect(x: next.minX + (frame.minX - visible.minX) * next.width / visible.width,
                            y: next.minY + (frame.minY - visible.minY) * next.height / visible.height,
                            width: min(frame.width, next.width), height: min(frame.height, next.height))
        default: target = rect(for: action, in: visible, current: frame)
        }
        guard let target else { return }
        if action != "restore" { restoreFrames[key] = frame }
        set(frame: target, on: window)
    }

    /// Pure geometry (unit-testable): where `action` puts a window inside `area` (top-left origin).
    static func rect(for action: String, in a: CGRect, current: CGRect) -> CGRect? {
        let w = a.width, h = a.height
        switch action {
        case "left": return CGRect(x: a.minX, y: a.minY, width: w / 2, height: h)
        case "right": return CGRect(x: a.minX + w / 2, y: a.minY, width: w / 2, height: h)
        case "top": return CGRect(x: a.minX, y: a.minY, width: w, height: h / 2)
        case "bottom": return CGRect(x: a.minX, y: a.minY + h / 2, width: w, height: h / 2)
        case "topLeft": return CGRect(x: a.minX, y: a.minY, width: w / 2, height: h / 2)
        case "topRight": return CGRect(x: a.minX + w / 2, y: a.minY, width: w / 2, height: h / 2)
        case "bottomLeft": return CGRect(x: a.minX, y: a.minY + h / 2, width: w / 2, height: h / 2)
        case "bottomRight": return CGRect(x: a.minX + w / 2, y: a.minY + h / 2, width: w / 2, height: h / 2)
        case "leftThird": return CGRect(x: a.minX, y: a.minY, width: w / 3, height: h)
        case "centerThird": return CGRect(x: a.minX + w / 3, y: a.minY, width: w / 3, height: h)
        case "rightThird": return CGRect(x: a.minX + 2 * w / 3, y: a.minY, width: w / 3, height: h)
        case "leftTwoThirds": return CGRect(x: a.minX, y: a.minY, width: 2 * w / 3, height: h)
        case "rightTwoThirds": return CGRect(x: a.minX + w / 3, y: a.minY, width: 2 * w / 3, height: h)
        case "max": return a
        case "almostMax": return a.insetBy(dx: w * 0.05, dy: h * 0.05)
        case "center":
            let cw = min(current.width, w), ch = min(current.height, h)
            return CGRect(x: a.midX - cw / 2, y: a.midY - ch / 2, width: cw, height: ch)
        default: return nil
        }
    }

    // MARK: Accessibility plumbing

    static func frame(of window: AXUIElement) -> CGRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let p = value,
              AXValueGetValue(p as! AXValue, .cgPoint, &pos) else { return nil }
        value = nil
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success, let s = value,
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    static func set(frame: CGRect, on window: AXUIElement) {
        var origin = frame.origin, size = frame.size
        // size → position → size: apps clamp the size to the screen they are currently on.
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
    }

    private static func toggleFullscreen(_ window: AXUIElement) {
        var value: CFTypeRef?
        let attr = "AXFullScreen" as CFString
        let current = AXUIElementCopyAttributeValue(window, attr, &value) == .success && (value as? Bool) == true
        AXUIElementSetAttributeValue(window, attr, (!current) as CFBoolean)
    }

    /// Screens in Accessibility coordinates (origin top-left of the primary display).
    private static func screensInAXSpace() -> [(frame: CGRect, visible: CGRect)] {
        guard let primary = NSScreen.screens.first else { return [] }
        let H = primary.frame.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { (frame: flip($0.frame), visible: flip($0.visibleFrame)) }
    }
}
