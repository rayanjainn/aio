import AppKit
import SwiftUI
import Combine

final class WidgetPanel: NSPanel {
    // Notes / to-dos need the keyboard; becomesKeyOnlyIfNeeded keeps everything else click-through-to-focus-neutral.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class WidgetController {
    let store = WidgetStore()
    private let bridge: MediaRemoteBridge
    private let power: PowerMonitor
    private var panels: [String: WidgetPanel] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var gallery: NSWindow?

    init(bridge: MediaRemoteBridge, power: PowerMonitor) {
        self.bridge = bridge
        self.power = power
    }

    func start() {
        store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        store.$visible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.sync() }
        }
    }

    var count: Int { store.items.count }

    func toggleVisible() { store.visible.toggle() }

    /// Creates, moves, resizes and removes panels so they match the store.
    private func sync() {
        let ids = Set(store.items.map(\.id))
        for (id, panel) in panels where !ids.contains(id) || !store.visible {
            panel.orderOut(nil)
            if !ids.contains(id) { panel.close(); panels[id] = nil }
        }
        guard store.visible else { return }
        for (index, config) in store.items.enumerated() {
            let panel = panels[config.id] ?? makePanel(config)
            panels[config.id] = panel
            let size = config.size.dimensions
            var frame = panel.frame
            if frame.size != size {
                // Keep the top-left corner where it is when resizing.
                frame = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
                if panel.frame.size == NSSize(width: 10, height: 10) { frame.origin = defaultOrigin(index: index, size: size, config: config) }
                panel.setFrame(frame, display: true)
            }
            panel.level = config.floating ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func defaultOrigin(index: Int, size: CGSize, config: WidgetConfig) -> NSPoint {
        if let x = config.x, let y = config.y { return NSPoint(x: x, y: y) }
        guard let area = NSScreen.screens.first?.visibleFrame else { return .zero }
        // Cascade down the right edge, new column when it runs out of room.
        var x = area.maxX - size.width - 24
        var y = area.maxY - size.height - 24
        var placed = 0
        for earlier in store.items.prefix(index) {
            let h = earlier.size.dimensions.height + 16
            y -= h
            placed += 1
            if y < area.minY + 24 { y = area.maxY - size.height - 24; x -= 372 }
        }
        _ = placed
        return NSPoint(x: x, y: y)
    }

    private func makePanel(_ config: WidgetConfig) -> WidgetPanel {
        let panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let host = WidgetHostingView(rootView: WidgetHostView(store: store, bridge: bridge, power: power, id: config.id))
        host.sizingOptions = []
        panel.contentView = host
        let id = config.id
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            DispatchQueue.main.async {
                guard let self, let panel, panel.isVisible else { return }
                self.store.update(id) { $0.x = Double(panel.frame.minX); $0.y = Double(panel.frame.minY) }
            }
        }
        return panel
    }

    func showGallery() {
        if let g = gallery { g.contentView = NSHostingView(rootView: WidgetGalleryView(store: store)); g.makeKeyAndOrderFront(nil) }
        else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Add a Widget"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WidgetGalleryView(store: store))
            w.center()
            gallery = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func describe() -> String {
        "\(store.items.count) widget(s), visible=\(store.visible), panels=\(panels.count)"
    }
}
