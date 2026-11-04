import AppKit
import Combine

struct DockItem: Identifiable, Equatable {
    let id: String          // bundle identifier
    var name: String
    var url: URL
    var running: Bool
    var pinned: Bool
}

/// Pinned apps (from ~/.cortex/native/dock.json) followed by every other running app.
@MainActor
final class DockModel: ObservableObject {
    @Published private(set) var items: [DockItem] = []
    @Published var iconSize: CGFloat = 54
    @Published var hovering = false

    static let maxScale: CGFloat = 1.55
    static let gap: CGFloat = 10
    static let padding: CGFloat = 12
    static let sideMargin: CGFloat = 28

    private var pinned: [String]
    private var icons: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []

    private static let defaults = [
        "com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.Music",
        "com.apple.iCal", "com.apple.Notes", "com.apple.Terminal", "com.apple.systempreferences",
    ]

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/dock.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.configURL),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            pinned = cfg.pinned
            iconSize = CGFloat(cfg.iconSize)
        } else {
            pinned = Self.defaults
        }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            })
        }
    }

    private struct Config: Codable { var pinned: [String]; var iconSize: Double }

    func save() {
        let url = Self.configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Config(pinned: pinned, iconSize: Double(iconSize))) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func refresh() {
        let selfID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != selfID
        }
        var byID: [String: NSRunningApplication] = [:]
        for app in running { if let id = app.bundleIdentifier { byID[id] = app } }

        var result: [DockItem] = []
        for id in pinned {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            result.append(DockItem(id: id, name: Self.name(of: url), url: url, running: byID[id] != nil, pinned: true))
        }
        for app in running {
            guard let id = app.bundleIdentifier, !pinned.contains(id), let url = app.bundleURL else { continue }
            result.append(DockItem(id: id, name: app.localizedName ?? Self.name(of: url), url: url, running: true, pinned: false))
        }
        if result != items { items = result }
    }

    private static func name(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func icon(for item: DockItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        image.size = NSSize(width: 128, height: 128)
        icons[item.id] = image
        return image
    }

    func activate(_ item: DockItem) {
        // Launches the app, or brings it forward if it's already running.
        NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.warn("dock: could not open \(item.id): \(error.localizedDescription)") }
        }
    }

    // MARK: geometry

    /// Width of the bar (without the side margin the magnified icons need).
    var barWidth: CGFloat {
        let n = CGFloat(max(items.count, 1))
        return n * iconSize + (n - 1) * Self.gap + Self.padding * 2
    }
    var barHeight: CGFloat { iconSize + Self.padding * 2 }
    var headroom: CGFloat { iconSize * (Self.maxScale - 1) + 8 }
}
