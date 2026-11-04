import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let nowPlaying = MediaRemoteBridge()
    private let power = PowerMonitor()
    private var island: IslandController?
    private var dock: DockController?
    private var dockItem: NSMenuItem?
    private var systemDockItem: NSMenuItem?
    private var statusItem: NSStatusItem?
    private var diagnosticsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Cortex native \(AppInfo.version) starting on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        nowPlaying.start()
        power.start()
        let island = IslandController(bridge: nowPlaying, power: power)
        island.show()
        self.island = island
        let dock = DockController()
        dock.show()
        self.dock = dock
        setUpStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        SystemDock.setHidden(false)   // never leave the user without a Dock
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Cortex")
        let menu = NSMenu()
        menu.addItem(withTitle: "Cortex \(AppInfo.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let dockToggle = NSMenuItem(title: "Show Cortex Dock", action: #selector(toggleDock), keyEquivalent: "")
        dockToggle.target = self
        dockToggle.state = .on
        menu.addItem(dockToggle)
        dockItem = dockToggle
        let sysDock = NSMenuItem(title: "Hide macOS Dock", action: #selector(toggleSystemDock), keyEquivalent: "")
        sysDock.target = self
        sysDock.state = SystemDock.hiddenByUs ? .on : .off
        menu.addItem(sysDock)
        systemDockItem = sysDock
        menu.addItem(.separator())
        let diag = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let log = NSMenuItem(title: "Reveal Log", action: #selector(revealLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Cortex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleDock() {
        guard let dock else { return }
        if dock.isVisible { dock.hide(); dockItem?.state = .off } else { dock.show(); dockItem?.state = .on }
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
        let text = Diagnostics.report(island: island, dock: dock, bridge: nowPlaying)
        if let w = diagnosticsWindow {
            w.contentView = NSHostingView(rootView: DiagnosticsView(text: text, refresh: { [weak self] in
                guard let self else { return "" }
                return Diagnostics.report(island: self.island, dock: self.dock, bridge: self.nowPlaying)
            }))
            w.makeKeyAndOrderFront(nil)
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Cortex Diagnostics"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DiagnosticsView(text: text, refresh: { [weak self] in
                guard let self else { return "" }
                return Diagnostics.report(island: self.island, dock: self.dock, bridge: self.nowPlaying)
            }))
            w.center()
            diagnosticsWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
