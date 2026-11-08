import AppKit
import SwiftUI
import Combine

// MARK: - Data

struct LauncherApp: Identifiable, Hashable {
    let path: String
    let name: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

struct LauncherFolder: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var apps: [String]          // app paths
}

/// Your launcher layout: folders, hidden apps, renamed apps. Saved to ~/.cortex/native/launcher.json.
struct LauncherLayout: Codable, Equatable {
    var folders: [LauncherFolder] = []
    var hidden: [String] = []
    var names: [String: String] = [:]
}

/// Every app on the Mac, grouped by your folders, filtered by search.
@MainActor
final class LauncherStore: ObservableObject {
    @Published private(set) var apps: [LauncherApp] = []
    @Published var layout = LauncherLayout() { didSet { if layout != oldValue { save() } } }
    @Published var query = ""
    @Published var openFolder: String?
    @Published var showHidden = false
    /// False while the launcher is closed: its view renders nothing, so no animation or timer runs behind the scenes.
    @Published var visible = false

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/launcher.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.url), let l = try? JSONDecoder().decode(LauncherLayout.self, from: d) { layout = l }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(layout) { try? d.write(to: Self.url, options: .atomic) }
    }

    /// Scans the usual app folders off the main thread.
    func reload() {
        Task.detached(priority: .userInitiated) {
            let found = LauncherStore.scan()
            // Decode every icon here, off the main thread, so scrolling and opening never stall on them.
            var icons: [String: NSImage] = [:]
            for app in found {
                let img = NSWorkspace.shared.icon(forFile: app.path)
                img.size = NSSize(width: 128, height: 128)
                icons[app.path] = img
            }
            let ready = icons
            await MainActor.run {
                LauncherIcons.cache.merge(ready) { _, new in new }
                if self.apps != found { self.apps = found }
            }
        }
    }

    nonisolated static func scan() -> [LauncherApp] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var out: [LauncherApp] = []
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
                let path = root + "/" + name
                let display = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                guard seen.insert(display.lowercased()).inserted else { continue }
                out.append(LauncherApp(path: path, name: display))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func name(of app: LauncherApp) -> String { layout.names[app.path] ?? app.name }

    private var inFolders: Set<String> { Set(layout.folders.flatMap(\.apps)) }

    /// Searching shows every match flat; otherwise folders first, then loose apps.
    var searchResults: [LauncherApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return apps.filter { (showHidden || !layout.hidden.contains($0.path)) && name(of: $0).lowercased().contains(q) }
            .sorted { a, b in
                let ap = name(of: a).lowercased().hasPrefix(q), bp = name(of: b).lowercased().hasPrefix(q)
                return ap != bp ? ap : name(of: a) < name(of: b)
            }
    }

    var looseApps: [LauncherApp] {
        let folded = inFolders
        return apps.filter { !folded.contains($0.path) && (showHidden || !layout.hidden.contains($0.path)) }
    }

    func apps(in folder: LauncherFolder) -> [LauncherApp] {
        folder.apps.compactMap { p in apps.first { $0.path == p } }
    }

    func launch(_ app: LauncherApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: editing

    func toggleHidden(_ app: LauncherApp) {
        if let i = layout.hidden.firstIndex(of: app.path) { layout.hidden.remove(at: i) } else { layout.hidden.append(app.path) }
    }

    func add(_ app: LauncherApp, toFolder id: String) {
        for i in layout.folders.indices { layout.folders[i].apps.removeAll { $0 == app.path } }
        if let i = layout.folders.firstIndex(where: { $0.id == id }) { layout.folders[i].apps.append(app.path) }
        layout.folders.removeAll { $0.apps.isEmpty }
    }

    func newFolder(with app: LauncherApp, named name: String) {
        for i in layout.folders.indices { layout.folders[i].apps.removeAll { $0 == app.path } }
        layout.folders.removeAll { $0.apps.isEmpty }
        layout.folders.append(LauncherFolder(name: name, apps: [app.path]))
    }

    func removeFromFolder(_ app: LauncherApp) {
        for i in layout.folders.indices { layout.folders[i].apps.removeAll { $0 == app.path } }
        layout.folders.removeAll { $0.apps.isEmpty }
    }

    func rename(folder id: String, to name: String) {
        if let i = layout.folders.firstIndex(where: { $0.id == id }) { layout.folders[i].name = name }
    }

    /// Groups apps into folders by their App Store category, the way Launchpad's first layout did.
    func autoGroup() {
        var groups: [String: [String]] = [:]
        for app in apps {
            guard let info = Bundle(url: app.url)?.infoDictionary,
                  let cat = info["LSApplicationCategoryType"] as? String else { continue }
            groups[Self.categoryName(cat), default: []].append(app.path)
        }
        layout.folders = groups.filter { $0.value.count >= 2 }.sorted { $0.key < $1.key }
            .map { LauncherFolder(name: $0.key, apps: $0.value) }
    }

    /// "public.app-category.graphics-design" → "Graphics & Design"; unknown or blank → "Other".
    static func categoryName(_ raw: String) -> String {
        let key = raw.replacingOccurrences(of: "public.app-category.", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        let names = ["developer-tools": "Developer Tools", "graphics-design": "Graphics & Design", "social-networking": "Social",
                     "productivity": "Productivity", "utilities": "Utilities", "music": "Music", "video": "Video",
                     "entertainment": "Entertainment", "education": "Education", "reference": "Reference", "games": "Games",
                     "business": "Business", "finance": "Finance", "photography": "Photos", "news": "News",
                     "lifestyle": "Lifestyle", "health-fitness": "Health", "travel": "Travel", "weather": "Weather"]
        if let n = names[key] { return n }
        if key.hasSuffix("-games") { return "Games" }
        let words = key.split(separator: "-").map { $0.capitalized }
        return words.isEmpty ? "Other" : words.joined(separator: " ")
    }

    func resetLayout() { layout.folders = [] }

    /// Moves the app to the Trash together with its settings, caches and support files (all restorable from the Trash).
    func uninstall(_ app: LauncherApp) {
        let bundleID = Bundle(url: app.url)?.bundleIdentifier
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var leftovers: [URL] = []
        if let id = bundleID {
            for rel in ["Preferences/\(id).plist", "Caches/\(id)", "Application Support/\(id)", "Containers/\(id)",
                        "Saved Application State/\(id).savedState", "HTTPStorages/\(id)", "WebKit/\(id)", "Logs/\(id)"] {
                let u = home.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: u.path) { leftovers.append(u) }
            }
        }
        let support = home.appendingPathComponent("Application Support/\(app.name)")
        if FileManager.default.fileExists(atPath: support.path) { leftovers.append(support) }

        let alert = NSAlert()
        alert.messageText = "Move \(app.name) to the Trash?"
        alert.informativeText = leftovers.isEmpty
            ? "The app goes to the Trash; you can put it back from there."
            : "The app and \(leftovers.count) related item\(leftovers.count == 1 ? "" : "s") (settings, caches, support files) go to the Trash; you can put them back from there."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.window.level = LauncherController.dialogLevel
        NSApp.activate(ignoringOtherApps: true)
        let go = alert.runModal() == .alertFirstButtonReturn
        NotificationCenter.default.post(name: .launcherRefocus, object: nil)
        guard go else { return }
        NSWorkspace.shared.recycle([app.url] + leftovers) { _, error in
            if let error { Toast.show("exclamationmark.triangle", error.localizedDescription) }
            else { Toast.show("trash", "\(app.name) moved to the Trash") }
            Task { @MainActor in self.reload() }
        }
    }
}

/// Launcher icons, decoded in the background (see `LauncherStore.reload`).
@MainActor
enum LauncherIcons {
    static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage { cache[path] ?? IconCache.icon(forPath: path) }
}

// MARK: - Window

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A full-screen app launcher, like Launchpad: opened with a shortcut, a hot corner or the menu bar.
@MainActor
final class LauncherController {
    let store = LauncherStore()
    private var panel: LauncherPanel?
    private var cornerMonitor: Any?
    private var cornerSince: Date?
    private var keyMonitor: Any?
    weak var bridge: MediaRemoteBridge?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Dialogs opened from the launcher (rename, uninstall) sit above it.
    static let dialogLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let panel = self.panel ?? build()
        store.query = ""
        store.openFolder = nil
        store.visible = true
        store.reload()
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        NotificationCenter.default.post(name: .launcherShown, object: nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.store.visible = false
        })
    }

    private func build() -> LauncherPanel {
        let p = LauncherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        let view = LauncherView(store: store, bridge: bridge, onClose: { [weak self] in self?.hide() })
        NotificationCenter.default.addObserver(forName: .launcherRefocus, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { if let p = self?.panel, p.isVisible { p.makeKeyAndOrderFront(nil) } }
        }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        p.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            // A rename / uninstall dialog takes focus: keep the launcher open behind it, and take focus back after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if NSApp.modalWindow != nil || (NSApp.keyWindow?.level.rawValue ?? 0) == LauncherController.dialogLevel.rawValue { return }
                self?.hide()
            }
        }
        panel = p
        return p
    }

    /// Opens the launcher when the pointer rests in the chosen screen corner.
    func configureHotCorner() {
        if let m = cornerMonitor { NSEvent.removeMonitor(m); cornerMonitor = nil }
        let corner = Prefs.shared.launcherHotCorner
        guard corner != "none" else { return }
        cornerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.checkCorner(corner) }
        }
    }

    private func checkCorner(_ corner: String) {
        let p = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return }
        let f = s.frame, edge: CGFloat = 3
        let hit: Bool
        switch corner {
        case "topLeft": hit = p.x <= f.minX + edge && p.y >= f.maxY - edge
        case "topRight": hit = p.x >= f.maxX - edge && p.y >= f.maxY - edge
        case "bottomLeft": hit = p.x <= f.minX + edge && p.y <= f.minY + edge
        case "bottomRight": hit = p.x >= f.maxX - edge && p.y <= f.minY + edge
        default: hit = false
        }
        if !hit { cornerSince = nil; return }
        if let since = cornerSince {
            if Date().timeIntervalSince(since) > 0.25, !isVisible { cornerSince = .distantFuture; show() }
        } else {
            cornerSince = Date()
        }
    }
}

extension Notification.Name {
    static let launcherShown = Notification.Name("cortex.launcher.shown")
    static let launcherRefocus = Notification.Name("cortex.launcher.refocus")
}

// MARK: - Views

struct LauncherView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject private var prefs = Prefs.shared
    weak var bridge: MediaRemoteBridge?
    let onClose: () -> Void
    @State private var appeared = false
    @FocusState private var searchFocused: Bool

    private var iconSize: CGFloat { CGFloat(prefs.launcherIconSize) }

    var body: some View {
        if store.visible { content } else { Color.clear }
    }

    private var content: some View {
        ZStack {
            background
                .onTapGesture { if store.openFolder != nil { withAnimation(.spring(response: 0.3)) { store.openFolder = nil } } else { onClose() } }

            VStack(spacing: 22) {
                search
                HStack(alignment: .top, spacing: 28) {
                    if prefs.launcherWidgets { sidebar.frame(width: 210) }
                    grid
                }
            }
            .padding(.horizontal, 70).padding(.top, 70).padding(.bottom, 40)
            .scaleEffect(appeared ? 1 : 1.04)
            .opacity(appeared ? 1 : 0)
            .opacity(store.openFolder == nil ? 1 : 0.25)

            if let id = store.openFolder, let folder = store.layout.folders.first(where: { $0.id == id }) {
                FolderSheet(store: store, folder: folder, iconSize: iconSize, onLaunch: launch)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { animateIn() }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShown)) { _ in animateIn() }
        .onExitCommand {
            if store.openFolder != nil { withAnimation(.spring(response: 0.3)) { store.openFolder = nil } }
            else if !store.query.isEmpty { store.query = "" }
            else { onClose() }
        }
    }

    private func animateIn() {
        appeared = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { appeared = true }
        DispatchQueue.main.async { searchFocused = true }
    }

    private func launch(_ app: LauncherApp) {
        store.launch(app)
        onClose()
    }

    @ViewBuilder private var background: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            if prefs.launcherWallpaper == "music", let bridge {
                LauncherMusicWallpaper(bridge: bridge).transition(.opacity)
            } else if !prefs.launcherWallpaper.isEmpty, let img = NSImage(contentsOfFile: prefs.launcherWallpaper) {
                // Overlay on a clear view so a fill-scaled image never grows the layout past the screen.
                Color.clear.overlay { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).opacity(0.85) }.clipped()
            }
            Color.black.opacity(prefs.launcherDim)
        }
        .ignoresSafeArea()
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            TextField("Search", text: $store.query)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit {
                    if let first = store.searchResults.first { launch(first) }
                }
                .onKeyPress(.escape) {
                    if !store.query.isEmpty { store.query = "" } else { onClose() }
                    return .handled
                }
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).frame(width: 380, height: 36)
        .cortexGlass(in: Capsule(), darken: 0.15)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: iconSize + 34, maximum: iconSize + 60), spacing: 18, alignment: .top)]
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                if !store.query.isEmpty {
                    ForEach(store.searchResults) { app in
                        AppTile(store: store, app: app, iconSize: iconSize, showTitle: prefs.launcherShowTitles, onLaunch: launch)
                    }
                } else {
                    ForEach(store.layout.folders) { folder in
                        FolderTile(store: store, folder: folder, iconSize: iconSize, showTitle: prefs.launcherShowTitles)
                    }
                    ForEach(store.looseApps) { app in
                        AppTile(store: store, app: app, iconSize: iconSize, showTitle: prefs.launcherShowTitles, onLaunch: launch)
                    }
                }
            }
            .padding(.vertical, 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.query)
        }
        .scrollIndicators(.never)
    }

    private var sidebar: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(ctx.date.formatted(.dateTime.weekday(.abbreviated))).foregroundStyle(.red)
                        Text(ctx.date.formatted(.dateTime.month(.abbreviated)))
                    }
                    .font(.system(size: 17, weight: .semibold))
                    Text(ctx.date.formatted(.dateTime.day()))
                        .font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(ctx.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .cortexGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), darken: 0.2)
            }
            if let bridge { LauncherMusicCard(bridge: bridge) }
            LauncherWeatherCard()
            LauncherMonthCard()
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

struct AppTile: View {
    @ObservedObject var store: LauncherStore
    let app: LauncherApp
    let iconSize: CGFloat
    let showTitle: Bool
    let onLaunch: (LauncherApp) -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: LauncherIcons.icon(app.path))
                .resizable().interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .opacity(store.layout.hidden.contains(app.path) ? 0.4 : 1)
            if showTitle {
                Text(store.name(of: app)).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: iconSize + 30)
            }
        }
        .scaleEffect(hover ? 1.07 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onLaunch(app) }
        .contextMenu {
            Button("Open") { onLaunch(app) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Divider()
            Menu("Add to Folder") {
                ForEach(store.layout.folders) { f in Button(f.name) { store.add(app, toFolder: f.id) } }
                Divider()
                Button("New Folder…") {
                    if let name = askName(default: "New Folder") { store.newFolder(with: app, named: name) }
                }
            }
            if store.layout.folders.contains(where: { $0.apps.contains(app.path) }) {
                Button("Remove from Folder") { store.removeFromFolder(app) }
            }
            Button("Rename…") {
                if let name = askName(default: store.name(of: app)) { store.layout.names[app.path] = name.isEmpty ? nil : name }
            }
            Button(store.layout.hidden.contains(app.path) ? "Unhide" : "Hide") { store.toggleHidden(app) }
            Divider()
            Button("Uninstall…", role: .destructive) { store.uninstall(app) }
        }
    }
}

@MainActor
func askName(default value: String) -> String? {
    let alert = NSAlert()
    alert.messageText = "Name"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = value
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    alert.window.level = LauncherController.dialogLevel   // above the full-screen launcher, not behind it
    let ok = alert.runModal() == .alertFirstButtonReturn
    NotificationCenter.default.post(name: .launcherRefocus, object: nil)
    guard ok else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespaces)
}

struct FolderTile: View {
    @ObservedObject var store: LauncherStore
    let folder: LauncherFolder
    let iconSize: CGFloat
    let showTitle: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 7) {
            let apps = store.apps(in: folder).prefix(9)
            let mini = iconSize * 0.25
            let gap = iconSize * 0.045
            // A 3×3 grid laid out from the top-left, like a folder on iPad/Launchpad.
            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<3, id: \.self) { c in
                            let i = r * 3 + c
                            if i < apps.count {
                                Image(nsImage: LauncherIcons.icon(apps[apps.startIndex + i].path)).resizable().interpolation(.high)
                                    .frame(width: mini, height: mini)
                            } else {
                                Color.clear.frame(width: mini, height: mini)
                            }
                        }
                    }
                }
            }
            .frame(width: iconSize, height: iconSize)
            .background(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.09)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
            if showTitle {
                Text(folder.name.isEmpty ? "Other" : folder.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
        }
        .scaleEffect(hover ? 1.07 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { store.openFolder = folder.id } }
        .contextMenu {
            Button("Rename…") { if let n = askName(default: folder.name), !n.isEmpty { store.rename(folder: folder.id, to: n) } }
            Button("Ungroup") { store.layout.folders.removeAll { $0.id == folder.id } }
        }
    }
}

struct FolderSheet: View {
    @ObservedObject var store: LauncherStore
    let folder: LauncherFolder
    let iconSize: CGFloat
    let onLaunch: (LauncherApp) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(folder.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(iconSize + 40), spacing: 16), count: min(5, max(1, store.apps(in: folder).count))), spacing: 20) {
                ForEach(store.apps(in: folder)) { app in
                    AppTile(store: store, app: app, iconSize: iconSize, showTitle: true, onLaunch: onLaunch)
                }
            }
        }
        .padding(30)
        .cortexGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous), darken: 0.25)
        .glassRim(cornerRadius: 34)
        .frame(maxWidth: 820)
    }
}

/// A record peeking out of the top of the card (coloured in the artwork's hue), then the song and controls.
struct LauncherMusicCard: View {
    @ObservedObject var bridge: MediaRemoteBridge
    @State private var tint = Color(white: 0.85)

    var body: some View {
        if let t = bridge.info {
            VStack(spacing: 8) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !t.playing)) { ctx in
                    ColoredRecord(d: 170, tint: tint, label: "\(t.title) • \(t.artist)")
                        .rotationEffect(.degrees(t.playing ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360 : 0))
                }
                .frame(width: 170, height: 170)
                .frame(height: 92, alignment: .bottom)          // only the lower half shows
                .clipped()
                .overlay(alignment: .bottom) {
                    ArtworkView(image: t.artwork, size: 40, radius: 8)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                        .offset(x: 58, y: 8)
                }
                .onTapGesture { NotificationCenter.default.post(name: .openMusicPlayer, object: nil) }
                .help("Open the full-screen player")
                VStack(spacing: 2) {
                    Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(t.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                if t.duration > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let f = min(1, t.position(at: ctx.date) / t.duration)
                        VStack(spacing: 2) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.2))
                                    Capsule().fill(.white.opacity(0.9)).frame(width: max(3, g.size.width * f))
                                }
                            }
                            .frame(height: 3)
                            HStack {
                                Text(clock(t.position(at: ctx.date))); Spacer(); Text(clock(t.duration))
                            }
                            .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                HStack(spacing: 22) {
                    Button { bridge.send(.previous) } label: { Image(systemName: "backward.fill") }
                    Button { bridge.send(.toggle) } label: {
                        Image(systemName: t.playing ? "pause.fill" : "play.fill").font(.system(size: 18)).contentTransition(.symbolEffect(.replace))
                    }
                    Button { bridge.send(.next) } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(PressDipStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 0)
            .cortexGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), darken: 0.2)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onAppear { retint(t.artwork) }
            .onChange(of: t.title) { _, _ in retint(bridge.info?.artwork) }
        }
    }

    private func retint(_ art: NSImage?) {
        guard let art, let c = ArtworkPalette.accent(art) else { return }
        withAnimation(.easeInOut(duration: 0.6)) { tint = Color(nsColor: c) }
    }
}

/// This month at a glance: today circled in red, then the next couple of events.
struct LauncherMonthCard: View {
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let cal = Calendar.current
            let now = ctx.date
            let first = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
            let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
            let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
            let today = cal.component(.day, from: now)
            VStack(alignment: .leading, spacing: 8) {
                Text(now.formatted(.dateTime.month(.abbreviated).year())).font(.system(size: 13, weight: .bold))
                let symbols = Array(cal.veryShortWeekdaySymbols[(cal.firstWeekday - 1)...] + cal.veryShortWeekdaySymbols[..<(cal.firstWeekday - 1)])
                // One list of cells with unique ids: weekday headers, blanks before the 1st, then the days.
                let cells: [(id: String, text: String, day: Int)] =
                    symbols.enumerated().map { ("h\($0.offset)", $0.element, -1) }
                    + (0..<lead).map { ("b\($0)", "", 0) }
                    + (1...days).map { ("d\($0)", "\($0)", $0) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                    ForEach(cells, id: \.id) { c in
                        if c.day < 0 {
                            Text(c.text).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                        } else if c.day == 0 {
                            Color.clear.frame(height: 16)
                        } else {
                            Text(c.text).font(.system(size: 9.5, weight: c.day == today ? .bold : .medium).monospacedDigit())
                                .foregroundStyle(c.day == today ? Color.white : Color.white.opacity(c.day < today ? 0.4 : 0.8))
                                .frame(width: 18, height: 16)
                                .background { if c.day == today { Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 17, height: 17) } }
                        }
                    }
                }
                if calendar.authorized {
                    ForEach(calendar.events.prefix(2)) { e in
                        HStack(spacing: 6) {
                            Capsule().fill(Color.white.opacity(0.7)).frame(width: 2.5, height: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                                Text(e.allDay ? "All day" : e.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cortexGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), darken: 0.2)
        }
        .onAppear { CalendarService.shared.refresh() }
    }
}

/// The playing song's artwork colours as a moving wallpaper; the frosted look when nothing plays.
struct LauncherMusicWallpaper: View {
    @ObservedObject var bridge: MediaRemoteBridge

    var body: some View {
        if let info = bridge.info, info.artwork != nil {
            MusicBackdrop(artwork: info.artwork, key: "\(info.title)|\(info.artist)", playing: info.playing)
                .opacity(0.9)
        }
    }
}

struct LauncherWeatherCard: View {
    @ObservedObject private var service = WeatherService.shared

    var body: some View {
        Group {
            if let w = service.weather {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(w.temperature.rounded()))° now in").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    Text(w.place.isEmpty ? "your area" : w.place).font(.system(size: 17, weight: .bold))
                    HStack(spacing: 6) {
                        Image(systemName: w.symbol).symbolRenderingMode(.hierarchical)
                        Text(w.summary)
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .cortexGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), darken: 0.2)
            }
        }
        .onAppear { service.watch() }
        .onDisappear { service.unwatch() }
    }
}
