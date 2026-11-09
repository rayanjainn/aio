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
    case pin(Int, String)         // pasted text (⌘↩ unpins)
    case file(String)             // open a file (⌘↩ reveals, ⌥↩ Quick Look)
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
    /// Rows computed asynchronously for the current query (currency rates, translations). Kept across the
    /// engine's result refresh, which used to overwrite them.
    private var asyncRows: [PaletteRow] = []
    /// Running apps, most recently used first — shown as an icon strip above the results when nothing is typed.
    @Published private(set) var runningApps: [RunningApp] = []

    var frontPID: pid_t?
    private var menuCache: [String: MenuEntry] = [:]
    private var windowCache: [String: WindowInfo] = [:]
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
            BuiltinCommand(id: "app.settings", title: "AIO Settings", subtitle: "Shortcuts, Island, Dock, permissions", symbol: "gearshape", keywords: ["preferences", "options", "shortcuts", "permissions"]),
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
            BuiltinCommand(id: "app.diagnostics", title: "AIO Diagnostics", subtitle: "Screens, engine, Now Playing", symbol: "stethoscope", keywords: ["debug", "log", "info"]),
            BuiltinCommand(id: "app.toggleDock", title: "Toggle AIO Dock", subtitle: "Show or hide the Dock", symbol: "dock.rectangle", keywords: ["dock"]),
            BuiltinCommand(id: "app.toggleSystemDock", title: "Hide / show macOS Dock", subtitle: "Replace the system Dock with AIO's", symbol: "dock.arrow.down.rectangle", keywords: ["dock", "system"]),
            BuiltinCommand(id: "app.island", title: "Expand the Island", subtitle: "Open the notch player", symbol: "capsule.portrait", keywords: ["island", "notch", "music"]),
            BuiltinCommand(id: "app.pause", title: "Pause / resume screen memory", subtitle: "Toggle episodic capture", symbol: "pause.circle", keywords: ["memory", "capture", "privacy"]),
            BuiltinCommand(id: "app.reindex", title: "Re-index now", subtitle: "Refresh apps, files, browser and git", symbol: "arrow.triangle.2.circlepath", keywords: ["sync", "index"]),
            BuiltinCommand(id: "app.clipboard", title: "Clipboard History", subtitle: "Everything you copied recently", symbol: "doc.on.clipboard", keywords: ["clip", "paste", "copied"]),
            BuiltinCommand(id: "app.quit", title: "Quit AIO", subtitle: "", symbol: "power", keywords: ["exit"]),
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
        runningApps = AppRecency.shared.ordered(excludingFront: frontPID)
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
    static let appsStripHeight: CGFloat = 86

    var showsApps: Bool { query.isEmpty && chat == nil && !runningApps.isEmpty }

    var totalHeight: CGFloat {
        if chat != nil { return Self.searchHeight + Self.chatBody + Self.footerHeight }
        let strip = showsApps ? Self.appsStripHeight : 0
        if rows.isEmpty { return Self.searchHeight + strip + (message != nil || !query.isEmpty ? 56 + Self.footerHeight : 0) }
        var body: CGFloat = 8
        var last = ""
        for r in rows {
            if r.section != last, !r.section.isEmpty { body += Self.headerHeight }
            last = r.section
            body += Self.rowHeight
        }
        return Self.searchHeight + strip + min(body, Self.maxBody + 8 - strip) + Self.footerHeight
    }

    private func addAsync(_ row: PaletteRow) {
        guard !asyncRows.contains(where: { $0.id == row.id }) else { return }
        asyncRows.append(row)
        rows.removeAll { $0.id == row.id }
        rows.insert(row, at: 0)
        selection = 0
    }

    /// ⌘1…⌘9 and clicks on the strip: bring that app forward.
    func switchToApp(at index: Int) -> Bool {
        guard showsApps, runningApps.indices.contains(index) else { return false }
        let app = runningApps[index]
        if let running = NSRunningApplication(processIdentifier: app.pid) {
            if running.isHidden { running.unhide() }
            running.activate()
        }
        return true
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
        asyncRows = []
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
                    self.addAsync(row)
                }
            }
        }
        if let t = TranslateService.parse(q) {
            Task { [weak self] in
                guard let out = await TranslateService.translate(t.text, to: t.to) else { return }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    let row = PaletteRow(id: "translate", title: out, subtitle: "Translated to \(t.to) — copy", symbol: "character.bubble",
                                         iconPath: nil, tag: t.to.uppercased(), kind: .copy(out), section: "Translate")
                    self.addAsync(row)
                }
            }
        }
        if q.lowercased() == "ip" || q.lowercased() == "my ip" {
            Task { [weak self] in
                guard let url = URL(string: "https://api.ipify.org"),
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty else { return }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    self.rows.append(PaletteRow(id: "ip:public", title: ip, subtitle: "Public IP · ↩ copy", symbol: "globe", iconPath: nil, tag: "",
                                                kind: .copy(ip), section: "Network"))
                }
            }
        }
        let wl = q.lowercased()
        if wl == "win" || wl.hasPrefix("win ") || wl == "windows" {
            let text = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces).lowercased()
            Task { [weak self] in
                let all = await WindowService.allWindows()
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    let words = text.split(separator: " ").map(String.init)
                    let found = all.filter { w in
                        let hay = (w.appName + " " + w.title).lowercased()
                        return words.allSatisfy { hay.contains($0) }
                    }.prefix(40)
                    self.windowCache = Dictionary(found.map { ("win:\($0.key)", $0) }, uniquingKeysWith: { a, _ in a })
                    self.rows = found.map { w in
                        PaletteRow(id: "win:\(w.key)", title: w.title.isEmpty ? w.appName : w.title, subtitle: w.appName + (w.minimized ? " · minimised" : ""),
                                   symbol: "macwindow", iconPath: NSRunningApplication(processIdentifier: w.pid)?.bundleURL?.path, tag: "",
                                   kind: .command("win:\(w.key)"), section: "Windows")
                    }
                    if self.rows.isEmpty {
                        self.rows = [PaletteRow(id: "win:none", title: "No windows match", subtitle: "Needs Accessibility (and Screen Recording for windows on other Spaces)",
                                                symbol: "macwindow", iconPath: nil, tag: "", kind: .copy(""), section: "Windows")]
                    }
                }
            }
        }
        let tl = q.lowercased()
        if tl == "tab" || tl == "tabs" || tl.hasPrefix("tab ") || tl.hasPrefix("tabs ") {
            let text = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
            Task { [weak self] in
                let all = await Task.detached { BrowserTabs.matching(BrowserTabs.list(), text) }.value
                let found = all.prefix(30)
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    let rows = found.map { t in
                        PaletteRow(id: "tab:\(t.id)", title: t.title.isEmpty ? t.url : t.title, subtitle: t.url, symbol: "safari",
                                   iconPath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundle)?.path, tag: "",
                                   kind: .command("tab:\(t.bundle)|\(t.window)|\(t.index)"), section: "Browser tabs")
                    }
                    self.rows = rows.isEmpty
                        ? [PaletteRow(id: "tab:none", title: "No open tabs found", subtitle: "Safari, Chrome, Brave, Arc and Edge are supported — allow Automation when asked",
                                      symbol: "safari", iconPath: nil, tag: "", kind: .copy(""), section: "Browser tabs")]
                        : Array(rows)
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
                    let engineRows = Self.grouped(Self.curate(response.results, forEmptyQuery: q.isEmpty, query: text).map(Self.row(from:)))
                    // Answers that arrived on their own (currency, translation) stay on top.
                    self.rows = self.asyncRows + local.filter { r in !self.asyncRows.contains { $0.id == r.id } } + engineRows + tail
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

    private static var recentCache: (at: Date, rows: [PaletteRow])?

    /// The newest files in Downloads, Desktop and Documents — what you were most likely just working on.
    private static func recentFileRows() -> [PaletteRow] {
        if let c = recentCache, Date().timeIntervalSince(c.at) < 15 { return c.rows }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [(URL, Date)] = []
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for dir in ["Downloads", "Desktop", "Documents"] {
            let url = home.appendingPathComponent(dir)
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for f in items {
                guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                      let m = v.contentModificationDate, m > cutoff else { continue }
                let n = f.lastPathComponent.lowercased()
                if n.hasSuffix(".crdownload") || n.hasSuffix(".download") || n.hasSuffix(".part") || n.hasPrefix(".") { continue }
                found.append((f, m))
            }
        }
        let rows = found.sorted { $0.1 > $1.1 }.prefix(5).map { f, m in
            PaletteRow(id: "recent:\(f.path)", title: f.lastPathComponent,
                       subtitle: f.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"),
                       symbol: "doc", iconPath: f.path, tag: m.formatted(.relative(presentation: .named)), kind: .file(f.path), section: "Recent files")
        }
        recentCache = (Date(), Array(rows))
        return Array(rows)
    }

    /// Commands for the app you were just in: its most useful menu items, plus extras for browsers.
    private func contextRows() -> [PaletteRow] {
        guard let pid = frontPID, let app = NSRunningApplication(processIdentifier: pid) else { return [] }
        let name = app.localizedName ?? "this app"
        let section = "In \(name)"
        var rows: [PaletteRow] = []
        let browsers = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac"]
        if let bid = app.bundleIdentifier, browsers.contains(bid) {
            rows.append(PaletteRow(id: "ctx:tabs", title: "Search open tabs", subtitle: "Every window of every browser", symbol: "safari",
                                   iconPath: nil, tag: "", kind: .command("query:tab "), section: section))
        }
        guard WindowManager.isTrusted else { return rows }
        let wanted = ["New Window", "New Tab", "New", "New Document", "Open…", "Save", "Find…", "Export…", "Print…", "Settings…", "Preferences…"]
        let entries = MenuItemService.entries(forPID: pid)
        var picked: [MenuEntry] = []
        for w in wanted {
            if let e = entries.first(where: { $0.title == w }), !picked.contains(where: { $0.id == e.id }) { picked.append(e) }
            if picked.count >= 5 { break }
        }
        for e in picked {
            menuCache[e.id] = e
            rows.append(PaletteRow(id: "ctx:\(e.id)", title: e.title.replacingOccurrences(of: "…", with: ""), subtitle: e.path, symbol: "filemenu.and.selection",
                                   iconPath: nil, tag: "", kind: .menu(e.id), section: section))
        }
        return rows
    }

    /// What the palette shows before you type: things worth one keystroke, then your running apps.
    private func homeRows() -> [PaletteRow] {
        func cmd(_ id: String, _ title: String, _ sub: String, _ symbol: String) -> PaletteRow {
            PaletteRow(id: "home:\(id)", title: title, subtitle: sub, symbol: symbol, iconPath: nil, tag: "", kind: .command(id), section: "Quick actions")
        }
        func sys(_ id: String, _ title: String, _ sub: String, _ symbol: String) -> PaletteRow {
            PaletteRow(id: "home:\(id)", title: title, subtitle: sub, symbol: symbol, iconPath: nil, tag: "", kind: .system(id), section: "Quick actions")
        }
        var out: [PaletteRow] = Self.recentRows() + contextRows()
        out += [
            cmd("timer.25", "Start a 25-minute focus timer", "Shows in the Island", "timer"),
            cmd("window.left", "Snap window to the left half", "Also ⌃⌥←", "rectangle.lefthalf.filled"),
            cmd("window.right", "Snap window to the right half", "Also ⌃⌥→", "rectangle.righthalf.filled"),
            cmd("window.max", "Maximise window", "Also ⌃⌥↩", "rectangle.inset.filled"),
            cmd("app.switcher", "Switch window", "Also ⌥⇥", "macwindow.on.rectangle"),
            PaletteRow(id: "home:layout", title: "Window layouts", subtitle: "Type  layout <name>  to save the current arrangement", symbol: "rectangle.3.group",
                       iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            PaletteRow(id: "home:translate", title: "Translate", subtitle: "Type  tr es good morning  (any 2-letter language code)", symbol: "character.bubble",
                       iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            PaletteRow(id: "home:tabs", title: "Search browser tabs", subtitle: "Type  tab <words>", symbol: "safari", iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            PaletteRow(id: "home:ai", title: "AI commands", subtitle: "Type  ai  — summarise, fix grammar, explain… on your clipboard", symbol: "sparkles", iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            PaletteRow(id: "home:pins", title: "Pinned text", subtitle: "Type  pin  — keep snippets of the clipboard one command away", symbol: "pin", iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            PaletteRow(id: "home:cal", title: "Today's schedule", subtitle: "Type  cal  — with Join buttons for calls", symbol: "calendar", iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            PaletteRow(id: "home:event", title: "Add an event or reminder", subtitle: "Type  event lunch with Sam tomorrow 1pm   or   remind call mom at 6pm", symbol: "calendar.badge.plus",
                       iconPath: nil, tag: "", kind: .command("query:event "), section: "Quick actions"),
            PaletteRow(id: "home:note", title: "Quick note", subtitle: "Type  note <text>  to jot something down", symbol: "square.and.pencil", iconPath: nil, tag: "", kind: .copy(""), section: "Quick actions"),
            PaletteRow(id: "home:spaces", title: "Spaces", subtitle: "Type  space work  to save your whole setup and switch back any time", symbol: "square.stack.3d.up",
                       iconPath: nil, tag: "", kind: .command("query:space "), section: "Quick actions"),
            cmd("music", "Full-screen music player", "Vinyl, cover or waves  ·  ⌃⌥P", "record.circle"),
            cmd("launcher", "Open the launcher", "All your apps, full screen  ·  ⌃⌥L", "square.grid.3x3.fill"),
            cmd("app.timeline", "Screen Memory timeline", "Browse and search what you've seen", "clock.arrow.circlepath"),
            sys("sys.focus", "Toggle Do Not Disturb", "Needs a Shortcut named “Toggle Do Not Disturb”", "moon"),
            cmd("app.addWidget", "Add a desktop widget", "Clock, weather, music, notes…", "square.grid.2x2"),
            sys("sys.screenshot", "Screenshot selection", "Copies to the clipboard", "camera.viewfinder"),
            sys("sys.pickColor", "Pick a colour", "Copies the hex value", "eyedropper"),
            sys("sys.darkmode", "Toggle dark mode", "", "circle.lefthalf.filled"),
            cmd("app.settings", "AIO settings", "Dock, Island, shortcuts, appearance", "gearshape"),
        ]
        out.append(contentsOf: Self.recentFileRows())
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
        for r in DevTools.results(for: q) {
            out.append(PaletteRow(id: "dev:\(r.symbol):\(r.value.prefix(40))", title: r.title, subtitle: "↩ copy", symbol: r.symbol,
                                  iconPath: nil, tag: "", kind: .copy(r.value), section: "Developer"))
        }
        if lower.hasPrefix("port "), let port = Int(lower.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
            let found = DevTools.listeners(port: port)
            for l in found {
                out.append(PaletteRow(id: "port:\(l.pid)", title: "Quit \(l.name) (pid \(l.pid))", subtitle: "Listening on port \(port) · ⌘↩ force quit",
                                      symbol: "network", iconPath: nil, tag: "", kind: .kill(l.pid), section: "Port \(port)"))
            }
            if found.isEmpty {
                out.append(PaletteRow(id: "port:none", title: "Nothing is listening on port \(port)", subtitle: "", symbol: "network",
                                      iconPath: nil, tag: "", kind: .copy(""), section: "Port \(port)"))
            }
            return out
        }
        if lower == "ip" || lower == "my ip" {
            if let ip = DevTools.localIP() {
                out.append(PaletteRow(id: "ip:local", title: ip, subtitle: "Local IP · ↩ copy", symbol: "wifi", iconPath: nil, tag: "", kind: .copy(ip), section: "Network"))
            }
            return out
        }
        if lower.hasPrefix("widget ") {
            let rest = String(q.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                out.append(PaletteRow(id: "widget.ai", title: "Make a widget: \(rest)", subtitle: "AI writes a command; you approve it before it runs", symbol: "sparkles",
                                      iconPath: nil, tag: "AI", kind: .command("widget.ai:" + rest), section: "Widgets"))
            }
            return out
        }
        if lower == "space" || lower == "spaces" || lower.hasPrefix("space ") {
            let rest = lower.hasPrefix("space ") ? String(q.dropFirst(6)).trimmingCharacters(in: .whitespaces) : ""
            if !rest.isEmpty {
                out.append(PaletteRow(id: "space.save", title: "Save everything as Space “\(rest)”", subtitle: "Dock, windows, browser tabs, wallpaper and glass", symbol: "square.stack.3d.up",
                                      iconPath: nil, tag: "", kind: .command("space.save:" + rest), section: "Spaces"))
            }
            for name in Spaces.all().keys.sorted() where rest.isEmpty || name.lowercased().contains(rest.lowercased()) {
                out.append(PaletteRow(id: "space.use.\(name)", title: "Switch to Space “\(name)”", subtitle: "Restores its Dock, windows, tabs and look", symbol: "square.stack.3d.up.fill",
                                      iconPath: nil, tag: "", kind: .command("space.use:" + name), section: "Spaces"))
            }
            if out.isEmpty {
                out.append(PaletteRow(id: "space.hint", title: "Type a name to save your whole setup", subtitle: "e.g.  space work  ·  later  space work  switches back", symbol: "square.stack.3d.up",
                                      iconPath: nil, tag: "", kind: .copy(""), section: "Spaces"))
            }
            return out
        }
        if lower == "dock" || lower.hasPrefix("dock ") {
            let rest = String(q.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                out.append(PaletteRow(id: "dock.save", title: "Save this Dock as “\(rest)”", subtitle: "Switch back any time with  dock \(rest)", symbol: "square.and.arrow.down",
                                      iconPath: nil, tag: "", kind: .command("dock.save:" + rest), section: "Dock profiles"))
            }
            for name in DockModel.profiles().keys.sorted() where rest.isEmpty || name.lowercased().contains(rest.lowercased()) {
                out.append(PaletteRow(id: "dock.use.\(name)", title: "Switch the Dock to “\(name)”", subtitle: "Pinned apps, folders and widgets", symbol: "dock.rectangle",
                                      iconPath: nil, tag: "", kind: .command("dock.use:" + name), section: "Dock profiles"))
            }
            if out.isEmpty {
                out.append(PaletteRow(id: "dock.hint", title: "Type a name to save this Dock", subtitle: "e.g.  dock work", symbol: "dock.rectangle",
                                      iconPath: nil, tag: "", kind: .copy(""), section: "Dock profiles"))
            }
            return out
        }
        if lower == "cal" || lower == "schedule" || lower == "agenda" || lower == "meetings" {
            CalendarService.shared.start()
            let upcoming = CalendarService.shared.events.filter { $0.end > Date() }.prefix(8)
            for e in upcoming {
                let when = e.allDay ? "All day" : e.start.formatted(date: .abbreviated, time: .shortened)
                out.append(PaletteRow(id: "cal:\(e.id)", title: e.title, subtitle: when + (e.location.map { " · " + $0 } ?? ""),
                                      symbol: e.joinURL != nil ? "video" : "calendar", iconPath: nil, tag: e.joinURL != nil ? "Join" : "",
                                      kind: e.joinURL.map { RowKind.web($0.absoluteString) } ?? RowKind.copy(e.title), section: "Schedule"))
            }
            if out.isEmpty {
                out.append(PaletteRow(id: "cal:none", title: CalendarService.shared.authorized ? "Nothing coming up" : "Allow Calendar access to see your schedule",
                                      subtitle: "Open the Island's Calendar page to grant access", symbol: "calendar", iconPath: nil, tag: "", kind: .copy(""), section: "Schedule"))
            }
            return out
        }
        if lower == "notes" || lower == "note" || lower.hasPrefix("note ") {
            let text = lower == "notes" || lower == "note" ? "" : String(q.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                out.append(PaletteRow(id: "note.add", title: "Save note: " + text, subtitle: "Appends to ~/.cortex/native/quicknotes.md", symbol: "square.and.pencil",
                                      iconPath: nil, tag: "", kind: .command("note.add:" + text), section: "Quick note"))
            }
            for n in QuickNotes.recent(5) {
                out.append(PaletteRow(id: "note:\(n)", title: n, subtitle: "↩ copy", symbol: "note.text", iconPath: nil, tag: "", kind: .copy(n), section: "Recent notes"))
            }
            if out.isEmpty {
                out.append(PaletteRow(id: "note.hint", title: "Type a note after “note”", subtitle: "e.g.  note call Sam about the invoice", symbol: "square.and.pencil",
                                      iconPath: nil, tag: "", kind: .copy(""), section: "Quick note"))
            }
            return out
        }
        if lower.hasPrefix("event ") || lower.hasPrefix("remind ") || lower.hasPrefix("reminder ") || lower.hasPrefix("cal add ") {
            let isReminder = lower.hasPrefix("remind")
            let rest = String(q.dropFirst(lower.hasPrefix("cal add ") ? 8 : lower.hasPrefix("reminder ") ? 9 : lower.hasPrefix("remind ") ? 7 : 6))
            guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return out }
            let p = QuickAdd.parse(rest)
            let when: String = {
                guard let d = p.date else { return isReminder ? "No due time — add one, e.g. “at 6pm”" : "Today, all day — add a time, e.g. “tomorrow 1pm”" }
                return p.hasTime ? d.formatted(.dateTime.weekday(.wide).day().month().hour().minute()) : d.formatted(.dateTime.weekday(.wide).day().month()) + " · all day"
            }()
            out.append(PaletteRow(id: "quickadd", title: (isReminder ? "Remind me: " : "Add event: ") + p.title, subtitle: when,
                                  symbol: isReminder ? "checklist" : "calendar.badge.plus", iconPath: nil, tag: isReminder ? "Reminders" : "Calendar",
                                  kind: .command((isReminder ? "quickadd.reminder:" : "quickadd.event:") + rest), section: isReminder ? "New reminder" : "New event"))
            return out
        }
        if lower == "gh" || lower == "github" || lower.hasPrefix("github ") {
            let gh = GitHubService.shared
            let rest = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces).lowercased()
            if !gh.connected {
                out.append(PaletteRow(id: "gh.connect", title: "Connect GitHub", subtitle: "Settings → Connections: your notifications, PRs and reviews right here",
                                      symbol: "link.circle", iconPath: nil, tag: "", kind: .command("app.settings"), section: "GitHub"))
            } else {
                gh.refresh()
                let groups: [(String, [GHItem])] = [("Waiting for your review", gh.reviewRequests), ("Notifications", gh.notifications),
                                                    ("Your pull requests", gh.myPRs), ("Assigned to you", gh.assigned)]
                for (section, items) in groups {
                    for item in items where rest.isEmpty || item.title.lowercased().contains(rest) || item.repo.lowercased().contains(rest) {
                        let symbol = item.kind == "review" ? "eye" : item.kind == "pr" ? "arrow.triangle.pull" : item.kind == "issue" ? "smallcircle.filled.circle" : "bell"
                        out.append(PaletteRow(id: "gh:\(item.id)", title: item.title,
                                              subtitle: item.repo + (item.number > 0 ? " #\(item.number)" : "") + (item.updated.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""),
                                              symbol: symbol, iconPath: nil, tag: "", kind: .web(item.url.absoluteString), section: section))
                    }
                }
                if !rest.isEmpty, let q = rest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    out.append(PaletteRow(id: "gh.search", title: "Search GitHub for “\(rest)”", subtitle: "github.com", symbol: "magnifyingglass",
                                          iconPath: nil, tag: "", kind: .web("https://github.com/search?q=\(q)"), section: "GitHub"))
                }
                if out.isEmpty {
                    out.append(PaletteRow(id: "gh.empty", title: "All clear on GitHub", subtitle: "No notifications, reviews or open PRs" + (rest.isEmpty ? "" : " matching “\(rest)”"),
                                          symbol: "checkmark.circle", iconPath: nil, tag: "", kind: .web("https://github.com"), section: "GitHub"))
                }
            }
            return out
        }
        if lower == "pin" || lower == "pins" || lower.hasPrefix("pin ") || lower.hasPrefix("pins ") {
            let rest = String(q.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces).lowercased()
            out.append(PaletteRow(id: "pin.add", title: "Pin the current clipboard", subtitle: String((NSPasteboard.general.string(forType: .string) ?? (NSImage(pasteboard: NSPasteboard.general) != nil ? "Image" : "Clipboard is empty")).prefix(70)),
                                  symbol: "pin", iconPath: nil, tag: "", kind: .command("pin.add"), section: "Pinned text"))
            for (i, text) in PinStore.all().enumerated() where rest.isEmpty || text.lowercased().contains(rest) {
                let isImage = text.hasPrefix("img:")
                out.append(PaletteRow(id: "pin:\(i)", title: isImage ? "Pinned image" : String(text.split(separator: "\n").first ?? "").prefix(80).description,
                                      subtitle: "↩ paste  ·  ⌘↩ unpin", symbol: isImage ? "photo" : "pin.fill", iconPath: isImage ? String(text.dropFirst(4)) : nil,
                                      tag: "", kind: .pin(i, text), section: "Pinned"))
            }
            return out
        }
        if lower == "ai" || lower.hasPrefix("ai ") {
            let rest = String(q.dropFirst(2)).trimmingCharacters(in: .whitespaces).lowercased()
            let clip = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let presets: [(String, String, String)] = [
                ("Summarize clipboard", "text.alignleft", "Summarize this in a few short bullet points:"),
                ("Fix grammar", "checkmark.bubble", "Fix the grammar and spelling. Keep the meaning and tone. Return only the corrected text:"),
                ("Explain simply", "lightbulb", "Explain this in simple terms:"),
                ("Translate to English", "character.bubble", "Translate this to English:"),
                ("Reply politely", "arrowshape.turn.up.left", "Write a short, polite reply to this message:"),
                ("Make it shorter", "scissors", "Rewrite this to be shorter and clearer:"),
                ("Write a commit message", "point.topleft.down.curvedto.point.bottomright.up", "Write a concise conventional commit message for this change:"),
            ]
            if !clip.isEmpty && rest.isEmpty {
                let one = String(clip.prefix(200))
                let encoded = one.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                out.append(PaletteRow(id: "act:web", title: "Search the web", subtitle: String(clip.prefix(70)), symbol: "magnifyingglass",
                                      iconPath: nil, tag: "", kind: .web("https://www.google.com/search?q=" + encoded), section: "AI commands"))
                out.append(PaletteRow(id: "act:note", title: "Save as a note", subtitle: String(clip.prefix(70)), symbol: "square.and.pencil",
                                      iconPath: nil, tag: "", kind: .command("note.add:" + one.replacingOccurrences(of: "\n", with: " ")), section: "AI commands"))
                out.append(PaletteRow(id: "act:pin", title: "Pin it", subtitle: "Keep it one command away", symbol: "pin",
                                      iconPath: nil, tag: "", kind: .command("pin.add"), section: "AI commands"))
            }
            for (title, symbol, prompt) in presets where rest.isEmpty || title.lowercased().contains(rest) {
                out.append(PaletteRow(id: "aipreset:\(title)", title: title, subtitle: clip.isEmpty ? "Copy some text first" : String(clip.prefix(70)), symbol: symbol,
                                      iconPath: nil, tag: "AI", kind: clip.isEmpty ? .copy("") : .ai(prompt + "\n\n" + clip), section: "AI commands"))
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
                out.append(PaletteRow(id: "ai", title: p, subtitle: "Ask AI", symbol: "sparkles", iconPath: nil, tag: "",
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
        out.append(PaletteRow(id: "ai:ask", title: "Ask AI: “\(q)”", subtitle: ["openai": "Your AI server (Settings → AI)", "ollamaCloud": "Ollama Cloud"][AISettings.load().provider] ?? "Local model via Ollama", symbol: "sparkles", iconPath: nil, tag: "",
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

    /// Cleans an engine result list: drops blanks, files that no longer exist, and repeats
    /// (the same file indexed twice, or under a different letter-case of its path).
    static func curate(_ results: [EngineResult], forEmptyQuery empty: Bool, query: String = "",
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [EngineResult] {
        var seen = Set<String>()
        var cleaned: [EngineResult] = []
        var perSource: [String: Int] = [:]
        let tokens = searchTokens(query)
        for r in results {
            if !empty, !tokens.isEmpty, !relevant(r, tokens: tokens) { continue }
            if !empty, perSource[r.pluginId, default: 0] >= sourceLimit(r.pluginId) { continue }
            if r.pluginId == "browser", (r.url ?? "").hasPrefix("file://") { continue }
            if r.title.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if r.pluginId == "files" || r.sourceType == "file", let p = r.path, !fileExists(p) { continue }
            let identity = (r.path ?? r.url ?? (r.title + "|" + (r.subtitle ?? ""))).lowercased()
            guard seen.insert(r.pluginId + "|" + identity).inserted else { continue }
            perSource[r.pluginId, default: 0] += 1
            cleaned.append(r)
        }
        guard empty else { return ranked(cleaned) }
        let wanted = ["apps", "commands", "clipboard"]
        let picked = cleaned.filter { wanted.contains($0.pluginId) }
        return Array((picked.isEmpty ? cleaned : picked).prefix(10))
    }

    static func searchTokens(_ q: String) -> [String] {
        q.lowercased().split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    /// The engine matches loosely (good for typos in app names, bad for clipboard and history, where it surfaces
    /// rows that share no word with the query). Apps and commands keep fuzzy matching — their title must contain
    /// the query's letters in order; everything else must contain every word typed.
    static func relevant(_ r: EngineResult, tokens: [String]) -> Bool {
        let hay = [r.title, r.subtitle ?? "", r.path ?? "", r.url ?? "", r.content ?? ""].joined(separator: " ").lowercased()
        if r.pluginId == "apps" || r.pluginId == "commands" {
            let title = r.title.lowercased()
            let joined = tokens.joined()
            return tokens.allSatisfy { hay.contains($0) } || isSubsequence(joined, of: title) || initials(of: title).hasPrefix(joined)
        }
        return tokens.allSatisfy { hay.contains($0) }
    }

    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle where c != " " {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// "visual studio code" → "vsc"
    static func initials(of s: String) -> String {
        String(s.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).compactMap(\.first))
    }

    static func sourceLimit(_ plugin: String) -> Int {
        switch plugin {
        case "apps": 6
        case "commands", "files": 5
        case "clipboard", "shell", "git": 3
        default: 4
        }
    }

    /// Apps first (running ones before the rest), then commands, files and everything else in the engine's order.
    static func ranked(_ results: [EngineResult]) -> [EngineResult] {
        let order = ["apps", "commands", "files", "browser", "github", "calendar", "email", "clipboard", "shell", "git"]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        return results.enumerated().sorted { a, b in
            let pa = order.firstIndex(of: a.element.pluginId) ?? order.count
            let pb = order.firstIndex(of: b.element.pluginId) ?? order.count
            if pa != pb { return pa < pb }
            if a.element.pluginId == "apps" {
                let ra = running.contains(a.element.path ?? ""), rb = running.contains(b.element.path ?? "")
                if ra != rb { return ra }
            }
            return a.offset < b.offset
        }.map(\.element)
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
        case .file: return [("↩", "Open"), ("⌘↩", "Reveal"), ("⌥↩", "Quick Look")]
        case .pin: return [("↩", "Paste"), ("⌘↩", "Unpin")]
        }
    }

    /// Runs the selected row. Returns true when the palette should close.
    /// Remembers what was run so the empty palette can offer it again.
    private func remember(_ row: PaletteRow) {
        let entry: RecentCommand?
        switch row.kind {
        case .command(let id) where !id.hasPrefix("query:") && !id.hasPrefix("note.add:") && !id.hasPrefix("tab:") && !id.hasPrefix("win:"):
            entry = RecentCommand(title: row.title, subtitle: row.subtitle, symbol: row.symbol, iconPath: row.iconPath, type: "command", value: id)
        case .system(let id):
            entry = RecentCommand(title: row.title, subtitle: row.subtitle, symbol: row.symbol, iconPath: nil, type: "system", value: id)
        case .web(let u):
            entry = RecentCommand(title: row.title, subtitle: u, symbol: row.symbol, iconPath: nil, type: "web", value: u)
        case .file(let p):
            entry = RecentCommand(title: row.title, subtitle: row.subtitle, symbol: row.symbol, iconPath: p, type: "file", value: p)
        case .engine(let r) where r.path?.hasSuffix(".app") == true:
            entry = RecentCommand(title: r.title, subtitle: "Application", symbol: "app", iconPath: r.path, type: "file", value: r.path ?? "")
        default:
            entry = nil
        }
        if let entry, !entry.value.isEmpty { RecentCommands.record(entry) }
    }

    static func recentRows() -> [PaletteRow] {
        RecentCommands.all().prefix(5).enumerated().map { i, r in
            let kind: RowKind
            switch r.type {
            case "system": kind = .system(r.value)
            case "web": kind = .web(r.value)
            case "file": kind = .file(r.value)
            default: kind = .command(r.value)
            }
            return PaletteRow(id: "recent:\(i):\(r.value)", title: r.title, subtitle: r.subtitle, symbol: r.symbol, iconPath: r.iconPath,
                              tag: "", kind: kind, section: "Recent")
        }
    }

    func activateSelection(modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let row = selectedRow else { return false }
        if modifiers.isEmpty { remember(row) }
        let cmd = modifiers.contains(.command), shift = modifiers.contains(.shift)
        switch row.kind {
        case .copy(let value):
            copy(value)
            return true
        case .command(let id):
            if id == "app.clipboard" { query = "clip "; return false }
            if id.hasPrefix("query:") { query = String(id.dropFirst(6)); return false }
            if id.hasPrefix("win:"), let w = windowCache[id] { WindowService.raise(w); return true }
            if id == "app.memory" { query = "mem "; return false }
            if id.hasPrefix("quickadd.") {
                let reminder = id.hasPrefix("quickadd.reminder:")
                let p = QuickAdd.parse(String(id.drop(while: { $0 != ":" }).dropFirst()))
                Task { @MainActor in
                    let error: String?
                    if reminder {
                        error = await CalendarService.shared.addReminder(title: p.title, due: p.date)
                    } else {
                        error = await CalendarService.shared.addEvent(title: p.title, start: p.date ?? Calendar.current.startOfDay(for: Date()), allDay: !p.hasTime)
                    }
                    Toast.show(error == nil ? (reminder ? "checklist" : "calendar.badge.checkmark") : "exclamationmark.triangle",
                               error ?? (reminder ? "Reminder added: \(p.title)" : "Added to your calendar: \(p.title)"))
                }
                return true
            }
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
        case .paste(let raw):
            if SnippetForm.needsInput(raw) {
                let front = frontPID
                DispatchQueue.main.async {
                    guard let filled = SnippetForm.fill(raw) else { return }
                    PasteService.copy(SnippetExpander.expand(filled))
                    if let front { NSRunningApplication(processIdentifier: front)?.activate() }
                    PasteService.pasteIntoFront(after: 0.35)
                }
                return true
            }
            let text = SnippetExpander.expand(raw)
            PasteService.copy(text)
            PasteService.pasteIntoFront()
            return true
        case .menu(let id):
            if let e = menuCache[id] { MenuItemService.press(e) }
            return true
        case .kill(let pid):
            if let app = NSRunningApplication(processIdentifier: pid) { if cmd { app.forceTerminate() } else { app.terminate() } }
            return true
        case .pin(let index, let text):
            if cmd { PinStore.remove(at: index); queryChanged(); return false }
            if text.hasPrefix("img:"), let image = NSImage(contentsOfFile: String(text.dropFirst(4))) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                PasteService.pasteIntoFront()
                return true
            }
            PasteService.copy(text)
            PasteService.pasteIntoFront()
            return true
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            if modifiers.contains(.option) {
                DispatchQueue.global().async { _ = SystemCommands.shell("/usr/bin/qlmanage", ["-p", path]) }
            } else if cmd {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
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


struct RunningApp: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let path: String
    let isHidden: Bool
    var id: pid_t { pid }
}

/// Remembers the order apps were last used in, so the palette can list them most-recent first.
@MainActor
final class AppRecency {
    static let shared = AppRecency()
    private var order: [pid_t] = []

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication { order = [front.processIdentifier] }
        NotificationCenter.default.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main,
                                               using: { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { AppRecency.shared.touch(pid) }
        })
    }

    func start() {}

    private func touch(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
        if order.count > 60 { order.removeLast(order.count - 60) }
    }

    /// Regular apps, most recently used first; the app the palette was opened over goes last (you're already in it).
    func ordered(excludingFront front: pid_t?) -> [RunningApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        func rank(_ a: NSRunningApplication) -> Int {
            if a.processIdentifier == front { return Int.max }
            return order.firstIndex(of: a.processIdentifier) ?? (order.count + 1)
        }
        return apps.sorted { rank($0) == rank($1) ? ($0.localizedName ?? "") < ($1.localizedName ?? "") : rank($0) < rank($1) }
            .prefix(14)
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", path: $0.bundleURL?.path ?? "", isHidden: $0.isHidden) }
    }
}
