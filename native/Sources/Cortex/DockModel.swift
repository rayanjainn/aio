import AppKit
import Combine

struct DockItem: Identifiable, Equatable {
    enum Kind: String, Codable { case app, folder, trash, widget }
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
    @Published var iconSize: CGFloat = 44
    @Published var hovering = false
    @Published var magnify = true
    @Published var edge = "bottom"
    @Published var darken = 0.0
    @Published private(set) var launching: Set<String> = []
    @Published var hoveredID: String?
    /// Set by the app so widgets can show live data.
    var bridge: MediaRemoteBridge?
    var power: PowerMonitor?
    @Published var pointer: CGFloat?          // along the bar's axis, from the start of the content

    /// Pointer from the window's own tracking area: `along` is measured from the content start,
    /// `across` is the distance from the screen edge the Dock sits on.
    func pointerMoved(along: CGFloat?, across: CGFloat) {
        guard let along, across <= barAcross + 6, draggingID == nil else {
            if pointer != nil { pointer = nil }
            if hoveredID != nil { hoveredID = nil }
            return
        }
        pointer = along
        var found: String?
        for (i, s) in slots.enumerated() {
            guard case .item(let item) = s else { continue }
            if abs(along - centre(ofSlot: i)) <= length(of: item) / 2 + Self.gap / 2 { found = item.id; break }
        }
        if found != hoveredID {
            hoveredID = found
            if found != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }
    @Published var previewHovering = false
    @Published var draggingID: String?

    static var maxScale: CGFloat { CGFloat(Prefs.shared.dockMagnification) }
    static var gap: CGFloat { CGFloat(Prefs.shared.dockSpacing) }
    static let padding: CGFloat = 9
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
        p.$dockShowRunning.dropFirst().sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // Layout-affecting options: the @Published values change just after the sink fires, so hop a turn.
        p.$dockMagnification.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &cancellables)
        p.$dockSpacing.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &cancellables)
        p.$dockRoundness.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &cancellables)
        p.$dockIndicators.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &cancellables)
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
            case .widget:
                guard let kind = DockWidgetKind.find(e.value) else { continue }
                pinned.append(DockItem(id: "widget:" + e.value, kind: .widget, value: e.value, name: kind.title, url: URL(fileURLWithPath: "/")))
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
        if Prefs.shared.dockShowRunning, !extra.isEmpty { list.append(.divider(1)); list += extra.map { .item(applyBadge($0)) } }
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

    private static var customIconsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/icons.json")
    }

    private lazy var customIcons: [String: String] = {
        guard let d = try? Data(contentsOf: Self.customIconsURL), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }()

    func hasCustomIcon(_ item: DockItem) -> Bool { customIcons[item.id] != nil }

    /// Pick an image (png, icns, jpg…) to use instead of an item's own icon.
    func chooseIcon(for item: DockItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an icon for \(item.name)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Keep a private copy so moving the original never breaks the Dock.
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "_") + "." + url.pathExtension)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
        customIcons[item.id] = dest.path
        saveCustomIcons()
    }

    func resetIcon(for item: DockItem) {
        if let p = customIcons[item.id] { try? FileManager.default.removeItem(atPath: p) }
        customIcons[item.id] = nil
        saveCustomIcons()
    }

    private func saveCustomIcons() {
        if let d = try? JSONEncoder().encode(customIcons) { try? d.write(to: Self.customIconsURL, options: .atomic) }
        icons.removeAll()
        objectWillChange.send()
        refresh()
    }

    func icon(for item: DockItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        if let path = customIcons[item.id], let custom = NSImage(contentsOfFile: path) {
            custom.size = NSSize(width: 128, height: 128)
            icons[item.id] = custom
            return custom
        }
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
        case .widget:
            break
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

    /// Length an item takes along the bar: icons are square, widgets are wider on a horizontal Dock.
    func length(of item: DockItem) -> CGFloat {
        guard item.kind == .widget, !isVertical, let k = DockWidgetKind.find(item.value) else { return iconSize }
        return iconSize * k.span
    }

    func hasWidget(_ id: String) -> Bool { entries.contains { $0.kind == .widget && $0.value == id } }

    func addWidget(_ id: String) {
        guard !hasWidget(id), DockWidgetKind.find(id) != nil else { return }
        // Widgets go before the trailing folder/Downloads entries so they sit with the apps.
        let at = entries.lastIndex(where: { $0.kind == .app }).map { $0 + 1 } ?? entries.count
        entries.insert(Entry(kind: .widget, value: id), at: at)
        save(); refresh()
    }

    func removeWidget(_ id: String) {
        entries.removeAll { $0.kind == .widget && $0.value == id }
        save(); refresh()
    }

    /// Length of the bar along its axis, without padding.
    var contentLength: CGFloat {
        var total: CGFloat = 0
        for (i, s) in slots.enumerated() {
            if i > 0 { total += Self.gap }
            switch s {
            case .item(let it): total += length(of: it)
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
            case .item(let it): w = length(of: it)
            case .divider: w = Self.dividerLength
            }
            if i == index { return x + w / 2 }
            x += w + Self.gap
        }
        return x
    }
}
