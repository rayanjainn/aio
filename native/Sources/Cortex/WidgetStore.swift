import AppKit
import Combine

enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case clock, calendar, system, nowPlaying, notes, todos, weather, claude, codex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: "Clock"
        case .calendar: "Calendar"
        case .system: "System"
        case .nowPlaying: "Now Playing"
        case .notes: "Sticky Note"
        case .todos: "To-Do"
        case .weather: "Weather"
        case .claude: "Claude Code Usage"
        case .codex: "Codex Usage"
        }
    }
    var detail: String {
        switch self {
        case .clock: "Time and date, down to the second"
        case .calendar: "This month at a glance"
        case .system: "CPU, memory, disk and battery"
        case .nowPlaying: "Whatever is playing, from any app"
        case .notes: "A note that stays on your desktop"
        case .todos: "A small checklist"
        case .weather: "Right now and today's range"
        case .claude: "Tokens today, the 5-hour block, last 7 days"
        case .codex: "Tokens today and the last 7 days"
        }
    }
    var symbol: String {
        switch self {
        case .clock: "clock"
        case .calendar: "calendar"
        case .system: "cpu"
        case .nowPlaying: "music.note"
        case .notes: "note.text"
        case .todos: "checklist"
        case .weather: "cloud.sun"
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum WidgetSize: String, Codable, CaseIterable {
    case small, medium, large
    var dimensions: CGSize {
        switch self {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 356, height: 170)
        case .large: CGSize(width: 356, height: 356)
        }
    }
    var title: String { rawValue.capitalized }
}

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
}

struct WidgetConfig: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: WidgetKind
    var size: WidgetSize = .small
    var x: Double?
    var y: Double?
    /// false = sits on the desktop under your windows; true = floats above them.
    var floating = false
    var text = ""
    var todos: [TodoItem] = []
}

/// The widgets on your desktop, saved to ~/.cortex/native/widgets.json.
@MainActor
final class WidgetStore: ObservableObject {
    @Published private(set) var items: [WidgetConfig] = []
    @Published var visible = true

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/widgets.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url), let list = try? JSONDecoder().decode([WidgetConfig].self, from: data) {
            items = list
        }
    }

    func add(_ kind: WidgetKind) {
        var config = WidgetConfig(kind: kind)
        config.size = (kind == .system || kind == .nowPlaying || kind == .claude || kind == .codex) ? .medium : .small
        items.append(config)
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func update(_ id: String, _ change: (inout WidgetConfig) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    func config(_ id: String) -> WidgetConfig? { items.first(where: { $0.id == id }) }

    private var saveWork: DispatchWorkItem?
    private func save() {
        saveWork?.cancel()
        let snapshot = items
        let work = DispatchWorkItem {
            let url = Self.url
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
