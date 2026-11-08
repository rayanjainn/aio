import SwiftUI

struct DockRootView: View {
    @ObservedObject var model: DockModel

    var body: some View {
        let bar = barView
        Group {
            switch model.edge {
            case "left":
                HStack(spacing: 0) { bar.padding(.vertical, DockModel.sideMargin); Spacer(minLength: 0) }
            case "right":
                HStack(spacing: 0) { Spacer(minLength: 0); bar.padding(.vertical, DockModel.sideMargin) }
            default:
                VStack(spacing: 0) { Spacer(minLength: 0); bar.padding(.horizontal, DockModel.sideMargin) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var barView: some View {
        let vertical = model.isVertical
        let layout: AnyLayout = vertical
            ? AnyLayout(VStackLayout(alignment: model.edge == "left" ? .leading : .trailing, spacing: DockModel.gap))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: DockModel.gap))
        let itemIndexes = Dictionary(uniqueKeysWithValues: model.items.enumerated().map { ($1.id, $0) })
        return layout {
            ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in
                switch slot {
                case .item(let item):
                    DockIcon(model: model, item: item, itemIndex: itemIndexes[item.id] ?? 0, scale: scale(at: index), isFront: model.frontBundle == item.value)
                case .divider:
                    Capsule().fill(Color.white.opacity(0.22))
                        .frame(width: vertical ? model.iconSize * 0.6 : 1.5, height: vertical ? 1.5 : model.iconSize * 0.6)
                        .frame(width: vertical ? nil : DockModel.dividerLength, height: vertical ? DockModel.dividerLength : model.iconSize)
                }
            }
        }
        .padding(DockModel.padding)
        .cortexGlass(in: RoundedRectangle(cornerRadius: model.iconSize * CGFloat(Prefs.shared.dockRoundness), style: .continuous), darken: model.darken)
        .glassRim(cornerRadius: model.iconSize * CGFloat(Prefs.shared.dockRoundness), strength: 0.8)
        .contextMenu { barMenu }
    }

    @ViewBuilder private var barMenu: some View {
        Toggle("Magnify icons", isOn: Binding(get: { Prefs.shared.dockMagnify }, set: { Prefs.shared.dockMagnify = $0 }))
        Toggle("Hide automatically", isOn: Binding(get: { Prefs.shared.dockAutohide }, set: { Prefs.shared.dockAutohide = $0 }))
        Menu("Size") {
            ForEach([32, 38, 44, 52, 60, 72], id: \.self) { s in
                Button("\(s) pt") { Prefs.shared.dockIconSize = Double(s) }
            }
        }
        Toggle("Group running apps", isOn: Binding(get: { Prefs.shared.dockGroupRunning }, set: { Prefs.shared.dockGroupRunning = $0 }))
        Menu("Add widget") {
            ForEach(DockWidgetKind.all) { k in
                Button(k.title) { if model.hasWidget(k.id) { model.removeWidget(k.id) } else { model.addWidget(k.id) } }
            }
        }
        Menu("Presets") {
            ForEach(DockPreset.all) { preset in
                Button("\(preset.name) — \(preset.detail)") { preset.apply(to: model) }
            }
        }
        Menu("Widget style") {
            ForEach(DockWidgetTheme.all) { t in
                Button((Prefs.shared.dockWidgetTheme == t.id ? "✓ " : "") + t.name) { Prefs.shared.dockWidgetTheme = t.id }
            }
        }
        Menu("Position") {
            ForEach(["bottom", "left", "right"], id: \.self) { e in
                Button(e.capitalized) { Prefs.shared.dockEdge = e }
            }
        }
        Divider()
        Button("Dock Settings…") { (NSApp.delegate as? AppDelegate)?.openSettings() }
    }

    /// Smooth bell curve around the pointer, measured against each slot's resting centre.
    private func scale(at index: Int) -> CGFloat {
        guard model.magnify, model.draggingID == nil, let p = model.pointer else { return 1 }
        let size = model.iconSize
        let d = (p - model.centre(ofSlot: index)) / (size * 1.15)
        return 1 + (DockModel.maxScale - 1) * CGFloat(exp(-Double(d * d)))
    }
}

struct DockIcon: View {
    let model: DockModel
    let item: DockItem
    let itemIndex: Int
    let scale: CGFloat
    var isFront = false
    @State private var drag: CGSize = .zero
    @State private var dropTargeted = false

    private var anchor: UnitPoint {
        switch model.edge {
        case "left": .leading
        case "right": .trailing
        default: .bottom
        }
    }

    var body: some View {
        let size = model.iconSize
        let launching = model.launching.contains(item.id)
        stack(size: size, launching: launching)
            .offset(drag)
            .zIndex(drag == .zero ? 0 : 10)
            .opacity(dropTargeted ? 0.7 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                model.activate(item)
            }
            .gesture(dragGesture, including: item.kind == .trash ? .subviews : .all)
            .contextMenu { menu }
            .dropDestination(for: URL.self) { urls, _ in
                guard item.kind == .app else { return false }
                model.open(urls, with: item)
                return true
            } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private func stack(size: CGFloat, launching: Bool) -> some View {
        let front = item.kind == .app && isFront
        let show = item.running && Prefs.shared.dockIndicators
        let dot = Capsule()
            .fill(Color.white.opacity(show ? (front ? 1 : 0.7) : 0))
            .frame(width: front ? 12 : 4, height: 4)
            .shadow(color: .white.opacity(front && show ? 0.8 : 0), radius: 3)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: front)
        // The indicator lives in the bar's padding, so every icon (Trash included) sits dead centre.
        let inset = DockModel.padding / 2 + 1.5
        switch model.edge {
        case "left": icon(size, launching).overlay(alignment: .leading) { dot.rotationEffect(.degrees(90)).offset(x: -inset - 2) }
        case "right": icon(size, launching).overlay(alignment: .trailing) { dot.rotationEffect(.degrees(90)).offset(x: inset + 2) }
        default: icon(size, launching).overlay(alignment: .bottom) { dot.offset(y: inset + 2) }
        }
    }

    @ViewBuilder private func icon(_ size: CGFloat, _ launching: Bool) -> some View {
        if item.kind == .widget {
            let len = model.length(of: item)
            DockWidgetTile(kind: item.value, size: size, compact: len <= size * 1.3 || model.isVertical, model: model)
                .frame(width: len, height: size)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                .scaleEffect(scale, anchor: anchor)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: scale)
        } else {
            appIcon(size, launching)
        }
    }

    private func appIcon(_ size: CGFloat, _ launching: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !launching)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let bounce = launching && Prefs.shared.dockBounce ? -abs(sin(t * 5.5)) * size * 0.32 : 0
            Image(nsImage: model.icon(for: item))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.38), radius: 6, y: 3)
                .scaleEffect(scale, anchor: anchor)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: scale)
                .offset(x: model.edge == "bottom" ? 0 : (model.edge == "left" ? -bounce : bounce),
                        y: model.edge == "bottom" ? bounce : 0)
                .overlay(alignment: .topTrailing) { badge }
        }
    }

    @ViewBuilder private var badge: some View {
        if let raw = item.badge, let text = DockBadge.display(raw) {
            Group {
                if text.isEmpty {
                    Circle().fill(Color.white).frame(width: 10, height: 10)      // long labels become a dot
                } else {
                    Text(text).font(.system(size: 10.5, weight: .bold).monospacedDigit()).foregroundStyle(.black)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.white))
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .offset(x: 6, y: -6)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                drag = v.translation
                model.draggingID = item.id
                model.hoveredID = nil
            }
            .onEnded { v in
                let vertical = model.isVertical
                let along = vertical ? v.translation.height : v.translation.width
                let across = vertical ? v.translation.width : v.translation.height
                let interior = model.edge == "left" ? across : -across
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = .zero }
                model.draggingID = nil
                if interior > 90 {
                    model.unpin(item)
                } else {
                    let steps = Int((along / (model.iconSize + DockModel.gap)).rounded())
                    if steps != 0 { model.move(item.id, toItemIndex: itemIndex + steps) }
                }
            }
    }

    @ViewBuilder private var menu: some View {
        switch item.kind {
        case .app:
            Button(item.running ? "Show" : "Open") { model.activate(item) }
            if item.running {
                Button("Show All Windows") { model.exposé(item) }
                Button("Hide") { model.hide(item) }
                Button("Quit") { model.quit(item) }
                Button("Force Quit") { model.forceQuit(item) }
            }
            Button("Show in Finder") { model.reveal(item) }
            Button("Change Icon…") { model.chooseIcon(for: item) }
            if model.hasCustomIcon(item) { Button("Reset Icon") { model.resetIcon(for: item) } }
            Divider()
            if item.pinned { Button("Remove from Dock") { model.unpin(item) } }
            else { Button("Keep in Dock") { model.pin(item) } }
        case .folder:
            Button("Open in Finder") { model.activate(item) }
            Button("Change Icon…") { model.chooseIcon(for: item) }
            if model.hasCustomIcon(item) { Button("Reset Icon") { model.resetIcon(for: item) } }
            Button("Remove from Dock") { model.unpin(item) }
        case .widget:
            if item.value == "running" {
                Button("Show Running Apps Separately") { Prefs.shared.dockGroupRunning = false }
            } else {
                Button("Remove Widget") { model.removeWidget(item.value) }
            }
        case .trash:
            Button("Open Trash") { model.activate(item) }
        }
    }
}


enum DockBadge {
    /// What to draw for an app's badge: numbers (capped at 99+), short labels as-is, anything longer as a dot ("").
    /// nil means no badge.
    static func display(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let n = Int(t) { return n <= 0 ? nil : (n > 99 ? "99+" : String(n)) }
        return t.count <= 3 ? t : ""
    }
}
