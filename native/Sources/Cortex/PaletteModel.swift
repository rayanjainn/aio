import AppKit
import Combine

/// What a row in the palette can do.
enum RowKind: Equatable {
    case engine(EngineResult)
    case calculator(String)
    case copy(String)             // copy text (unit conversion, emoji)
    case command(String)          // a built-in command id
}

struct PaletteRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String            // SF Symbol, used when there is no file icon
    let iconPath: String?         // real file / app icon
    let tag: String               // small source label on the right
    let kind: RowKind
    var glyph: String? = nil      // emoji shown instead of an icon
}

/// A command that lives in the app itself (window snapping, toggles…).
struct BuiltinCommand {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
}

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published private(set) var rows: [PaletteRow] = []
    @Published var selection = 0
    @Published private(set) var engineReady = false
    @Published private(set) var message: String?
    @Published var focusToken = 0

    var client: EngineClient?
    var runBuiltin: ((String) -> Void)?
    private var searchTask: Task<Void, Never>?
    private var generation = 0

    static let builtins: [BuiltinCommand] = {
        var list: [BuiltinCommand] = ShortcutTable.all.filter { $0.group == "Windows" }.map {
            BuiltinCommand(id: $0.id, title: $0.label, subtitle: "Move and resize the front window", symbol: "rectangle.split.2x1",
                           keywords: ["window", "snap", "resize"] + $0.label.lowercased().split(separator: " ").map(String.init))
        }
        list += [
            BuiltinCommand(id: "app.settings", title: "Cortex Settings", subtitle: "Shortcuts, Island, Dock, permissions", symbol: "gearshape", keywords: ["preferences", "options", "shortcuts", "permissions"]),
            BuiltinCommand(id: "app.diagnostics", title: "Cortex Diagnostics", subtitle: "Screens, engine, Now Playing", symbol: "stethoscope", keywords: ["debug", "log", "info"]),
            BuiltinCommand(id: "app.toggleDock", title: "Toggle Cortex Dock", subtitle: "Show or hide the Dock", symbol: "dock.rectangle", keywords: ["dock"]),
            BuiltinCommand(id: "app.toggleSystemDock", title: "Hide / show macOS Dock", subtitle: "Replace the system Dock with Cortex's", symbol: "dock.arrow.down.rectangle", keywords: ["dock", "system"]),
            BuiltinCommand(id: "app.island", title: "Expand the Island", subtitle: "Open the notch player", symbol: "capsule.portrait", keywords: ["island", "notch", "music"]),
            BuiltinCommand(id: "app.pause", title: "Pause / resume screen memory", subtitle: "Toggle episodic capture", symbol: "pause.circle", keywords: ["memory", "capture", "privacy"]),
            BuiltinCommand(id: "app.reindex", title: "Re-index now", subtitle: "Refresh apps, files, browser and git", symbol: "arrow.triangle.2.circlepath", keywords: ["sync", "index"]),
            BuiltinCommand(id: "app.quit", title: "Quit Cortex", subtitle: "", symbol: "power", keywords: ["exit"]),
        ]
        return list
    }()

    func reset() {
        query = ""
        selection = 0
        focusToken += 1
        queryChanged()
    }

    func setEngine(ready: Bool) {
        engineReady = ready
        if ready { queryChanged() }
    }

    // MARK: searching

    private func queryChanged() {
        searchTask?.cancel()
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespaces)
        let local = localRows(for: q)
        // Show instant local matches immediately; engine results are appended when they arrive.
        rows = local
        selection = 0

        guard let client else { return }
        searchTask = Task { [weak self] in
            do {
                let response: EngineSearchResponse
                if q.isEmpty { response = try await client.suggestions() }
                else { response = try await client.search(q, limit: 30) }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    self.message = nil
                    self.rows = local + Self.curate(response.results, forEmptyQuery: q.isEmpty).map(Self.row(from:))
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
                out.append(PaletteRow(id: "emoji:" + e.name, title: e.name, subtitle: "\(e.c) — press Return to copy", symbol: "face.smiling",
                                      iconPath: nil, tag: "Emoji", kind: .copy(e.c), glyph: e.c))
            }
            return out
        }
        if let c = UnitConverter.convert(q) {
            out.append(PaletteRow(id: "convert", title: c.value, subtitle: c.label + " — press Return to copy", symbol: "arrow.left.arrow.right.circle",
                                  iconPath: nil, tag: "Convert", kind: .copy(c.value)))
        }
        if let value = Calculator.evaluate(q) {
            out.append(PaletteRow(id: "calc", title: value, subtitle: q + " — press Return to copy", symbol: "equal.circle",
                                  iconPath: nil, tag: "Calculator", kind: .calculator(value)))
        }
        let lower = q.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        for c in Self.builtins {
            let hay = ([c.title.lowercased()] + c.keywords).joined(separator: " ")
            if words.allSatisfy({ hay.contains($0) }) {
                out.append(PaletteRow(id: "cmd:" + c.id, title: c.title, subtitle: c.subtitle, symbol: c.symbol,
                                      iconPath: nil, tag: "Command", kind: .command(c.id)))
            }
            if out.count >= 6 { break }
        }
        return out
    }

    /// Empty query: apps and commands first (like Spotlight / Raycast), no git commits or
    /// browser noise. Otherwise: everything, but never `file://` browser history entries.
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
        return PaletteRow(id: r.id, title: r.title, subtitle: r.subtitle ?? r.path ?? r.url ?? "", symbol: symbol,
                          iconPath: icon, tag: r.pluginId.capitalized, kind: .engine(r))
    }

    // MARK: acting

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    /// Runs the selected row. Returns true when the palette should close.
    func activateSelection() -> Bool {
        guard rows.indices.contains(selection) else { return false }
        let row = rows[selection]
        switch row.kind {
        case .calculator(let value), .copy(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            return true
        case .command(let id):
            runBuiltin?(id)
            return true
        case .engine(let result):
            guard let client else { return false }
            Task {
                do { try await client.execute(result.id) }
                catch { Log.warn("execute failed: \(error.localizedDescription)") }
            }
            return true
        }
    }
}
