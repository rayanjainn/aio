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
