import AppKit
import SwiftUI

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selected = 0
    @Published var loading = true
    var onChoose: ((Int) -> Void)?
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.loading && model.windows.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for windows…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if model.windows.isEmpty {
                Text("No windows").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(224), spacing: 14), count: min(model.windows.count, 4)), spacing: 16) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.key) { index, w in
                        SwitcherCard(window: w, selected: index == model.selected)
                            .onTapGesture { model.selected = index; model.onChoose?(index) }
                    }
                }
            }
            HStack(spacing: 14) {
                Text("⇥ / ←→  move").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("↩  switch").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("esc  cancel").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if !WindowService.canCapture {
                    Text("Allow Screen Recording in Settings for previews").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(22)
        .cortexGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), darken: 0.35)
        .environment(\.colorScheme, .dark)
        .padding(8)
    }
}

struct SwitcherCard: View {
    let window: WindowInfo
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = window.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Color.white.opacity(0.06)
                        if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                            Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                        }
                    }
                }
            }
            .frame(width: 224, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 0.8))
            HStack(spacing: 6) {
                if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(window.title.isEmpty ? window.appName : window.title).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .frame(width: 224, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

final class SwitcherPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { keyHandler?(event) }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// ⌥⇥ — every window of every app (even other Spaces), with live thumbnails.
@MainActor
final class WindowSwitcher {
    let model = SwitcherModel()
    private var panel: SwitcherPanel?
    private var loadTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// First press opens it; pressing again moves to the next window.
    func showOrAdvance() {
        if isVisible { advance(1); return }
        show()
    }

    func show() {
        let panel = self.panel ?? build()
        model.windows = []
        model.selected = 0
        model.loading = true
        resize(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            var windows = await WindowService.allWindows()
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            windows.sort { a, b in
                if (a.pid == front) != (b.pid == front) { return a.pid == front }
                if a.appName != b.appName { return a.appName < b.appName }
                return a.title < b.title
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.model.windows = windows
                self.model.loading = false
                self.model.selected = windows.count > 1 ? 1 : 0
                self.resize(panel)
            }
        }
    }

    func hide() {
        loadTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func advance(_ delta: Int) {
        guard !model.windows.isEmpty else { return }
        model.selected = (model.selected + delta + model.windows.count) % model.windows.count
    }

    private func choose(_ index: Int) {
        guard model.windows.indices.contains(index) else { hide(); return }
        let window = model.windows[index]
        hide()
        WindowService.raise(window)
    }

    private func resize(_ panel: SwitcherPanel) {
        let n = max(model.windows.count, 1)
        let cols = min(n, 4)
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let width = CGFloat(cols) * 224 + CGFloat(cols - 1) * 14 + 22 * 2 + 16
        let height = model.windows.isEmpty ? 220 : CGFloat(rows) * 186 + CGFloat(rows - 1) * 16 + 22 * 2 + 50
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let h = min(height, f.height * 0.85)
        panel.setFrame(NSRect(x: f.midX - width / 2, y: f.midY - h / 2, width: width, height: h), display: true)
    }

    private func build() -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        model.onChoose = { [weak self] i in self?.choose(i) }
        panel.keyHandler = { [weak self] event in
            guard let self else { return }
            let shift = event.modifierFlags.contains(.shift)
            switch Int(event.keyCode) {
            case 48: self.advance(shift ? -1 : 1)          // tab
            case 124, 125: self.advance(1)                 // → ↓
            case 123, 126: self.advance(-1)                // ← ↑
            case 36, 76: self.choose(self.model.selected)  // return / enter
            case 53: self.hide()                           // esc
            default: break
            }
        }
        let host = NSHostingView(rootView: SwitcherView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
        self.panel = panel
        return panel
    }
}
