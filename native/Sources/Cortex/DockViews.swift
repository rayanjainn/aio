import SwiftUI

struct DockRootView: View {
    @ObservedObject var model: DockModel
    @State private var pointer: CGFloat?   // pointer position along the bar's axis

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
                    DockIcon(model: model, item: item, itemIndex: itemIndexes[item.id] ?? 0, scale: scale(at: index))
                case .divider:
                    Capsule().fill(Color.white.opacity(0.22))
                        .frame(width: vertical ? model.iconSize * 0.6 : 1.5, height: vertical ? 1.5 : model.iconSize * 0.6)
                        .frame(width: vertical ? nil : DockModel.dividerLength, height: vertical ? DockModel.dividerLength : model.iconSize)
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): pointer = vertical ? point.y : point.x
            case .ended: pointer = nil
            }
        }
        .padding(DockModel.padding)
        .cortexGlass(in: RoundedRectangle(cornerRadius: model.iconSize * 0.42, style: .continuous), darken: model.darken)
    }

    /// Smooth bell curve around the pointer, measured against each slot's resting centre.
    private func scale(at index: Int) -> CGFloat {
        guard model.magnify, model.draggingID == nil, let p = pointer else { return 1 }
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
            .onTapGesture { model.activate(item) }
            .gesture(dragGesture, including: item.kind == .trash ? .subviews : .all)
            .onHover { inside in
                if inside { model.hoveredID = item.id }
                else if model.hoveredID == item.id { model.hoveredID = nil }
            }
            .contextMenu { menu }
            .dropDestination(for: URL.self) { urls, _ in
                guard item.kind == .app else { return false }
                model.open(urls, with: item)
                return true
            } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private func stack(size: CGFloat, launching: Bool) -> some View {
        let dot = Circle().fill(Color.white.opacity(item.running ? 0.85 : 0)).frame(width: 4, height: 4)
        switch model.edge {
        case "left": HStack(spacing: 3) { dot; icon(size, launching) }
        case "right": HStack(spacing: 3) { icon(size, launching); dot }
        default: VStack(spacing: 3) { icon(size, launching); dot }
        }
    }

    private func icon(_ size: CGFloat, _ launching: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !launching)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let bounce = launching ? -abs(sin(t * 5.5)) * size * 0.32 : 0
            Image(nsImage: model.icon(for: item))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .scaleEffect(scale, anchor: anchor)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: scale)
                .offset(x: model.edge == "bottom" ? 0 : (model.edge == "left" ? -bounce : bounce),
                        y: model.edge == "bottom" ? bounce : 0)
                .overlay(alignment: .topTrailing) { badge }
        }
    }

    @ViewBuilder private var badge: some View {
        if let text = item.badge, !text.isEmpty {
            Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color.white))
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
                Button("Hide") { model.hide(item) }
                Button("Quit") { model.quit(item) }
                Button("Force Quit") { model.forceQuit(item) }
            }
            Button("Show in Finder") { model.reveal(item) }
            Divider()
            if item.pinned { Button("Remove from Dock") { model.unpin(item) } }
            else { Button("Keep in Dock") { model.pin(item) } }
        case .folder:
            Button("Open in Finder") { model.activate(item) }
            Button("Remove from Dock") { model.unpin(item) }
        case .trash:
            Button("Open Trash") { model.activate(item) }
        }
    }
}
