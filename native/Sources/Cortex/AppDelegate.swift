import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let nowPlaying = MediaRemoteBridge()
    private let power = PowerMonitor()
    private let engineProcess = EngineProcess()
    private let engine = EngineClient()
    private var island: IslandController?
    private var dock: DockController?
    private var palette: PaletteController?
    private var statusItem: NSStatusItem?
    private var dockItem: NSMenuItem?
    private var systemDockItem: NSMenuItem?
    private var diagnosticsWindow: NSWindow?
    private var settings: SettingsController?
    private var widgets: WidgetController?
    private let switcher = WindowSwitcher()
    private let onboarding = OnboardingController()
    private var pendingUpdate: UpdateInfo?
    private var updateItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("AIO \(AppInfo.version) starting on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if AppRename.migrateIfNeeded() { return }

        // Search engine (separate process) + its client.
        engineProcess.start()
        engine.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.palette?.model.setEngine(ready: connected) }
        }
        engine.start()

        nowPlaying.start()
        power.start()

        let island = IslandController(bridge: nowPlaying, power: power)
        island.show()
        self.island = island

        let dock = DockController()
        self.dock = dock
        dock.model.bridge = nowPlaying
        dock.model.power = power
        Prefs.shared.$dockEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?.dock?.show() } else { self?.dock?.hide() }
                self?.dockItem?.state = enabled ? .on : .off
            }
            .store(in: &cancellables)

        Prefs.shared.$islandAllDisplays.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncSecondaryIslands() }.store(in: &cancellables)
        Prefs.shared.$islandDisplay.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.syncSecondaryIslands() } }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self?.syncSecondaryIslands()
                self?.applyDockProfileForDisplays()
            }
        }
        syncSecondaryIslands()
        Coach.shared.start()
        launcher.bridge = nowPlaying
        musicPlayer.bridge = nowPlaying
        NotificationCenter.default.addObserver(forName: .openMusicPlayer, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.musicPlayer.show() }
        }
        Prefs.shared.$launcherHotCorner.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.launcher.configureHotCorner() } }.store(in: &cancellables)
        menuBarDock.attach(dock.model)
        Prefs.shared.$dockMenuBar.receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.menuBarDock.setVisible(on) }.store(in: &cancellables)
        Engine.client = engine
        if !Prefs.shared.hyperKey { HyperKey.cleanUpStaleRemap() }
        Prefs.shared.$hyperKey
            .receive(on: DispatchQueue.main)
            .sink { on in
                if on { if !HyperKey.start() { Toast.show("keyboard", "Hyper key needs Accessibility access"); } }
                else { HyperKey.stop() }
            }
            .store(in: &cancellables)

        let palette = PaletteController()
        palette.attach(client: engine, runBuiltin: { [weak self] id in self?.runBuiltin(id) })
        self.palette = palette

        let widgets = WidgetController(bridge: nowPlaying, power: power)
        widgets.start()
        self.widgets = widgets

        HotKeyCenter.shared.onAction = { [weak self] action in self?.runBuiltin(action) }
        HotKeyCenter.shared.registerAll()

        settings = SettingsController(actions: SettingsActions(
            reregisterHotkeys: { HotKeyCenter.shared.registerAll() },
            systemDockHidden: { SystemDock.hiddenByUs },
            setSystemDockHidden: { [weak self] hide in SystemDock.setHidden(hide); self?.systemDockItem?.state = hide ? .on : .off },
            engineSummary: { [weak self] in
                guard let self else { return "" }
                return "\(self.engineProcess.describe), \(self.engine.isConnected ? "connected" : "not connected")"
            },
            reindex: { [weak self] in Task { _ = try? await self?.engine.call("sync") } },
            toggleScreenMemory: { [weak self] in Task { _ = try? await self?.engine.call("recording_toggle") } },
            openDiagnostics: { [weak self] in self?.showDiagnostics() },
            addDockFolder: { [weak self] in self?.addDockFolder() },
            dockHasWidget: { [weak self] id in self?.dock?.model.hasWidget(id) ?? false },
            dockSetWidget: { [weak self] id, on in if on { self?.dock?.model.addWidget(id) } else { self?.dock?.model.removeWidget(id) } },
            dockModel: { [weak self] in self?.dock?.model },
            engine: engine))
        setUpStatusItem()
        if !Prefs.shared.onboardingDone { onboarding.show() }
        checkForUpdatesQuietly()
        if !WindowManager.isTrusted {
            Log.info("Accessibility not granted yet (needed for window snapping)")
            // Pick the permission up the moment it is granted — no relaunch needed.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                guard WindowManager.isTrusted else { return }
                t.invalidate()
                Task { @MainActor in
                    Log.info("Accessibility granted — starting media keys and window features")
                    if Prefs.shared.islandHUD { HUDService.shared.captureKeys() }
                }
            }
        }
        GitHubService.shared.start()
        AppRecency.shared.start()
        if CommandLine.arguments.contains("--grant-permissions") {
            // Relaunched by "Reset and ask again": go straight to the permissions list and ask for all of them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.settings?.show(.privacy)
                Permissions.shared.refresh()
                Permissions.shared.grantEverything()
            }
        }
    }

    /// cortex://run/<command>, cortex://palette?q=…, cortex://toast?text=… — so scripts and Shortcuts can drive Cortex.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "cortex" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ k: String) -> String? { items.first(where: { $0.name == k })?.value }
            switch url.host {
            case "run": runBuiltin(String(url.path.dropFirst()))
            case "palette": palette?.show(query: q("q") ?? "")
            case "toast": Toast.show(q("symbol") ?? "bell", q("text") ?? "")
            case "layout": if let n = q("name") { WindowLayouts.restore(n) }
            default: Log.warn("unknown cortex:// link \(url)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HyperKey.stop()
        nowPlaying.stop()
        engineProcess.stop()
        SystemDock.setHidden(false)   // never leave the user without a Dock
    }

    // MARK: actions (menu, palette commands and hotkeys all land here)

    private func runBuiltin(_ id: String) {
        switch id {
        case "palette": palette?.toggle()
        case "launcher": launcher.toggle()
        case "music": musicPlayer.toggle()
        case "music.open": musicPlayer.show()
        case "music.close": musicPlayer.hide()
        case "act": ActOnThis.captureSelection { [weak self] in self?.palette?.show(query: "ai ") }
        case "clip.plain": ActOnThis.pastePlain()
        case "dictate": ActOnThis.dictate()
        case "app.diagnostics": showDiagnostics()
        case "app.diagnostics.export": exportDiagnostics()
        case "app.timeline": showTimeline()
        case "app.settings": settings?.show()
        case "switcher", "app.switcher": switcher.showOrAdvance()
        case "timer.25": FocusTimer.shared.start(minutes: 25)
        case "timer.50": FocusTimer.shared.start(minutes: 50)
        case "timer.5": FocusTimer.shared.start(minutes: 5, label: "Break")
        case "timer.stop": FocusTimer.shared.reset()
        case "island.calendar": island?.openPage(.calendar)
        case "island.collapse": island?.collapse()
        case "island.shelf": island?.openPage(.shelf)
        case "island.tools": island?.openPage(.tools)
        case "app.addWidget": widgets?.showGallery()
        case "app.toggleWidgets": widgets?.toggleVisible()
        case "app.toggleDock": toggleDock()
        case "app.toggleSystemDock": toggleSystemDock()
        case "app.island", "island": island?.toggleExpanded()
        case "app.quit": NSApp.terminate(nil)
        case "app.reindex":
            Task { _ = try? await engine.call("sync") }
        case "app.pause", "pause":
            Task { _ = try? await engine.call("recording_toggle") }
        default:
            if id.hasPrefix("island.page:"), let page = IslandPage(rawValue: String(id.dropFirst(12))) { island?.openPage(page) }
            else if id.hasPrefix("music.style:") { Prefs.shared.musicPlayerStyle = String(id.dropFirst(12)) }
            else if id == "dock.magnify:on" { if magnifyBeforeTest == nil { magnifyBeforeTest = Prefs.shared.dockMagnify }; Prefs.shared.dockMagnify = true }
            else if id == "dock.magnify:restore" { Prefs.shared.dockMagnify = magnifyBeforeTest ?? Prefs.shared.dockMagnify; magnifyBeforeTest = nil }
            else if id.hasPrefix("music.lyrics:") { Prefs.shared.musicPlayerLyrics = id.hasSuffix(":on") }
            else if id.hasPrefix("space.save:") { Spaces.save(String(id.dropFirst(11)), dock: dock?.model) }
            else if id.hasPrefix("space.use:") { Spaces.apply(String(id.dropFirst(10)), dock: dock?.model) }
            else if id.hasPrefix("widget.ai:"), let store = widgets?.store { AIWidgetMaker.make(String(id.dropFirst(10)), store: store) }
            else if id.hasPrefix("dock.save:") { let n = String(id.dropFirst(10)); dock?.model.saveProfile(n); Toast.show("dock.rectangle", "Saved Dock “\(n)”") }
            else if id.hasPrefix("dock.use:") { dock?.model.applyProfile(String(id.dropFirst(9))) }
            else if id.hasPrefix("note.add:") { QuickNotes.add(String(id.dropFirst("note.add:".count))); Toast.show("square.and.pencil", "Note saved") }
            else if id == "pin.add" { Toast.show("pin.fill", PinStore.addClipboard() ? "Pinned" : "Clipboard is empty") }
            else if let tab = BrowserTabs.parse(id) { BrowserTabs.focus(tab) }
            else if id.hasPrefix("layout.save:") {
                let n = String(id.dropFirst("layout.save:".count))
                let c = WindowLayouts.save(n)
                Toast.show("rectangle.3.group", c > 0 ? "Saved layout “\(n)” — \(c) windows" : "Grant Accessibility to save layouts")
            }
            else if id.hasPrefix("layout.restore:") { WindowLayouts.restore(String(id.dropFirst("layout.restore:".count))) }
            else if id.hasPrefix("layout.delete:") { WindowLayouts.delete(String(id.dropFirst("layout.delete:".count))) }
            else if id.hasPrefix("window.") { WindowManager.perform(String(id.dropFirst("window.".count))) }
            else if id.hasPrefix("app:") {
                let bundle = String(id.dropFirst(4))
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            }
            else { Log.warn("unknown action \(id)") }
        }
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()
        let menu = NSMenu()
        menu.addItem(withTitle: "AIO \(AppInfo.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open AIO", action: #selector(openPalette), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let launchItem = NSMenuItem(title: "Open Launcher", action: #selector(openLauncher), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        let dockToggle = NSMenuItem(title: "Show AIO Dock", action: #selector(toggleDock), keyEquivalent: "")
        dockToggle.target = self
        dockToggle.state = .on
        menu.addItem(dockToggle)
        dockItem = dockToggle
        let addWidget = NSMenuItem(title: "Add Widget…", action: #selector(openWidgetGallery), keyEquivalent: "")
        addWidget.target = self
        menu.addItem(addWidget)
        let toggleWidgets = NSMenuItem(title: "Show / Hide Widgets", action: #selector(toggleWidgets), keyEquivalent: "")
        toggleWidgets.target = self
        menu.addItem(toggleWidgets)
        let sysDock = NSMenuItem(title: "Hide macOS Dock", action: #selector(toggleSystemDock), keyEquivalent: "")
        sysDock.target = self
        sysDock.state = SystemDock.hiddenByUs ? .on : .off
        menu.addItem(sysDock)
        systemDockItem = sysDock
        let access = NSMenuItem(title: "Grant Window-Snapping Access…", action: #selector(grantAccessibility), keyEquivalent: "")
        access.target = self
        menu.addItem(access)
        menu.addItem(.separator())
        let upd = NSMenuItem(title: "Install Update…", action: #selector(installUpdate), keyEquivalent: "")
        upd.target = self
        upd.isHidden = true
        menu.addItem(upd)
        updateItem = upd
        let timeline = NSMenuItem(title: "Screen Memory Timeline…", action: #selector(showTimeline), keyEquivalent: "")
        timeline.target = self
        menu.addItem(timeline)
        let diag = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let log = NSMenuItem(title: "Reveal Log", action: #selector(revealLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AIO", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openPalette() { palette?.show() }

    /// Checks 20 s after launch and then every 6 hours. With automatic updates on (the default) a new
    /// version installs itself once you've been away from the keyboard for a minute; otherwise the ✦ menu offers it.
    private func checkForUpdatesQuietly() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                if let update = try? await UpdateChecker.check(current: AppInfo.version) {
                    await MainActor.run { self?.offer(update) }
                }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    private func offer(_ update: UpdateInfo) {
        let isNew = pendingUpdate?.tag != update.tag
        pendingUpdate = update
        updateItem?.title = "Install Update \(update.tag)…"
        updateItem?.isHidden = false
        guard Prefs.shared.autoUpdate else {
            if isNew { Toast.show("arrow.down.circle", "Update \(update.tag) available — ✦ menu → Install") }
            return
        }
        if isNew { Toast.show("arrow.down.circle", "AIO \(update.tag) will install when you're away for a minute") }
        installWhenIdle()
    }

    private func installWhenIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= 60, let u = pendingUpdate, !SelfUpdater.shared.busy {
            Log.info("auto-update: installing \(u.tag) after \(Int(idle)) s idle")
            Task { await SelfUpdater.shared.install(u) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.installWhenIdle() }
        }
    }

    @objc private func installUpdate() {
        guard let u = pendingUpdate else { return }
        Task { await SelfUpdater.shared.install(u) }
    }

    private func addDockFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Dock"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { for url in panel.urls { dock?.model.addFolder(url) } }
    }
    @objc func openSettings() { settings?.show() }
    @objc func openLauncher() { launcher.toggle() }
    func launcherAutoGroup() { launcher.store.reload(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.launcher.store.autoGroup() } }
    func launcherReset() { launcher.store.resetLayout() }
    @objc private func openWidgetGallery() { widgets?.showGallery() }
    @objc private func toggleWidgets() { widgets?.toggleVisible() }
    @objc private func grantAccessibility() { WindowManager.requestAccess() }

    @objc private func toggleDock() {
        Prefs.shared.dockEnabled.toggle()   // the sink above shows / hides the Dock and updates the menu
    }

    @objc private func toggleSystemDock() {
        let hide = !SystemDock.hiddenByUs
        SystemDock.setHidden(hide)
        systemDockItem?.state = hide ? .on : .off
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    private var secondaryIslands: [String: IslandController] = [:]
    private let menuBarDock = MenuBarDock()
    private let launcher = LauncherController()
    private let musicPlayer = MusicPlayerController()
    private var magnifyBeforeTest: Bool?

    /// Uses the Dock profile chosen for "external display connected" / "built-in only", if any.
    private func applyDockProfileForDisplays() {
        let p = Prefs.shared
        let name = NSScreen.screens.count > 1 ? p.dockProfileExternal : p.dockProfileBuiltIn
        if !name.isEmpty { dock?.model.applyProfile(name) }
    }

    /// One extra pill per other display when "Also show a pill on my other displays" is on.
    private func syncSecondaryIslands() {
        guard let island else { return }
        let primaryFrame = island.model.geometry.screenFrame
        let wanted: [String] = Prefs.shared.islandAllDisplays && Prefs.shared.islandEnabled
            ? NSScreen.screens.filter { $0.frame != primaryFrame }.map(\.localizedName) : []
        for (name, controller) in secondaryIslands where !wanted.contains(name) {
            controller.hide()
            secondaryIslands[name] = nil
        }
        for name in wanted where secondaryIslands[name] == nil {
            let c = IslandController(bridge: nowPlaying, power: power, screenName: name, primary: island)
            c.show()
            secondaryIslands[name] = c
        }
    }

    private var timelineWindow: NSWindow?

    @objc func showTimeline() {
        if let w = timelineWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Screen Memory"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MemoryTimelineView(client: engine))
            w.center()
            timelineWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Writes the Diagnostics report to ~/.cortex/logs/diagnostics.txt (used by the e2e test script).
    private func exportDiagnostics() {
        let text = Diagnostics.report(island: island, dock: dock, bridge: nowPlaying,
                                      engineProcess: engineProcess.describe, engineConnected: engine.isConnected,
                                      widgets: widgets?.describe() ?? "")
            + "\n== Signing ==\nsigned by: \(AppInfo.signer)  auto-update=\(Prefs.shared.autoUpdate)"
            + "\n== Surfaces ==\nlauncher visible=\(launcher.isVisible) apps=\(launcher.store.apps.count) folders=\(launcher.store.layout.folders.count)"
            + "\nmusic player visible=\(musicPlayer.isVisible) style=\(Prefs.shared.musicPlayerStyle) lyrics=\(Prefs.shared.musicPlayerLyrics) lyricsState=\(LyricsService.shared.state) lines=\(LyricsService.shared.lines.count)"
            + "\nhyper key=\(HyperKey.isRunning) hot corner=\(Prefs.shared.launcherHotCorner)\n"
        let url = Log.fileURL.deletingLastPathComponent().appendingPathComponent("diagnostics.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func showDiagnostics() {
        let provider: () -> String = { [weak self] in
            guard let self else { return "" }
            return Diagnostics.report(island: self.island, dock: self.dock, bridge: self.nowPlaying,
                                      engineProcess: self.engineProcess.describe, engineConnected: self.engine.isConnected,
                                      widgets: self.widgets?.describe() ?? "")
        }
        let view = NSHostingView(rootView: DiagnosticsView(text: provider(), refresh: provider))
        if let w = diagnosticsWindow {
            w.contentView = view
            w.makeKeyAndOrderFront(nil)
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "AIO Diagnostics"
            w.isReleasedWhenClosed = false
            w.contentView = view
            w.center()
            diagnosticsWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
