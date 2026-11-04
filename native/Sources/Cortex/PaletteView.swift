import SwiftUI
import AppKit

/// A single-line text field that hands arrow keys, Return (with modifiers) and Escape to the
/// palette — SwiftUI's TextField can't intercept them reliably.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: (NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 21, weight: .regular)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
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
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                parent.onSubmit(flags)
                return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertBacktab(_:)): parent.onMove(-1); return true
            default: return false
            }
        }
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @ObservedObject private var prefs = Prefs.shared
    let onClose: () -> Void
    @State private var appeared = false
    @Namespace private var selectionNS

    static let width: CGFloat = 740

    private var placeholder: String {
        model.chat != nil ? "Ask a follow-up…" : "Search apps, files, commands…   (try 12*4, 10km to mi, :heart, > ls, ? why)"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if model.chat != nil {
                Divider().opacity(0.35)
                ChatPane(model: model)
                footer
            } else if !model.rows.isEmpty {
                Divider().opacity(0.35)
                results
                footer
            } else if let text = emptyText {
                Divider().opacity(0.35)
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).frame(height: 56)
                footer
            }
        }
        .frame(width: Self.width, height: model.totalHeight, alignment: .top)
        .cortexGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), darken: prefs.paletteDarken)
        .glassRim(cornerRadius: 28)
        .environment(\.colorScheme, .dark)
        .scaleEffect(appeared ? 1 : 0.965, anchor: .top)
        .opacity(appeared ? 1 : 0.4)
        .onChange(of: model.focusToken) { _, _ in
            appeared = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true }
        }
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true } }
    }

    private var emptyText: String? {
        if let m = model.message { return m }
        return model.query.isEmpty ? nil : "No results"
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: model.chat != nil ? "sparkles" : "magnifyingglass")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 22)
            SearchField(text: $model.query, focusToken: model.focusToken, placeholder: placeholder,
                        onMove: { model.moveSelection($0) },
                        onSubmit: { flags in
                            if model.chat != nil { return }
                            if model.activateSelection(modifiers: flags) { onClose() }
                        },
                        onCancel: { if model.handleCancel() { onClose() } })
                .frame(height: 30)
        }
        .padding(.horizontal, 22)
        .frame(height: PaletteModel.searchHeight)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || model.rows[index - 1].section != row.section, !row.section.isEmpty {
                            Text(row.section.uppercased())
                                .font(.system(size: 10.5, weight: .semibold)).tracking(0.7)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)
                                .frame(height: PaletteModel.headerHeight, alignment: .bottom)
                                .padding(.bottom, 4)
                        }
                        RowView(row: row, selected: index == model.selection, ns: selectionNS)
                            .id(row.id)
                            .onTapGesture {
                                model.selection = index
                                if model.activateSelection() { onClose() }
                            }
                    }
                }
                .padding(.vertical, 4)
                .animation(.spring(response: 0.26, dampingFraction: 0.86), value: model.selection)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selection) { _, new in
                if model.rows.indices.contains(new) { proxy.scrollTo(model.rows[new].id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.chat != nil {
                hint("esc", "back")
            } else {
                hint("↑↓", "navigate")
                ForEach(Array(model.hints.enumerated()), id: \.offset) { _, h in hint(h.key, h.label) }
                hint("esc", model.query.isEmpty ? "close" : "clear")
            }
            Spacer()
            Text(model.engineReady ? "Cortex" : "Starting engine…").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .frame(height: PaletteModel.footerHeight)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ChatPane: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let chat = model.chat {
                    Text(chat.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    if let error = chat.error {
                        Text(error).font(.system(size: 13)).foregroundStyle(.orange)
                    } else if chat.answer.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                    } else {
                        Text((try? AttributedString(markdown: chat.answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(chat.answer))
                            .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(height: PaletteModel.chatBody)
    }
}

struct RowView: View {
    let row: PaletteRow
    let selected: Bool
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !row.tag.isEmpty { Text(row.tag).font(.system(size: 11)).foregroundStyle(.tertiary) }
            if selected { Image(systemName: "return").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12)
        .frame(height: PaletteModel.rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                    .matchedGeometryEffect(id: "selection", in: ns)
            }
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let glyph = row.glyph {
            Text(glyph).font(.system(size: 24)).frame(width: 32, height: 32)
        } else if let path = row.iconPath {
            Image(nsImage: IconCache.icon(forPath: path)).resizable().interpolation(.high)
        } else {
            Image(systemName: row.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
