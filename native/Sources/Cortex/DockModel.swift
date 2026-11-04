import AppKit
import Combine

struct DockItem: Identifiable, Equatable {
    enum Kind: String, Codable { case app, folder, trash }
    let id: String            // "app:<bundle id>", "folder:<path>", "trash"
    let kind: Kind
    var value: String         // bundle id or path
    var name: String
    var url: URL
    var running = false
    var pinned = true
    var badge: String?
    var pid: pid_t?
}

enum DockSlot: Identifiable, Equatable {
    case item(DockItem)
    case divider(Int)
    var id: String {
        switch self {
        case .item(let i): i.id
        case .divider(let n): "divider-\(n)"
        }
    }
}

/// Pinned apps and folders (saved in ~/.cortex/native/dock.json), then every other running app, then the Trash.
@MainActor
final class DockModel: ObservableObject {
    @Published private(set) var slots: [DockSlot] = []
    @Published var iconSize: CGFloat = 54
    @Published var hovering = false
    @Published var magnify = true
    @Published var edge = "bottom"
    @Published var darken = 0.0
    @Published private(set) var launching: Set<String> = []
    @Published var hoveredID: String?
    @Published var previewHovering = false
    @Published var draggingID: String?

    static let maxScale: CGFloat = 1.55
    static let gap: CGFloat = 10
    static let padding: CGFloat = 12
    static let sideMargin: CGFloat = 30
    static let dividerLength: CGFloat = 12
    static let dotArea: CGFloat = 9

    struct Entry: Codable, Equatable { var kind: DockItem.Kind; var value: String }

    private(set) var entries: [Entry]
    private var icons: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var badges: [String: String] = [:]
    private var badgeTimer: Timer?

    private static let defaultApps = [
        "com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.Music",
        "com.apple.iCal", "com.apple.Notes", "com.apple.Terminal", "com.apple.systempreferences",
    ]

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/dock.json")
    }

    init() {
        entries = Self.loadEntries()
        let p = Prefs.shared
        iconSize = CGFloat(p.dockIconSize); magnify = p.dockMagnify; edge = p.dockEdge; darken = p.dockDarken
        p.$dockIconSize.dropFirst().sink { [weak self] in self?.iconSize = CGFloat($0) }.store(in: &cancellables)
        p.$dockMagnify.dropFirst().sink { [weak self] in self?.magnify = $0 }.store(in: &cancellables)
        p.$dockEdge.dropFirst().sink { [weak self] in self?.edge = $0 }.store(in: &cancellables)
        p.$dockDarken.dropFirst().sink { [weak self] in self?.darken = $0 }.store(in: &cancellables)
        p.$dockShowTrash.dropFirst().sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            })
        }
    }

    private static func loadEntries() -> [Entry] {
        if let data = try? Data(contentsOf: configURL) {
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let list = obj["entries"] as? [[String: String]] {
                    let parsed = list.compactMap { d -> Entry? in
                        guard let k = d["kind"], let kind = DockItem.Kind(rawValue: k), let v = d["value"] else { return nil }
                        return Entry(kind: kind, value: v)
                    }
                    if !parsed.isEmpty { return parsed }
                }
                if let old = obj["pinned"] as? [String] { return old.map { Entry(kind: .app, value: $0) } + [defaultDownloads] }
            }
        }
        return defaultApps.map { Entry(kind: .app, value: $0) } + [defaultDownloads]
    }

    private static var defaultDownloads: Entry {
        Entry(kind: .folder, value: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path)
    }

    func save() {
        let url = Self.configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let list = entries.map { ["kind": $0.kind.rawValue, "value": $0.value] }
        if let data = try? JSONSerialization.data(withJSONObject: ["entries": list], options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: items

    func refresh() {
        let selfID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != selfID }
        var byID: [String: NSRunningApplication] = [:]
        for app in running { if let id = app.bundleIdentifier { byID[id] = app } }

        var pinned: [DockItem] = []
        for e in entries {
            switch e.kind {
            case .app:
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.value) else { continue }
                let app = byID[e.value]
                pinned.append(DockItem(id: "app:" + e.value, kind: .app, value: e.value, name: Self.name(of: url), url: url,
                                       running: app != nil, pinned: true, badge: nil, pid: app?.processIdentifier))
            case .folder:
                let url = URL(fileURLWithPath: e.value)
                guard FileManager.default.fileExists(atPath: e.value) else { continue }
                pinned.append(DockItem(id: "folder:" + e.value, kind: .folder, value: e.value, name: url.lastPathComponent, url: url))
            case .trash: break
            }
        }
        let pinnedIDs = Set(entries.filter { $0.kind == .app }.map(\.value))
        var extra: [DockItem] = []
        for app in running {
            guard let id = app.bundleIdentifier, !pinnedIDs.contains(id), let url = app.bundleURL else { continue }
            extra.append(DockItem(id: "app:" + id, kind: .app, value: id, name: app.localizedName ?? Self.name(of: url), url: url,
                                  running: true, pinned: false, badge: nil, pid: app.processIdentifier))
        }
        for item in pinned where item.running { launching.remove(item.id) }
        for item in extra { launching.remove(item.id) }

        var list: [DockSlot] = pinned.map { .item(applyBadge($0)) }
        if !extra.isEmpty { list.append(.divider(1)); list += extra.map { .item(applyBadge($0)) } }
        if Prefs.shared.dockShowTrash {
            list.append(.divider(2))
            list.append(.item(DockItem(id: "trash", kind: .trash, value: "", name: "Trash",
                                       url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))))
        }
        if list != slots { slots = list }
    }

    private func applyBadge(_ item: DockItem) -> DockItem {
        var i = item
        i.badge = badges[item.name]
        return i
    }

    private static func name(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var items: [DockItem] { slots.compactMap { if case .item(let i) = $0 { return i } else { return nil } } }

    func item(withID id: String) -> DockItem? { items.first(where: { $0.id == id }) }

    func startBadgePolling() {
        guard badgeTimer == nil else { return }
        pollBadges()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollBadges() }
        }
    }

    func stopBadgePolling() { badgeTimer?.invalidate(); badgeTimer = nil }

    private func pollBadges() {
        Task.detached {
            let found = WindowService.dockBadges()
            await MainActor.run { [weak self] in
                guard let self, found != self.badges else { return }
                self.badges = found
                self.refresh()
            }
        }
    }

    // MARK: icons

    func icon(for item: DockItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let image: NSImage
        switch item.kind {
        case .trash:
            image = NSImage(named: NSImage.trashEmptyName) ?? NSWorkspace.shared.icon(forFile: item.url.path)
        default:
            image = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        image.size = NSSize(width: 128, height: 128)
        icons[item.id] = image
        return image
    }

    // MARK: actions

    func activate(_ item: DockItem) {
        switch item.kind {
        case .app:
            if !item.running {
                launching.insert(item.id)
                let id = item.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    self?.launching.remove(id)
                }
            }
            NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Log.warn("dock: could not open \(item.id): \(error.localizedDescription)") }
            }
        case .folder, .trash:
            NSWorkspace.shared.open(item.url)
        }
    }

    func quit(_ item: DockItem) { NSRunningApplication.runningApplications(withBundleIdentifier: item.value).forEach { $0.terminate() } }
    func forceQuit(_ item: DockItem) { NSRunningApplication.runningApplications(withBundleIdentifier: item.value).forEach { $0.forceTerminate() } }
    func hide(_ item: DockItem) { NSRunningApplication.runningApplications(withBundleIdentifier: item.value).forEach { $0.hide() } }
    func reveal(_ item: DockItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func pin(_ item: DockItem) {
        guard !entries.contains(where: { $0.value == item.value && $0.kind == item.kind }) else { return }
        entries.append(Entry(kind: item.kind, value: item.value))
        save(); refresh()
    }

    func unpin(_ item: DockItem) {
        entries.removeAll { $0.value == item.value && $0.kind == item.kind }
        save(); refresh()
    }

    func addFolder(_ url: URL) {
        guard !entries.contains(where: { $0.value == url.path }) else { return }
        entries.append(Entry(kind: .folder, value: url.path))
        save(); refresh()
    }

    /// Moves `id` to position `index` among the visible items; pinned order follows.
    func move(_ id: String, toItemIndex index: Int) {
        var visible = items.filter { $0.kind != .trash }
        guard let from = visible.firstIndex(where: { $0.id == id }) else { return }
        let moved = visible.remove(at: from)
        visible.insert(moved, at: max(0, min(index, visible.count)))
        entries = visible.filter { $0.pinned || $0.id == id }.map { Entry(kind: $0.kind, value: $0.value) }
        save(); refresh()
    }

    func open(_ urls: [URL], with item: DockItem) {
        guard item.kind == .app else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: item.url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: geometry

    var isVertical: Bool { edge == "left" || edge == "right" }

    /// Length of the bar along its axis, without padding.
    var contentLength: CGFloat {
        var total: CGFloat = 0
        for (i, s) in slots.enumerated() {
            if i > 0 { total += Self.gap }
            switch s {
            case .item: total += iconSize
            case .divider: total += Self.dividerLength
            }
        }
        return max(total, iconSize)
    }

    var barAlong: CGFloat { contentLength + Self.padding * 2 }
    var barAcross: CGFloat { iconSize + Self.dotArea + Self.padding * 2 }
    var headroom: CGFloat { iconSize * (Self.maxScale - 1) + 10 }

    /// Resting centre of the slot at `index`, along the bar's axis, measured from the start of the content.
    func centre(ofSlot index: Int) -> CGFloat {
        var x: CGFloat = 0
        for (i, s) in slots.enumerated() {
            let w: CGFloat
            switch s {
            case .item: w = iconSize
            case .divider: w = Self.dividerLength
            }
            if i == index { return x + w / 2 }
            x += w + Self.gap
        }
        return x
    }
}
