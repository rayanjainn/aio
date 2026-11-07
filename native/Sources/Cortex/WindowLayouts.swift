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
        saveTabs(name)
        Log.info("layout: saved '\(name)' with \(entries.count) windows")
        return entries.count
    }

    static func restore(_ name: String) {
        guard WindowManager.isTrusted else { WindowManager.requestAccess(); return }
        restoreTabs(name)
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

    // MARK: browser tabs, saved alongside the windows

    private static var tabsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/layout-tabs.json")
    }

    private static func allTabs() -> [String: [String: [String]]] {
        guard let d = try? Data(contentsOf: tabsURL), let s = try? JSONDecoder().decode([String: [String: [String]]].self, from: d) else { return [:] }
        return s
    }

    /// Off the main thread: asks each running browser for its tabs.
    static func saveTabs(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var byBrowser: [String: [String]] = [:]
            for t in BrowserTabs.list() where !t.url.isEmpty { byBrowser[t.bundle, default: []].append(t.url) }
            var s = allTabs()
            s[name] = byBrowser
            if let d = try? JSONEncoder().encode(s) { try? d.write(to: tabsURL, options: .atomic) }
        }
    }

    /// Reopens tabs from the snapshot that are not open already.
    static func restoreTabs(_ name: String) {
        guard let saved = allTabs()[name], !saved.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let open = Set(BrowserTabs.list().map(\.url))
            for (bundle, urls) in saved {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { continue }
                let missing = urls.filter { !open.contains($0) }.compactMap(URL.init(string:))
                guard !missing.isEmpty else { continue }
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(missing, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            }
        }
    }

    static func delete(_ name: String) {
        var s = all(); s[name] = nil; write(s)
    }
}
