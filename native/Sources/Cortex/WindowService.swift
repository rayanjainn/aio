import AppKit
import ApplicationServices
import ScreenCaptureKit

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    var appName: String
    var frame: CGRect
    var minimized = false
    var thumbnail: NSImage?
    var key: String { "\(pid)-\(id)-\(title)" }
}

/// Maps an Accessibility window to its CGWindowID (a long-standing private SPI used by every window switcher).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WindowService {
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: Accessibility helpers

    static func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func boolAttr(_ el: AXUIElement, _ name: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    private static func axWindowElements(pid: pid_t) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v) == .success,
              let list = v as? [AXUIElement] else { return [] }
        return list
    }

    // MARK: listing

    /// The windows of one app. With Screen Recording permission they carry live thumbnails;
    /// without it Cortex still lists them (titles come from Accessibility).
    static func windows(forPID pid: pid_t, thumbnails: Bool = true, onScreenOnly: Bool = true) async -> [WindowInfo] {
        if canCapture, let list = try? await captured(pid: pid, thumbnails: thumbnails, onScreenOnly: onScreenOnly), !list.isEmpty {
            return list
        }
        return accessibilityWindows(pid: pid)
    }

    private static func captured(pid: pid_t, thumbnails: Bool, onScreenOnly: Bool) async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenOnly)
        let wins = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 80
        }
        var out: [WindowInfo] = []
        for w in wins.prefix(10) {
            var image: NSImage?
            if thumbnails {
                let cfg = SCStreamConfiguration()
                let scale = min(1, 360 / max(w.frame.width, 1))
                cfg.width = max(2, Int(w.frame.width * scale * 2))
                cfg.height = max(2, Int(w.frame.height * scale * 2))
                cfg.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) {
                    image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
                }
            }
            out.append(WindowInfo(id: w.windowID, pid: pid, title: w.title ?? "", appName: w.owningApplication?.applicationName ?? "",
                                  frame: w.frame, thumbnail: image))
        }
        return out
    }

    static func accessibilityWindows(pid: pid_t) -> [WindowInfo] {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        return axWindowElements(pid: pid).compactMap { el in
            if let role = stringAttr(el, kAXSubroleAttribute as String), role != "AXStandardWindow" && role != "AXDialog" { return nil }
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(el, &wid)
            return WindowInfo(id: wid, pid: pid, title: stringAttr(el, kAXTitleAttribute as String) ?? "", appName: name, frame: .zero,
                              minimized: boolAttr(el, kAXMinimizedAttribute as String) ?? false, thumbnail: nil)
        }
    }

    /// Every window of every regular app (for the window switcher).
    static func allWindows() async -> [WindowInfo] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        return await withTaskGroup(of: [WindowInfo].self) { group in
            for app in apps { group.addTask { await windows(forPID: app.processIdentifier, thumbnails: true, onScreenOnly: false) } }
            var all: [WindowInfo] = []
            for await list in group { all += list }
            return all
        }
    }

    // MARK: acting

    static func raise(_ window: WindowInfo) {
        for el in axWindowElements(pid: window.pid) {
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(el, &wid)
            let match = (window.id != 0 && wid == window.id) || (window.id == 0 && stringAttr(el, kAXTitleAttribute as String) == window.title)
            guard match else { continue }
            if boolAttr(el, kAXMinimizedAttribute as String) == true {
                AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, false as CFBoolean)
            }
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            break
        }
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    static func close(_ window: WindowInfo) {
        for el in axWindowElements(pid: window.pid) {
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(el, &wid)
            guard (window.id != 0 && wid == window.id) || stringAttr(el, kAXTitleAttribute as String) == window.title else { continue }
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &button) == .success, let b = button {
                AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
            }
            break
        }
    }

    // MARK: Dock badges

    /// Badge text of the macOS Dock's items ("3", "•"), keyed by item title — read from the Dock's accessibility tree.
    static func dockBadges() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        var result: [String: String] = [:]
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 4 else { return }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
                  let kids = children as? [AXUIElement] else { return }
            for k in kids {
                if stringAttr(k, kAXRoleAttribute as String) == "AXDockItem" {
                    if let title = stringAttr(k, kAXTitleAttribute as String), let status = stringAttr(k, "AXStatusLabel"), !status.isEmpty {
                        result[title] = status
                    }
                } else {
                    walk(k, depth: depth + 1)
                }
            }
        }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        walk(root, depth: 0)
        return result
    }
}
