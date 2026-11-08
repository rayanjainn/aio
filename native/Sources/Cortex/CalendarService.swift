import Foundation
import EventKit
import AppKit

struct MeetingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let joinURL: URL?
}

/// Upcoming calendar events, with the video-call link pulled out so the Island can offer "Join".
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var events: [MeetingEvent] = []
    @Published private(set) var authorized = false
    @Published private(set) var denied = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: authorized = true; refresh()
        case .notDetermined: break   // asked when the user opens the calendar page
        default: denied = true
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                self?.denied = !granted
                if granted { self?.refresh() }
            }
        }
    }

    func refresh() {
        guard authorized else { return }
        let start = Date().addingTimeInterval(-10 * 60)
        let end = Date().addingTimeInterval(36 * 3600)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map { e in
                MeetingEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Event", start: e.startDate, end: e.endDate,
                             allDay: e.isAllDay, location: e.location, joinURL: Self.joinURL(in: [e.url?.absoluteString, e.location, e.notes]))
            }
        let list = Array(found)
        if list != events { events = list }
    }

    // MARK: quick add

    /// Creates an event in the default calendar. Returns an error message, or nil on success.
    func addEvent(title: String, start: Date, allDay: Bool) async -> String? {
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            authorized = ok; denied = !ok
            guard ok else { return "Calendar access is off (Settings → Privacy & Permissions)" }
        }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = allDay ? start : start.addingTimeInterval(3600)
        e.isAllDay = allDay
        e.calendar = store.defaultCalendarForNewEvents
        do { try store.save(e, span: .thisEvent); refresh(); return nil } catch { return error.localizedDescription }
    }

    /// Creates a reminder (with an alarm when it has a time). Returns an error message, or nil on success.
    func addReminder(title: String, due: Date?) async -> String? {
        if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            let ok = (try? await store.requestFullAccessToReminders()) ?? false
            guard ok else { return "Reminders access is off (Settings → Privacy & Permissions)" }
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = store.defaultCalendarForNewReminders()
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        do { try store.save(r, commit: true); return nil } catch { return error.localizedDescription }
    }

    /// The next timed event that hasn't ended yet.
    var next: MeetingEvent? { events.first(where: { !$0.allDay && $0.end > Date() }) }

    private static let linkPattern = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|around\.co|gotomeeting\.com)[^\s<>"']*"#,
        options: [.caseInsensitive])

    static func joinURL(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let m = linkPattern?.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }
}


/// "lunch with Sam tomorrow at 1pm" → title "Lunch with Sam", date tomorrow 13:00.
enum QuickAdd {
    struct Parsed: Equatable { let title: String; let date: Date?; let hasTime: Bool }

    static func parse(_ text: String, now: Date = Date()) -> Parsed {
        let raw = text.trimmingCharacters(in: .whitespaces)
        var title = raw
        var date: Date?
        var hasTime = false
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = detector.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), let d = m.date,
           let r = Range(m.range, in: raw) {
            date = d
            let phrase = raw[r].lowercased()
            hasTime = phrase.range(of: #"\d\s*(am|pm)|\d:\d|noon|midnight|morning|evening|tonight|afternoon|\bat\b"#, options: .regularExpression) != nil
            title = raw.replacingCharacters(in: r, with: " ")
        }
        // Drop dangling joiners left behind ("call mom at" → "call mom").
        var words = title.split(separator: " ").map(String.init)
        let joiners: Set<String> = ["at", "on", "by", "for", "in", "from", "to"]
        while let last = words.last, joiners.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, joiners.contains(first.lowercased()) { words.removeFirst() }
        title = words.joined(separator: " ")
        if let f = title.first { title = f.uppercased() + title.dropFirst() }
        if !hasTime, let d = date {
            // A date without a time: an all-day item on that day.
            date = Calendar.current.startOfDay(for: d)
        }
        _ = now
        return Parsed(title: title.isEmpty ? "New item" : title, date: date, hasTime: hasTime)
    }
}
