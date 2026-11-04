import AppKit
import SwiftUI
import Combine

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class DockHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    var onMove: ((NSPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true); onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onHover?(false); onMove?(nil) }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
}

@MainActor
final class DockController {
    let model = DockModel()
    private var panel: DockPanel?
    private var previews: DockPreviewController?
    private var cancellables = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var autohideTimer: Timer?
    private var hiddenByAutohide = false
    private var hideCountdown: Date?
    private var lastTarget: CGSize = .zero

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { build() }
        layout(force: true)
        model.startBadgePolling()
        configureAutohide()
    }

    func hide() {
        previews?.hide()
        model.stopBadgePolling()
        autohideTimer?.invalidate(); autohideTimer = nil
        panel?.orderOut(nil)
    }

    private func build() {
        let panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let host = DockHostingView(rootView: DockRootView(model: model))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        host.onMove = { [weak self, weak host] p in
            guard let self, let host else { return }
            guard let p else { self.model.pointerMoved(along: nil, across: 0); return }
            let b = host.bounds
            let lead = DockModel.sideMargin + DockModel.padding
            switch self.model.edge {
            case "left": self.model.pointerMoved(along: (b.height - p.y) - lead, across: p.x)
            case "right": self.model.pointerMoved(along: (b.height - p.y) - lead, across: b.width - p.x)
            default: self.model.pointerMoved(along: p.x - lead, across: p.y)
            }
        }
        panel.contentView = host
        self.panel = panel

        let previews = DockPreviewController(dock: model)
        previews.anchorProvider = { [weak self] index in self?.anchor(forSlot: index) }
        self.previews = previews

        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let t = self.targetSize()
                if t != self.lastTarget { self.lastTarget = t; self.layout() }
            }
        }.store(in: &cancellables)
        Prefs.shared.$dockAutohide.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configureAutohide() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.layout(force: true) }
        }
        Log.info("dock created")
    }

    private func hoverChanged(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.hovering = inside }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.0 : 0.25), execute: work)
    }

    // MARK: geometry

    /// The window is only as thick as the bar, plus headroom for magnified icons while the pointer
    /// is on it — so it never blocks clicks on the windows behind it.
    private func targetSize() -> CGSize {
        let along = model.barAlong + DockModel.sideMargin * 2
        let across = model.barAcross + 8 + (model.hovering ? model.headroom : 0)
        return model.isVertical ? CGSize(width: across, height: along) : CGSize(width: along, height: across)
    }

    private func screen() -> NSScreen? { NSScreen.screens.first }

    private func restFrame(for size: CGSize) -> NSRect {
        guard let area = screen()?.visibleFrame, let full = screen()?.frame else { return .zero }
        switch model.edge {
        case "left": return NSRect(x: area.minX + 4, y: area.midY - size.height / 2, width: size.width, height: size.height)
        case "right": return NSRect(x: area.maxX - size.width - 4, y: area.midY - size.height / 2, width: size.width, height: size.height)
        default: return NSRect(x: full.midX - size.width / 2, y: area.minY + 4, width: size.width, height: size.height)
        }
    }

    private func hiddenFrame(for size: CGSize) -> NSRect {
        var r = restFrame(for: size)
        switch model.edge {
        case "left": r.origin.x -= size.width + 10
        case "right": r.origin.x += size.width + 10
        default: r.origin.y -= size.height + 10
        }
        return r
    }

    private func anchor(forSlot index: Int) -> NSPoint? {
        guard let panel else { return nil }
        let f = panel.frame
        let c = DockModel.sideMargin + DockModel.padding + model.centre(ofSlot: index)
        let bar = model.barAcross
        switch model.edge {
        case "left":
            // Slots run top → bottom.
            return NSPoint(x: f.minX + bar + 2, y: f.maxY - c)
        case "right":
            return NSPoint(x: f.maxX - bar - 2, y: f.maxY - c)
        default:
            return NSPoint(x: f.minX + c, y: f.minY + bar + 8 - 2)
        }
    }

    private func layout(force: Bool = false) {
        guard let panel else { return }
        let target = targetSize()
        if hiddenByAutohide, Prefs.shared.dockAutohide {
            panel.setFrame(hiddenFrame(for: target), display: true)
            return
        }
        let current = panel.isVisible ? panel.frame.size : .zero
        let grown = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        // Keep the screen-edge side fixed while the window grows / shrinks.
        if grown != current || force { place(grown) }
        shrinkWork?.cancel()
        if grown != target {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.place(self.targetSize())
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func place(_ size: CGSize) {
        guard let panel, screen() != nil else { return }
        panel.setFrame(restFrame(for: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: auto-hide

    private func configureAutohide() {
        autohideTimer?.invalidate(); autohideTimer = nil
        guard let panel else { return }
        if !Prefs.shared.dockAutohide {
            if hiddenByAutohide { reveal() }
            return
        }
        if !hiddenByAutohide { concealSoon(immediately: true) }
        autohideTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autohideTick() }
        }
        _ = panel
    }

    private func autohideTick() {
        guard let panel, Prefs.shared.dockAutohide, let scr = screen() else { return }
        let loc = NSEvent.mouseLocation
        let rest = restFrame(for: targetSize())
        let f = scr.frame
        let atEdge: Bool
        switch model.edge {
        case "left": atEdge = loc.x <= f.minX + 2 && loc.y >= rest.minY && loc.y <= rest.maxY
        case "right": atEdge = loc.x >= f.maxX - 2 && loc.y >= rest.minY && loc.y <= rest.maxY
        default: atEdge = loc.y <= f.minY + 2 && loc.x >= rest.minX && loc.x <= rest.maxX
        }
        if hiddenByAutohide {
            if atEdge { reveal() }
        } else {
            let keepOpen = rest.insetBy(dx: -24, dy: -24).contains(loc) || model.previewHovering || model.hoveredID != nil || model.draggingID != nil
            if keepOpen { hideCountdown = nil }
            else if let t = hideCountdown { if Date().timeIntervalSince(t) > 0.55 { concealSoon(immediately: false) } }
            else { hideCountdown = Date() }
        }
        _ = panel
    }

    private func reveal() {
        guard let panel else { return }
        hiddenByAutohide = false
        hideCountdown = nil
        panel.ignoresMouseEvents = false
        let size = targetSize()
        panel.setFrame(hiddenFrame(for: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(restFrame(for: size), display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func concealSoon(immediately: Bool) {
        guard let panel else { return }
        hiddenByAutohide = true
        hideCountdown = nil
        previews?.hide()
        let size = targetSize()
        if immediately {
            panel.setFrame(hiddenFrame(for: size), display: true)
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame(for: size), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.ignoresMouseEvents = true })
    }

    func describe() -> String {
        guard let panel else { return "not created" }
        return "visible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame)) level=\(panel.level.rawValue) items=\(model.items.count) edge=\(model.edge) autohide=\(Prefs.shared.dockAutohide) hidden=\(hiddenByAutohide) screenRecording=\(WindowService.canCapture)"
    }
}

/// Hides / restores the macOS Dock by auto-hide with a very long delay. Remembers
/// what it changed so quitting (or the menu toggle) puts everything back.
enum SystemDock {
    private static let flag = "cortex.systemDockHiddenByUs"
    private static let priorKey = "cortex.systemDockPriorAutohide"

    static var hiddenByUs: Bool { UserDefaults.standard.bool(forKey: flag) }

    static func setHidden(_ hidden: Bool) {
        if hidden {
            if !hiddenByUs {
                let prior = defaults(["read", "com.apple.dock", "autohide"]).trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.set(prior == "1", forKey: priorKey)
                UserDefaults.standard.set(true, forKey: flag)
            }
            _ = defaults(["write", "com.apple.dock", "autohide", "-bool", "true"])
            _ = defaults(["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        } else {
            guard hiddenByUs else { return }
            _ = defaults(["write", "com.apple.dock", "autohide", "-bool", UserDefaults.standard.bool(forKey: priorKey) ? "true" : "false"])
            _ = defaults(["delete", "com.apple.dock", "autohide-delay"])
            UserDefaults.standard.set(false, forKey: flag)
        }
        run("/usr/bin/killall", ["Dock"])
        Log.info("system Dock \(hidden ? "hidden" : "restored")")
    }

    @discardableResult
    private static func defaults(_ args: [String]) -> String { run("/usr/bin/defaults", args) }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return "" }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
