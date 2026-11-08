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
        model.chat != nil ? "Ask a follow-up…" : "Search apps, files, commands…"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if model.showsApps {
                Divider().opacity(0.35)
                RunningAppsStrip(apps: model.runningApps) { i in
                    if model.switchToApp(at: i) { onClose() }
                }
                .frame(height: PaletteModel.appsStripHeight)
                .transition(.opacity)
            }
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
                        RowView(row: row, selected: index == model.selection, ns: selectionNS, query: model.query)
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
    var query: String = ""

    /// The title with the part you typed in full white and the rest a touch softer.
    private var title: AttributedString {
        var a = AttributedString(row.title)
        a.foregroundColor = .white.opacity(0.88)
        let needle = query.split(separator: " ").last.map(String.init) ?? ""
        guard needle.count >= 1, let r = a.range(of: needle, options: .caseInsensitive) else { return a }
        a[r].foregroundColor = .white
        a[r].font = .system(size: 14, weight: .bold)
        return a
    }

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 32, height: 32)
                .shadow(color: .black.opacity(selected ? 0.35 : 0.18), radius: selected ? 4 : 2, y: 1)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(selected ? 0.62 : 0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !row.tag.isEmpty {
                Text(row.tag).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            }
            if selected {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.12)))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PaletteModel.rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.17), Color.white.opacity(0.11)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
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
            Image(systemName: row.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(selected ? 0.22 : 0.14), Color.white.opacity(selected ? 0.10 : 0.06)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
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


/// Running apps as large icons above the results: click (or ⌘1…⌘9) to switch.
struct RunningAppsStrip: View {
    let apps: [RunningApp]
    let onPick: (Int) -> Void
    @State private var hovered: pid_t?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                    Button { onPick(i) } label: {
                        VStack(spacing: 3) {
                            ZStack(alignment: .bottomTrailing) {
                                Image(nsImage: IconCache.icon(forPath: app.path)).resizable().interpolation(.high)
                                    .frame(width: 40, height: 40)
                                    .opacity(app.isHidden ? 0.55 : 1)
                                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
                                if i < 9 {
                                    Text("\(i + 1)").font(.system(size: 8.5, weight: .bold).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 13, height: 13)
                                        .background(Circle().fill(.black.opacity(0.55)))
                                        .offset(x: 3, y: 3)
                                        .opacity(hovered == app.pid || i < 3 ? 1 : 0.0)
                                }
                            }
                            Text(app.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .foregroundStyle(.white.opacity(hovered == app.pid ? 0.95 : 0.6))
                                .frame(width: 62)
                        }
                        .frame(width: 66, height: 70)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.white.opacity(hovered == app.pid ? 0.12 : 0)))
                        .scaleEffect(hovered == app.pid ? 1.04 : 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { hovered = h ? app.pid : (hovered == app.pid ? nil : hovered) } }
                    .help(i < 9 ? "\(app.name)  ·  ⌘\(i + 1)" : app.name)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}
