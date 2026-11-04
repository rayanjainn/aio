import AppKit
import ApplicationServices

/// Named arrangements of your windows: save the current one, bring it back with one command.
enum WindowLayouts {
    struct Entry: Codable { var bundle: String; var title: String; var x: Double; var y: Double; var w: Double; var h: Double }
    typealias Store = [String: [Entry]]

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/layouts.json")
    }

    static func all() -> Store {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Store.self, from: data) else { return [:] }
        return s
    }

    private static func write(_ s: Store) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    static func names() -> [String] { all().keys.sorted() }

    private static func windows(of app: NSRunningApplication) -> [(AXUIElement, String, CGRect)] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success, let list = value as? [AXUIElement] else { return [] }
        return list.compactMap { w in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &role)
            guard (role as? String) == (kAXStandardWindowSubrole as String), let f = WindowManager.frame(of: w), f.width > 100 else { return nil }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return (w, (t as? String) ?? "", f)
        }
    }

    @discardableResult
    static func save(_ name: String) -> Int {
        guard WindowManager.isTrusted else { WindowManager.requestAccess(); return 0 }
        var entries: [Entry] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier else { continue }
            for (_, title, f) in windows(of: app) {
                entries.append(Entry(bundle: bundle, title: title, x: f.minX, y: f.minY, w: f.width, h: f.height))
            }
        }
        var s = all()
        s[name] = entries
        write(s)
        Log.info("layout: saved '\(name)' with \(entries.count) windows")
        return entries.count
    }

    static func restore(_ name: String) {
        guard WindowManager.isTrusted else { WindowManager.requestAccess(); return }
        guard let entries = all()[name] else { return }
        var used = Set<String>()
        for e in entries {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: e.bundle).first else { continue }
            let wins = windows(of: app)
            let match = wins.enumerated().first { !used.contains("\(e.bundle)#\($0.offset)") && $0.element.1 == e.title }
                ?? wins.enumerated().first { !used.contains("\(e.bundle)#\($0.offset)") }
            guard let m = match else { continue }
            used.insert("\(e.bundle)#\(m.offset)")
            WindowManager.set(frame: CGRect(x: e.x, y: e.y, width: e.w, height: e.h), on: m.element.0)
        }
    }

    static func delete(_ name: String) {
        var s = all(); s[name] = nil; write(s)
    }
}
