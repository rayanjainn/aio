import AppKit
import SwiftUI
import Combine

/// Never becomes key or main, so showing or clicking it never steals focus.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Borderless windows are otherwise pushed below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI island and reports the pointer entering / leaving it.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    // A click on a non-key window must act, not just "activate".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
final class IslandController {
    let model = IslandModel()
    private let bridge: MediaRemoteBridge
    private let power: PowerMonitor
    private var panel: IslandPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?

    init(bridge: MediaRemoteBridge, power: PowerMonitor) {
        self.bridge = bridge
        self.power = power
    }

    func show() {
        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let host = IslandHostingView(rootView: IslandRootView(model: model, bridge: bridge))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host
        self.panel = panel

        bridge.$info.receive(on: DispatchQueue.main).sink { [weak self] in self?.model.track = $0 }.store(in: &cancellables)
        power.$percent.receive(on: DispatchQueue.main).sink { [weak self] in self?.model.battery = $0 }.store(in: &cancellables)
        power.$charging.receive(on: DispatchQueue.main).sink { [weak self] in self?.model.charging = $0 }.store(in: &cancellables)
        power.onPlugIn = { [weak self] percent in
            DispatchQueue.main.async { self?.flash(.charging(percent)) }
        }
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.geometry = NotchGeometry.detect()
                Log.info("screens changed: \(self.describeGeometry())")
                self.layout(force: true)
            }
        }
        Log.info("island created: \(describeGeometry())")
        layout(force: true)
    }

    // MARK: behaviour

    private func hoverChanged(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.expanded = inside }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.12 : 0.3), execute: work)
    }

    private func flash(_ f: IslandModel.Flash) {
        model.flash = f
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: window layout

    /// The window always hugs the pill (so it never blocks menu-bar clicks around the
    /// notch). It grows instantly and shrinks only once the pill's animation is done.
    private func layout(force: Bool = false) {
        guard let panel else { return }
        let target = model.pillSize()
        if target == .zero { panel.orderOut(nil); return }
        let current = panel.isVisible ? panel.frame.size : .zero
        let grown = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        if grown != current || force { place(grown) }
        shrinkWork?.cancel()
        if grown != target {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let t = self.model.pillSize()
                if t == .zero { self.panel?.orderOut(nil) } else { self.place(t) }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
    }

    private func place(_ size: CGSize) {
        guard let panel, size != .zero else { return }
        let f = model.geometry.screenFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func toggleExpanded() {
        hoverWork?.cancel()
        model.expanded.toggle()
    }

    // MARK: diagnostics

    func describeGeometry() -> String {
        let g = model.geometry
        return "notch=\(g.hasNotch) notchWidth=\(Int(g.notchWidth)) menuBar=\(Int(g.menuBarHeight)) screen=\(NSStringFromRect(g.screenFrame))"
    }

    func describePanel() -> String {
        guard let panel else { return "not created" }
        return "visible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame)) level=\(panel.level.rawValue) expanded=\(model.expanded) pill=\(NSStringFromSize(model.pillSize()))"
    }
}
