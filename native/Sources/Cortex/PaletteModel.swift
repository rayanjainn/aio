import AppKit
import Combine

/// What a row does when you press Return.
enum RowKind: Equatable {
    case engine(EngineResult)
    case copy(String)             // calculator, unit conversion, emoji
    case command(String)          // an app command ("app.settings", "window.left", …)
    case system(String)           // a SystemCommands id
    case web(String)              // open a URL
    case shell(String)            // run in Terminal
    case ai(String)               // ask the model
}

struct PaletteRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let iconPath: String?
    let tag: String
    let kind: RowKind
    var glyph: String? = nil
    var section: String = ""
}

struct BuiltinCommand {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
}

struct ChatState: Equatable {
    var question: String
    var answer = ""
    var streaming = true
    var error: String?
}

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published private(set) var rows: [PaletteRow] = []
    @Published var selection = 0
    @Published private(set) var engineReady = false
    @Published private(set) var message: String?
    @Published private(set) var chat: ChatState?
    @Published var focusToken = 0

    var client: EngineClient?
    var runBuiltin: ((String) -> Void)?
    private var searchTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var generation = 0

    // MARK: catalogue

    static let builtins: [BuiltinCommand] = {
        var list: [BuiltinCommand] = ShortcutTable.all.filter { $0.group == "Windows" }.map {
            BuiltinCommand(id: $0.id, title: $0.label, subtitle: "Move and resize the front window", symbol: "rectangle.split.2x1",
                           keywords: ["window", "snap", "resize"] + $0.label.lowercased().split(separator: " ").map(String.init))
        }
        list += [
            BuiltinCommand(id: "app.settings", title: "Cortex Settings", subtitle: "Shortcuts, Island, Dock, permissions", symbol: "gearshape", keywords: ["preferences", "options", "shortcuts", "permissions"]),
            BuiltinCommand(id: "app.addWidget", title: "Add a Widget", subtitle: "Clock, calendar, system, now playing, notes, to-dos", symbol: "square.grid.2x2", keywords: ["widgets", "desktop", "clock", "notes"]),
            BuiltinCommand(id: "app.toggleWidgets", title: "Show / hide widgets", subtitle: "", symbol: "eye", keywords: ["widgets", "desktop"]),
            BuiltinCommand(id: "app.diagnostics", title: "Cortex Diagnostics", subtitle: "Screens, engine, Now Playing", symbol: "stethoscope", keywords: ["debug", "log", "info"]),
            BuiltinCommand(id: "app.toggleDock", title: "Toggle Cortex Dock", subtitle: "Show or hide the Dock", symbol: "dock.rectangle", keywords: ["dock"]),
            BuiltinCommand(id: "app.toggleSystemDock", title: "Hide / show macOS Dock", subtitle: "Replace the system Dock with Cortex's", symbol: "dock.arrow.down.rectangle", keywords: ["dock", "system"]),
            BuiltinCommand(id: "app.island", title: "Expand the Island", subtitle: "Open the notch player", symbol: "capsule.portrait", keywords: ["island", "notch", "music"]),
            BuiltinCommand(id: "app.pause", title: "Pause / resume screen memory", subtitle: "Toggle episodic capture", symbol: "pause.circle", keywords: ["memory", "capture", "privacy"]),
            BuiltinCommand(id: "app.reindex", title: "Re-index now", subtitle: "Refresh apps, files, browser and git", symbol: "arrow.triangle.2.circlepath", keywords: ["sync", "index"]),
            BuiltinCommand(id: "app.clipboard", title: "Clipboard History", subtitle: "Everything you copied recently", symbol: "doc.on.clipboard", keywords: ["clip", "paste", "copied"]),
            BuiltinCommand(id: "app.quit", title: "Quit Cortex", subtitle: "", symbol: "power", keywords: ["exit"]),
        ]
        return list
    }()

    private static let sectionNames: [String: String] = [
        "apps": "Applications", "files": "Files", "commands": "System", "browser": "Browser", "git": "Git",
        "github": "GitHub", "clipboard": "Clipboard", "shell": "Shell history", "vscode": "VS Code",
        "calendar": "Calendar", "email": "Mail", "slack": "Slack", "docker": "Docker",
    ]

    // MARK: lifecycle

    func reset() {
        endChat()
        query = ""
        selection = 0
        focusToken += 1
        queryChanged()
    }

    func setEngine(ready: Bool) {
        engineReady = ready
        if ready { queryChanged() }
    }

    // MARK: height

    static let rowHeight: CGFloat = 52
    static let headerHeight: CGFloat = 28
    static let searchHeight: CGFloat = 66
    static let footerHeight: CGFloat = 38
    static let maxBody: CGFloat = 8 * 52 + 3 * 28
    static let chatBody: CGFloat = 270

    var totalHeight: CGFloat {
        if chat != nil { return Self.searchHeight + Self.chatBody + Self.footerHeight }
        if rows.isEmpty { return Self.searchHeight + (message != nil || !query.isEmpty ? 56 + Self.footerHeight : 0) }
        var body: CGFloat = 8
        var last = ""
        for r in rows {
            if r.section != last, !r.section.isEmpty { body += Self.headerHeight }
            last = r.section
            body += Self.rowHeight
        }
        return Self.searchHeight + min(body, Self.maxBody + 8) + Self.footerHeight
    }

    // MARK: searching

    private func queryChanged() {
        searchTask?.cancel()
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespaces)
        if chat != nil { endChat() }
        let local = localRows(for: q)
        let tail = tailRows(for: q)
        rows = local + tail
        selection = 0

        let special = q.hasPrefix(":") || q.hasPrefix(">") || q.hasPrefix("?") || q.lowercased().hasPrefix("ask ")
        guard let client, !special else { message = nil; return }

        // `clip …` searches the clipboard history only.
        var sources: [String]?
        var text = q
        let lower = q.lowercased()
        if lower == "clip" || lower.hasPrefix("clip ") || lower == "cb" || lower.hasPrefix("cb ") {
            sources = ["clipboard"]
            text = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
        }

        searchTask = Task { [weak self] in
            do {
                let response: EngineSearchResponse
                if sources == nil && text.isEmpty { response = try await client.suggestions() }
                else { response = try await client.search(text.isEmpty ? " " : text, limit: 30, sources: sources) }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    self.message = nil
                    let engineRows = Self.grouped(Self.curate(response.results, forEmptyQuery: q.isEmpty).map(Self.row(from:)))
                    self.rows = local + engineRows + tail
                    self.selection = min(self.selection, max(self.rows.count - 1, 0))
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    self.message = self.engineReady ? error.localizedDescription : "Starting the search engine…"
                }
            }
        }
    }

    private func localRows(for q: String) -> [PaletteRow] {
        guard !q.isEmpty else { return [] }
        var out: [PaletteRow] = []

        if q.hasPrefix(":") {
            for e in EmojiSearch.search(String(q.dropFirst()), limit: 8) {
                out.append(PaletteRow(id: "emoji:" + e.name, title: e.name, subtitle: "\(e.c) — copy", symbol: "face.smiling",
                                      iconPath: nil, tag: "", kind: .copy(e.c), glyph: e.c, section: "Emoji"))
            }
            return out
        }
        if q.hasPrefix(">") {
            let cmd = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty {
                out.append(PaletteRow(id: "shell", title: cmd, subtitle: "Run in Terminal", symbol: "terminal", iconPath: nil, tag: "",
                                      kind: .shell(cmd), section: "Shell"))
            }
            return out
        }
        if q.hasPrefix("?") || q.lowercased().hasPrefix("ask ") {
            let prompt = q.hasPrefix("?") ? String(q.dropFirst()) : String(q.dropFirst(4))
            let p = prompt.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty {
                out.append(PaletteRow(id: "ai", title: p, subtitle: "Ask Cortex AI", symbol: "sparkles", iconPath: nil, tag: "",
                                      kind: .ai(p), section: "Ask"))
            }
            return out
        }

        if let c = UnitConverter.convert(q) {
            out.append(PaletteRow(id: "convert", title: c.value, subtitle: c.label, symbol: "arrow.left.arrow.right.circle",
                                  iconPath: nil, tag: "Convert", kind: .copy(c.value), section: "Calculator"))
        }
        if let value = Calculator.evaluate(q) {
            out.append(PaletteRow(id: "calc", title: value, subtitle: q, symbol: "equal.circle",
                                  iconPath: nil, tag: "Calculator", kind: .copy(value), section: "Calculator"))
        }

        let words = q.lowercased().split(separator: " ").map(String.init)
        var commands: [PaletteRow] = []
        for c in Self.builtins {
            let hay = ([c.title.lowercased()] + c.keywords).joined(separator: " ")
            if words.allSatisfy({ hay.contains($0) }) {
                commands.append(PaletteRow(id: "cmd:" + c.id, title: c.title, subtitle: c.subtitle, symbol: c.symbol,
                                           iconPath: nil, tag: "", kind: .command(c.id), section: "Commands"))
            }
        }
        for c in SystemCommands.all {
            let hay = ([c.title.lowercased()] + c.keywords).joined(separator: " ")
            if words.allSatisfy({ hay.contains($0) }) {
                commands.append(PaletteRow(id: "sys:" + c.id, title: c.title, subtitle: c.subtitle, symbol: c.symbol,
                                           iconPath: nil, tag: "", kind: .system(c.id), section: "Commands"))
            }
        }
        out += commands.prefix(5)
        return out
    }

    /// "Search the web" and "Open URL" fallbacks, always last.
    private func tailRows(for q: String) -> [PaletteRow] {
        guard !q.isEmpty, !q.hasPrefix(":"), !q.hasPrefix(">"), !q.hasPrefix("?") else { return [] }
        var out: [PaletteRow] = []
        if !q.contains(" "), q.contains("."), let url = Self.normalizedURL(q) {
            out.append(PaletteRow(id: "openurl", title: q, subtitle: "Open in browser", symbol: "safari", iconPath: nil, tag: "",
                                  kind: .web(url), section: "Web"))
        }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        out.append(PaletteRow(id: "web:google", title: "Search the web for “\(q)”", subtitle: "Google", symbol: "magnifyingglass", iconPath: nil, tag: "",
                              kind: .web("https://www.google.com/search?q=\(encoded)"), section: "Web"))
        out.append(PaletteRow(id: "ai:ask", title: "Ask Cortex AI: “\(q)”", subtitle: "Local model via Ollama", symbol: "sparkles", iconPath: nil, tag: "",
                              kind: .ai(q), section: "Web"))
        return out
    }

    static func normalizedURL(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) != nil ? t : nil }
        let candidate = "https://" + t
        guard let u = URL(string: candidate), let host = u.host, host.contains("."), !host.hasSuffix(".") else { return nil }
        return candidate
    }

    // MARK: engine rows

    static func curate(_ results: [EngineResult], forEmptyQuery empty: Bool) -> [EngineResult] {
        let cleaned = results.filter { r in
            if r.pluginId == "browser", (r.url ?? "").hasPrefix("file://") { return false }
            return !r.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard empty else { return cleaned }
        let wanted = ["apps", "commands", "files", "clipboard"]
        let picked = cleaned.filter { wanted.contains($0.pluginId) }
        return Array((picked.isEmpty ? cleaned : picked).prefix(10))
    }

    /// Groups rows under their section header, keeping the engine's order of first appearance.
    static func grouped(_ rows: [PaletteRow]) -> [PaletteRow] {
        var order: [String] = []
        var buckets: [String: [PaletteRow]] = [:]
        for r in rows {
            if buckets[r.section] == nil { order.append(r.section) }
            buckets[r.section, default: []].append(r)
        }
        return order.flatMap { buckets[$0] ?? [] }
    }

    static func row(from r: EngineResult) -> PaletteRow {
        let symbol: String
        switch r.sourceType {
        case "url": symbol = "globe"
        case "shell_command": symbol = "terminal"
        case "git_commit": symbol = "point.topleft.down.curvedto.point.bottomright.up"
        case "clipboard_text": symbol = "doc.on.clipboard"
        default: symbol = r.pluginId == "commands" ? "command" : "doc"
        }
        let icon = (r.sourceType == "file" || r.pluginId == "apps") ? r.path : nil
        let section = sectionNames[r.pluginId] ?? r.pluginId.capitalized
        return PaletteRow(id: r.id, title: r.title, subtitle: r.subtitle ?? r.path ?? r.url ?? "", symbol: symbol,
                          iconPath: icon, tag: "", kind: .engine(r), section: section)
    }

    // MARK: acting

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    var selectedRow: PaletteRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// The key hints for the footer, for whatever is selected.
    var hints: [(key: String, label: String)] {
        guard let row = selectedRow else { return [] }
        switch row.kind {
        case .engine(let r):
            var h: [(String, String)] = [("↩", r.pluginId == "apps" ? "Open" : (r.sourceType == "clipboard_text" ? "Copy" : "Open"))]
            if r.path != nil { h.append(("⌘↩", "Reveal")); h.append(("⌘⇧↩", "Copy path")) }
            else if r.url != nil { h.append(("⌘⇧↩", "Copy link")) }
            return h
        case .copy: return [("↩", "Copy")]
        case .command, .system: return [("↩", "Run")]
        case .web: return [("↩", "Open")]
        case .shell: return [("↩", "Run in Terminal")]
        case .ai: return [("↩", "Ask")]
        }
    }

    /// Runs the selected row. Returns true when the palette should close.
    func activateSelection(modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let row = selectedRow else { return false }
        let cmd = modifiers.contains(.command), shift = modifiers.contains(.shift)
        switch row.kind {
        case .copy(let value):
            copy(value)
            return true
        case .command(let id):
            if id == "app.clipboard" { query = "clip "; return false }
            runBuiltin?(id)
            return true
        case .system(let id):
            SystemCommands.all.first(where: { $0.id == id })?.run()
            return true
        case .web(let url):
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            return true
        case .shell(let command):
            SystemCommands.runInTerminal(command)
            return true
        case .ai(let prompt):
            startChat(prompt)
            return false
        case .engine(let result):
            if cmd && shift { copy(result.path ?? result.url ?? result.title); return true }
            if cmd, let path = result.path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return true
            }
            guard let client else { return false }
            Task {
                do { try await client.execute(result.id) }
                catch { Log.warn("execute failed: \(error.localizedDescription)") }
            }
            return true
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: AI chat

    func startChat(_ prompt: String) {
        chatTask?.cancel()
        chat = ChatState(question: prompt)
        chatTask = Task { [weak self] in
            do {
                for try await piece in AIChat.stream(prompt) {
                    if Task.isCancelled { return }
                    await MainActor.run { self?.chat?.answer += piece }
                }
                await MainActor.run { self?.chat?.streaming = false }
            } catch {
                await MainActor.run {
                    self?.chat?.streaming = false
                    self?.chat?.error = error.localizedDescription
                }
            }
        }
    }

    func endChat() {
        chatTask?.cancel()
        chatTask = nil
        chat = nil
    }

    /// Escape: leave the chat, then clear the query, then close.
    func handleCancel() -> Bool {
        if chat != nil { endChat(); return false }
        if !query.isEmpty { query = ""; return false }
        return true
    }
}
