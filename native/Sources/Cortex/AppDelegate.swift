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
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Cortex native \(AppInfo.version) starting on \(ProcessInfo.processInfo.operatingSystemVersionString)")

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
        Prefs.shared.$dockEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?.dock?.show() } else { self?.dock?.hide() }
                self?.dockItem?.state = enabled ? .on : .off
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
            addDockFolder: { [weak self] in self?.addDockFolder() }))
        setUpStatusItem()
        if !Prefs.shared.onboardingDone { settings?.show(.privacy) }
        if !WindowManager.isTrusted { Log.info("Accessibility not granted yet (needed for window snapping)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        engineProcess.stop()
        SystemDock.setHidden(false)   // never leave the user without a Dock
    }

    // MARK: actions (menu, palette commands and hotkeys all land here)

    private func runBuiltin(_ id: String) {
        switch id {
        case "palette": palette?.toggle()
        case "app.diagnostics": showDiagnostics()
        case "app.settings": settings?.show()
        case "switcher", "app.switcher": switcher.showOrAdvance()
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
            if id.hasPrefix("window.") { WindowManager.perform(String(id.dropFirst("window.".count))) }
            else { Log.warn("unknown action \(id)") }
        }
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Cortex")
        let menu = NSMenu()
        menu.addItem(withTitle: "Cortex \(AppInfo.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Cortex", action: #selector(openPalette), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        let dockToggle = NSMenuItem(title: "Show Cortex Dock", action: #selector(toggleDock), keyEquivalent: "")
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
        let diag = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let log = NSMenuItem(title: "Reveal Log", action: #selector(revealLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Cortex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openPalette() { palette?.show() }

    private func addDockFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Dock"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { for url in panel.urls { dock?.model.addFolder(url) } }
    }
    @objc private func openSettings() { settings?.show() }
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
            w.title = "Cortex Diagnostics"
            w.isReleasedWhenClosed = false
            w.contentView = view
            w.center()
            diagnosticsWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
