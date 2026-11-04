import SwiftUI

struct DockRootView: View {
    @ObservedObject var model: DockModel
    @State private var mouseX: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: DockModel.gap) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    DockIcon(model: model, item: item, scale: scale(at: index))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): mouseX = point.x
                case .ended: mouseX = nil
                }
            }
            .padding(DockModel.padding)
            .cortexGlass(in: RoundedRectangle(cornerRadius: model.iconSize * 0.42, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Smooth bell curve around the pointer, measured against each icon's resting centre.
    private func scale(at index: Int) -> CGFloat {
        guard model.magnify, let x = mouseX else { return 1 }
        let size = model.iconSize
        let centre = CGFloat(index) * (size + DockModel.gap) + size / 2
        let d = (x - centre) / (size * 1.15)
        return 1 + (DockModel.maxScale - 1) * CGFloat(exp(-Double(d * d)))
    }
}

struct DockIcon: View {
    let model: DockModel
    let item: DockItem
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: model.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: model.iconSize, height: model.iconSize)
                .scaleEffect(scale, anchor: .bottom)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: scale)
            Circle()
                .fill(Color.white.opacity(item.running ? 0.85 : 0))
                .frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.activate(item) }
        .help(item.name)
    }
}
