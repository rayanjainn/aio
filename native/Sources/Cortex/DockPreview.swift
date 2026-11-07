import AppKit
import SwiftUI
import Combine

enum PreviewContent {
    case none
    case label(String)
    case windows(String, [WindowInfo])
    case stack(String, URL, [URL])
}

/// What the preview popover shows (an app's windows, a folder's contents, or just a name).
@MainActor
final class PreviewModel: ObservableObject {
    @Published var content: PreviewContent = .none
    var onHover: ((Bool) -> Void)?
    var onChoose: (() -> Void)?
    var onRefresh: (() -> Void)?
}

struct PreviewView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        Group {
            switch model.content {
            case .none: EmptyView()
            case .label(let name):
                Text(name).font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .cortexGlass(in: Capsule(), darken: 0.2)
            case .windows(let name, let windows):
                VStack(alignment: .leading, spacing: 10) {
                    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(windows, id: \.key) { w in WindowCard(window: w, model: model) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(14)
                .frame(maxWidth: 900, alignment: .leading)
                .cortexGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), darken: 0.25)
            case .stack(let name, let url, let files):
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open in Finder") { NSWorkspace.shared.open(url); model.onChoose?() }.buttonStyle(.plain).font(.system(size: 11))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(82), spacing: 8), count: min(max(files.count, 1), 6)), spacing: 10) {
                        ForEach(files, id: \.self) { f in
                            VStack(spacing: 4) {
                                Image(nsImage: IconCache.icon(forPath: f.path)).resizable().frame(width: 48, height: 48)
                                Text(f.lastPathComponent).font(.system(size: 10.5)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 82)
                            .contentShape(Rectangle())
                            .onTapGesture { NSWorkspace.shared.open(f); model.onChoose?() }
                        }
                    }
                    if files.isEmpty { Text("Empty").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(14)
                .cortexGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), darken: 0.25)
            }
        }
        .environment(\.colorScheme, .dark)
        .padding(8)
    }
}

struct WindowCard: View {
    let window: WindowInfo
    let model: PreviewModel
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image = window.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: window.minimized ? "arrow.down.right.and.arrow.up.left" : "macwindow")
                            .font(.system(size: 30)).foregroundStyle(.secondary)
                            .frame(width: 190, height: 110).background(Color.white.opacity(0.06))
                    }
                }
                .frame(maxWidth: 220, maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(hover ? 0.55 : 0.14), lineWidth: hover ? 1.5 : 0.8))
                if hover {
                    Button {
                        WindowService.close(window)
                        model.onRefresh?()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain).padding(5)
                }
            }
            Text(window.title.isEmpty ? (window.appName.isEmpty ? "Window" : window.appName) : window.title)
                .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
        }
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture { WindowService.raise(window); model.onChoose?() }
        .gesture(DragGesture(minimumDistance: 14).onEnded { _ in
            // Dock Peek: drag a preview out and the window lands where you let go.
            WindowService.move(window, to: NSEvent.mouseLocation)
            model.onChoose?()
        })
        .contextMenu {
            Button("Bring to Front") { WindowService.raise(window); model.onChoose?() }
            Divider()
            Button("Left Half") { WindowService.snap(window, "left"); model.onChoose?() }
            Button("Right Half") { WindowService.snap(window, "right"); model.onChoose?() }
            Button("Top Half") { WindowService.snap(window, "top"); model.onChoose?() }
            Button("Bottom Half") { WindowService.snap(window, "bottom"); model.onChoose?() }
            Button("Maximise") { WindowService.snap(window, "max"); model.onChoose?() }
            Button("Centre") { WindowService.snap(window, "center"); model.onChoose?() }
            Divider()
            Button("Minimise") { WindowService.minimize(window); model.onRefresh?() }
            Button("Close") { WindowService.close(window); model.onRefresh?() }
        }
    }
}

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Shows the popover above (or beside) the dock icon the pointer rests on.
@MainActor
final class DockPreviewController {
    private let dock: DockModel
    private let preview = PreviewModel()
    private var panel: PreviewPanel?
    private var cancellables = Set<AnyCancellable>()
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var shownFor: String?
    private var loadTask: Task<Void, Never>?

    /// Screen-space anchor for a slot index: the point on the dock's outer edge above that icon.
    var anchorProvider: ((Int) -> NSPoint?)?

    init(dock: DockModel) {
        self.dock = dock
        preview.onHover = { [weak self] inside in self?.dock.previewHovering = inside }
        preview.onChoose = { [weak self] in self?.hide() }
        preview.onRefresh = { [weak self] in
            guard let self, let id = self.shownFor else { return }
            self.shownFor = nil
            self.show(for: id)
        }
        dock.$hoveredID.combineLatest(dock.$previewHovering)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id, overPreview in self?.changed(id: id, overPreview: overPreview) }
            .store(in: &cancellables)
    }

    private func changed(id: String?, overPreview: Bool) {
        if let id {
            hideWork?.cancel()
            guard shownFor != id else { return }
            showWork?.cancel()
            // Name label almost at once, richer content after a short rest.
            let work = DispatchWorkItem { [weak self] in self?.show(for: id) }
            showWork = work
            let delay = shownFor == nil ? 0.32 : 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else if overPreview {
            hideWork?.cancel()
        } else {
            showWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }
    }

    private func show(for id: String) {
        guard dock.draggingID == nil, let item = dock.item(withID: id) else { return }
        shownFor = id
        loadTask?.cancel()
        switch item.kind {
        case .widget:
            hide()
        case .trash:
            present(.label("Trash"), forItem: id)
        case .folder:
            let files = Self.recentFiles(in: item.url)
            present(.stack(item.name, item.url, files), forItem: id)
        case .app:
            present(.label(item.name), forItem: id)
            guard Prefs.shared.dockPreviews, item.running, let pid = item.pid else { return }
            loadTask = Task { [weak self] in
                let windows = await WindowService.windows(forPID: pid)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.shownFor == id, !windows.isEmpty else { return }
                    self.present(.windows(item.name, windows), forItem: id)
                }
            }
        }
    }

    static func recentFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isHiddenKey]
        guard let all = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.prefix(18).map { $0 }
    }

    private func present(_ content: PreviewContent, forItem id: String) {
        let panel = self.panel ?? build()
        preview.content = content
        guard let slotIndex = dock.slots.firstIndex(where: { $0.id == id }), let anchor = anchorProvider?(slotIndex),
              let host = panel.contentView as? DockHostingView<PreviewView> else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        var origin: NSPoint
        switch dock.edge {
        case "left": origin = NSPoint(x: anchor.x + 4, y: anchor.y - size.height / 2)
        case "right": origin = NSPoint(x: anchor.x - size.width - 4, y: anchor.y - size.height / 2)
        default: origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 6), f.maxX - size.width - 6)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        showWork?.cancel(); loadTask?.cancel()
        shownFor = nil
        dock.previewHovering = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func build() -> PreviewPanel {
        let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let host = DockHostingView(rootView: PreviewView(model: preview))
        host.onHover = { [weak self] inside in self?.preview.onHover?(inside) }
        panel.contentView = host
        self.panel = panel
        return panel
    }
}
