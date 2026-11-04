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
    case paste(String)            // copy and paste into the front app (snippets)
    case menu(String)             // press a menu item of the front app
    case kill(Int32)              // quit an app (⌘↩ force quits)
    case script(String)           // run a user script
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

    var frontPID: pid_t?
    private var menuCache: [String: MenuEntry] = [:]
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
            BuiltinCommand(id: "app.memory", title: "Search Screen Memory", subtitle: "What was on your screen — type mem, then your words", symbol: "clock.arrow.circlepath", keywords: ["memory", "rewind", "screen", "history", "remember"]),
            BuiltinCommand(id: "app.switcher", title: "Switch Windows", subtitle: "Every window of every app, with previews", symbol: "rectangle.on.rectangle", keywords: ["window", "alt tab", "switcher", "windows"]),
            BuiltinCommand(id: "timer.25", title: "Start Focus Timer (25 min)", subtitle: "Shown live in the Island", symbol: "timer", keywords: ["focus", "pomodoro", "timer", "work"]),
            BuiltinCommand(id: "timer.50", title: "Start Focus Timer (50 min)", subtitle: "", symbol: "timer", keywords: ["focus", "pomodoro", "timer", "deep"]),
            BuiltinCommand(id: "timer.5", title: "Start Break (5 min)", subtitle: "", symbol: "cup.and.saucer", keywords: ["break", "timer", "rest"]),
            BuiltinCommand(id: "timer.stop", title: "Stop Focus Timer", subtitle: "", symbol: "stop.circle", keywords: ["timer", "stop", "cancel"]),
            BuiltinCommand(id: "island.calendar", title: "Island: Calendar", subtitle: "Your next meetings with Join", symbol: "calendar", keywords: ["island", "meeting", "join", "calendar"]),
            BuiltinCommand(id: "island.shelf", title: "Island: Shelf", subtitle: "Files you parked on the notch", symbol: "tray.full", keywords: ["island", "shelf", "files", "airdrop"]),
            BuiltinCommand(id: "island.tools", title: "Island: Tools", subtitle: "Timer, mirror, Shortcuts", symbol: "slider.horizontal.3", keywords: ["island", "mirror", "camera", "shortcuts"]),
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

        if let c = CurrencyService.parse(q) {
            Task { [weak self] in
                guard let value = await CurrencyService.convert(c.amount, from: c.from, to: c.to) else { return }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    let text = String(format: "%.2f %@", value, c.to)
                    let row = PaletteRow(id: "currency", title: text, subtitle: "\(Calculator.format(c.amount)) \(c.from) → \(c.to) · ECB rates", symbol: "dollarsign.circle",
                                         iconPath: nil, tag: "Currency", kind: .copy(text), section: "Calculator")
                    if !self.rows.contains(where: { $0.id == "currency" }) { self.rows.insert(row, at: 0) }
                }
            }
        }
        let ql = q.lowercased()
        if ql == "mem" || ql.hasPrefix("mem ") || ql == "rewind" || ql.hasPrefix("rewind ") {
            let text = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
            if let client {
                searchTask = Task { [weak self] in
                    do {
                        let hits = text.isEmpty ? try await client.timeline(hours: 6) : try await client.searchMemory(text)
                        if Task.isCancelled { return }
                        await MainActor.run {
                            guard let self, self.generation == gen else { return }
                            self.message = nil
                            self.rows = hits.prefix(30).map { h in
                                let when = Date(timeIntervalSince1970: TimeInterval(h.timestamp)).formatted(date: .abbreviated, time: .shortened)
                                return PaletteRow(id: "mem:\(h.id)", title: h.windowTitle.isEmpty ? h.appName : "\(h.appName) — \(h.windowTitle)",
                                                  subtitle: h.snippet, symbol: "clock.arrow.circlepath", iconPath: nil, tag: when,
                                                  kind: h.url.map { .web($0) } ?? .copy(h.snippet), section: "Screen memory")
                            }
                            if self.rows.isEmpty { self.message = "Nothing remembered yet — turn on screen memory in Settings." }
                        }
                    } catch {
                        await MainActor.run { self?.message = "Search engine isn't ready" }
                    }
                }
            }
            return
        }
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

    /// What the palette shows before you type: things worth one keystroke, then your running apps.
    private func homeRows() -> [PaletteRow] {
        func cmd(_ id: String, _ title: String, _ sub: String, _ symbol: String) -> PaletteRow {
            PaletteRow(id: "home:\(id)", title: title, subtitle: sub, symbol: symbol, iconPath: nil, tag: "", kind: .command(id), section: "Quick actions")
        }
        func sys(_ id: String, _ title: String, _ sub: String, _ symbol: String) -> PaletteRow {
            PaletteRow(id: "home:\(id)", title: title, subtitle: sub, symbol: symbol, iconPath: nil, tag: "", kind: .system(id), section: "Quick actions")
        }
        var out: [PaletteRow] = [
            cmd("timer.25", "Start a 25-minute focus timer", "Shows in the Island", "timer"),
            cmd("window.left", "Snap window to the left half", "Also ⌃⌥←", "rectangle.lefthalf.filled"),
            cmd("window.right", "Snap window to the right half", "Also ⌃⌥→", "rectangle.righthalf.filled"),
            cmd("window.max", "Maximise window", "Also ⌃⌥↩", "rectangle.inset.filled"),
            cmd("app.switcher", "Switch window", "Also ⌥⇥", "macwindow.on.rectangle"),
            PaletteRow(id: "home:layout", title: "Window layouts", subtitle: "Type  layout <name>  to save the current arrangement", symbol: "rectangle.3.group",
                       iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            cmd("app.timeline", "Screen Memory timeline", "Browse and search what you've seen", "clock.arrow.circlepath"),
            sys("sys.focus", "Toggle Do Not Disturb", "Needs a Shortcut named “Toggle Do Not Disturb”", "moon"),
            cmd("app.addWidget", "Add a desktop widget", "Clock, weather, music, notes…", "square.grid.2x2"),
            sys("sys.screenshot", "Screenshot selection", "Copies to the clipboard", "camera.viewfinder"),
            sys("sys.pickColor", "Pick a colour", "Copies the hex value", "eyedropper"),
            sys("sys.darkmode", "Toggle dark mode", "", "circle.lefthalf.filled"),
            cmd("app.settings", "Cortex settings", "Dock, Island, shortcuts, appearance", "gearshape"),
        ]
        let front = NSWorkspace.shared.frontmostApplication
        var n = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != front && app.bundleIdentifier != Bundle.main.bundleIdentifier {
            guard let bid = app.bundleIdentifier, n < 5 else { continue }
            out.append(PaletteRow(id: "home:app:\(bid)", title: app.localizedName ?? bid, subtitle: "Running", symbol: "app", iconPath: app.bundleURL?.path,
                                  tag: "", kind: .command("app:\(bid)"), section: "Running apps"))
            n += 1
        }
        return out
    }

    private func localRows(for q: String) -> [PaletteRow] {
        guard !q.isEmpty else { return homeRows() }
        var out: [PaletteRow] = []

        let lower = q.lowercased()
        if lower == "snip" || lower.hasPrefix("snip ") {
            let rest = String(q.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            for s in SnippetStore.shared.matching(rest) {
                out.append(PaletteRow(id: "snip:\(s.id)", title: s.name, subtitle: String(s.text.split(separator: "\n").first ?? "").prefix(90).description,
                                      symbol: "text.quote", iconPath: nil, tag: s.keyword, kind: .paste(s.text), section: "Snippets"))
            }
            return out
        }
        if lower.hasPrefix("kill ") || lower.hasPrefix("quit ") {
            let rest = String(q.dropFirst(5)).lowercased().trimmingCharacters(in: .whitespaces)
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let name = app.localizedName ?? ""
                guard rest.isEmpty || name.lowercased().contains(rest) else { continue }
                out.append(PaletteRow(id: "kill:\(app.processIdentifier)", title: "Quit \(name)", subtitle: "⌘↩ to force quit", symbol: "xmark.circle",
                                      iconPath: app.bundleURL?.path, tag: "", kind: .kill(app.processIdentifier), section: "Quit"))
            }
            return Array(out.prefix(8))
        }
        if lower == "m" || lower.hasPrefix("m ") || lower == "menu" || lower.hasPrefix("menu ") {
            let rest = String(q.drop(while: { $0 != " " })).lowercased().trimmingCharacters(in: .whitespaces)
            if let pid = frontPID {
                let all = MenuItemService.entries(forPID: pid)
                menuCache = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let words = rest.split(separator: " ").map(String.init)
                for e in all {
                    let hay = (e.path + " " + e.title).lowercased()
                    guard words.allSatisfy({ hay.contains($0) }) else { continue }
                    out.append(PaletteRow(id: e.id, title: e.title, subtitle: e.path, symbol: "filemenu.and.selection", iconPath: nil, tag: "",
                                          kind: .menu(e.id), section: "Menu Items"))
                    if out.count >= 30 { break }
                }
            }
            if out.isEmpty { out.append(PaletteRow(id: "menu:none", title: WindowManager.isTrusted ? "No matching menu items" : "Grant Accessibility to search menus", subtitle: "", symbol: "filemenu.and.selection", iconPath: nil, tag: "", kind: .command("app.settings"), section: "Menu Items")) }
            return out
        }
        if lower == "layout" || lower.hasPrefix("layout ") || lower == "layouts" {
            let rest = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                out.append(PaletteRow(id: "layout.save", title: "Save current windows as “\(rest)”", subtitle: "Remembers where every window is", symbol: "square.and.arrow.down",
                                      iconPath: nil, tag: "", kind: .command("layout.save:\(rest)"), section: "Window layouts"))
            }
            for name in WindowLayouts.names() where rest.isEmpty || name.lowercased().contains(rest.lowercased()) {
                out.append(PaletteRow(id: "layout.\(name)", title: "Restore “\(name)”", subtitle: "Move windows back to where they were", symbol: "rectangle.3.group",
                                      iconPath: nil, tag: "", kind: .command("layout.restore:\(name)"), section: "Window layouts"))
            }
            if out.isEmpty {
                out.append(PaletteRow(id: "layout.hint", title: "Type a name to save this arrangement", subtitle: "e.g.  layout coding", symbol: "rectangle.3.group",
                                      iconPath: nil, tag: "", kind: .copy(""), section: "Window layouts"))
            }
            return out
        }
        if lower.hasPrefix("define ") || lower.hasPrefix("def ") {
            let word = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
            if let d = DictionaryLookup.define(word) {
                out.append(PaletteRow(id: "define", title: word, subtitle: String(d.prefix(140)), symbol: "character.book.closed", iconPath: nil, tag: "",
                                      kind: .copy(d), section: "Dictionary"))
            }
            return out
        }
        if let (link, url) = QuicklinkStore.shared.resolve(q) {
            let rest = q.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            out.append(PaletteRow(id: "quicklink", title: rest.isEmpty ? "Open \(link.name)" : "Search \(link.name) for “\(rest)”", subtitle: url, symbol: "link",
                                  iconPath: nil, tag: link.keyword, kind: .web(url), section: "Quicklinks"))
        }

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
        for s in ScriptService.list() where words.allSatisfy({ s.name.lowercased().contains($0) }) {
            commands.append(PaletteRow(id: "script:" + s.path, title: s.name, subtitle: "Script", symbol: "scroll", iconPath: nil, tag: "",
                                       kind: .script(s.path), section: "Commands"))
        }
        out += commands.prefix(6)
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
            var h: [(String, String)] = [("↩", r.pluginId == "apps" ? "Open" : (r.sourceType == "clipboard_text" ? "Paste" : "Open"))]
            if r.sourceType == "clipboard_text" { h.append(("⌘↩", "Copy")) }
            if r.path != nil { h.append(("⌘↩", "Reveal")); h.append(("⌥↩", "Quick Look")); h.append(("⌘⇧↩", "Copy path")) }
            else if r.url != nil { h.append(("⌘⇧↩", "Copy link")) }
            return h
        case .copy: return [("↩", "Copy")]
        case .command, .system: return [("↩", "Run")]
        case .web: return [("↩", "Open")]
        case .shell: return [("↩", "Run in Terminal")]
        case .ai: return [("↩", "Ask")]
        case .paste: return [("↩", "Paste")]
        case .menu: return [("↩", "Choose")]
        case .kill: return [("↩", "Quit"), ("⌘↩", "Force quit")]
        case .script: return [("↩", "Run")]
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
            if id == "app.memory" { query = "mem "; return false }
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
        case .paste(let text):
            PasteService.copy(text)
            PasteService.pasteIntoFront()
            return true
        case .menu(let id):
            if let e = menuCache[id] { MenuItemService.press(e) }
            return true
        case .kill(let pid):
            if let app = NSRunningApplication(processIdentifier: pid) { if cmd { app.forceTerminate() } else { app.terminate() } }
            return true
        case .script(let path):
            ScriptService.run(ScriptCommand(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path))
            return true
        case .engine(let result):
            if modifiers.contains(.option), let path = result.path {
                // Quick Look, like pressing Space in Finder.
                DispatchQueue.global().async { _ = SystemCommands.shell("/usr/bin/qlmanage", ["-p", path]) }
                return true
            }
            if cmd && shift { copy(result.path ?? result.url ?? result.title); return true }
            if cmd, let path = result.path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return true
            }
            guard let client else { return false }
            let isClip = result.sourceType == "clipboard_text" && !cmd
            Task {
                do {
                    try await client.execute(result.id)
                    if isClip { await MainActor.run { PasteService.pasteIntoFront(after: 0.05) } }
                } catch { Log.warn("execute failed: \(error.localizedDescription)") }
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
