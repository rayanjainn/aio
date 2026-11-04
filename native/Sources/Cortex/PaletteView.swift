import SwiftUI
import AppKit

/// A single-line text field that hands arrow keys, Return and Escape to the palette
/// (SwiftUI's TextField can't intercept them reliably).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "Search apps, files, commands…"
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastFocusToken = -1
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)): parent.onMove(1); return true
            default: return false
            }
        }
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    let onClose: () -> Void

    static let width: CGFloat = 720
    static let rowHeight: CGFloat = 50
    static let searchHeight: CGFloat = 64
    static let footerHeight: CGFloat = 34

    static func height(forRows count: Int, hasMessage: Bool) -> CGFloat {
        let body = count == 0 ? (hasMessage ? 44 : 0) : CGFloat(min(count, 8)) * rowHeight + 8
        return searchHeight + body + (count == 0 && !hasMessage ? 0 : footerHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
                SearchField(text: $model.query, focusToken: model.focusToken,
                            onMove: { model.moveSelection($0) },
                            onSubmit: { if model.activateSelection() { onClose() } },
                            onCancel: onClose)
                    .frame(height: 30)
            }
            .padding(.horizontal, 20)
            .frame(height: Self.searchHeight)

            if !model.rows.isEmpty {
                Divider().opacity(0.4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                RowView(row: row, selected: index == model.selection)
                                    .id(row.id)
                                    .onTapGesture {
                                        model.selection = index
                                        if model.activateSelection() { onClose() }
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selection) { _, new in
                        if model.rows.indices.contains(new) { proxy.scrollTo(model.rows[new].id) }
                    }
                }
                footer
            } else if let message = model.message {
                Divider().opacity(0.4)
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary).frame(height: 44)
                footer
            }
        }
        .frame(width: Self.width, height: Self.height(forRows: model.rows.count, hasMessage: model.message != nil && model.rows.isEmpty), alignment: .top)
        .cortexGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), darken: 0.42)
        .environment(\.colorScheme, .dark)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "navigate")
            hint("↩", "open")
            hint("esc", "close")
            Spacer()
            Text(model.engineReady ? "Cortex" : "Starting engine…").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: Self.footerHeight)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct RowView: View {
    let row: PaletteRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(row.tag).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: PaletteView.rowHeight)
        .background(selected ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let glyph = row.glyph {
            Text(glyph).font(.system(size: 22)).frame(width: 30, height: 30)
        } else if let path = row.iconPath {
            Image(nsImage: IconCache.icon(forPath: path)).resizable().interpolation(.high)
        } else {
            Image(systemName: row.symbol).font(.system(size: 18)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        if cache.count > 400 { cache.removeAll() }
        cache[path] = image
        return image
    }
}
