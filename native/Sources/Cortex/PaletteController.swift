import AppKit
import SwiftUI
import Combine

/// A panel that takes keyboard focus without activating Cortex (so the app you were using
/// keeps its place) — the way Spotlight behaves.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class PaletteController {
    let model = PaletteModel()
    private var panel: PalettePanel?
    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { panel?.isVisible ?? false }

    func attach(client: EngineClient, runBuiltin: @escaping (String) -> Void) {
        model.client = client
        model.runBuiltin = runBuiltin
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let panel = self.panel ?? build()
        model.reset()
        place(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func build() -> PalettePanel {
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: PaletteView.width, height: PaletteModel.searchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: PaletteView(model: model, onClose: { [weak self] in self?.hide() }))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel

        // Click-away closes it.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
        // Grow / shrink with the number of results, keeping the top edge fixed.
        model.$rows.combineLatest(model.$message, model.$chat)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.resize() }
            .store(in: &cancellables)
        return panel
    }

    private func currentHeight() -> CGFloat { model.totalHeight }

    private func resize() {
        guard let panel, panel.isVisible else { return }
        let h = currentHeight()
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: PaletteView.width, height: h)
        frame.origin.y = top - h
        panel.setFrame(frame, display: true)
    }

    private func place(_ panel: PalettePanel) {
        // On the screen the pointer is on, a third of the way down.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        let h = currentHeight()
        let top = area.maxY - area.height * 0.22
        panel.setFrame(NSRect(x: area.midX - PaletteView.width / 2, y: top - h, width: PaletteView.width, height: h), display: true)
    }
}
