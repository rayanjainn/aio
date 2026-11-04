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
    private var tracking: NSTrackingArea?

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
final class DockController {
    let model = DockModel()
    private var panel: DockPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { build() }
        layout(force: true)
    }

    func hide() {
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
        // Just above the system Dock's own level, below the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.dock.rawValue + 1)
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
        panel.contentView = host
        self.panel = panel

        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
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

    /// The window is only as tall as the bar, plus headroom for magnified icons while
    /// the pointer is on it — so it never blocks clicks on the windows behind it.
    private func layout(force: Bool = false) {
        guard let panel else { return }
        let target = targetSize()
        let current = panel.isVisible ? panel.frame.size : .zero
        let grown = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
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

    private func targetSize() -> CGSize {
        CGSize(
            width: model.barWidth + DockModel.sideMargin * 2,
            height: model.barHeight + 8 + (model.hovering ? model.headroom : 0)
        )
    }

    private func place(_ size: CGSize) {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let rect = NSRect(x: screen.frame.midX - size.width / 2, y: area.minY + 4, width: size.width, height: size.height)
        panel.setFrame(rect, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func describe() -> String {
        guard let panel else { return "not created" }
        return "visible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame)) level=\(panel.level.rawValue) items=\(model.items.count) hovering=\(model.hovering)"
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
