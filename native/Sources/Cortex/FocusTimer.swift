import Foundation
import AppKit

/// A focus / pomodoro timer shown in the Island.
@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    @Published private(set) var endsAt: Date?
    @Published private(set) var total: TimeInterval = 25 * 60
    @Published private(set) var remainingWhenPaused: TimeInterval = 25 * 60
    @Published var label = "Focus"
    var onFinish: (() -> Void)?
    private var ticker: Timer?

    var isRunning: Bool { endsAt != nil }
    var isActive: Bool { isRunning || remainingWhenPaused < total }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(date)) }
        return remainingWhenPaused
    }

    func progress(at date: Date = Date()) -> Double { total > 0 ? 1 - remaining(at: date) / total : 0 }

    func start(minutes: Int, label: String = "Focus") {
        total = TimeInterval(minutes * 60)
        remainingWhenPaused = total
        self.label = label
        resume()
    }

    func resume() {
        endsAt = Date().addingTimeInterval(remainingWhenPaused)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        remainingWhenPaused = remaining()
        endsAt = nil
        ticker?.invalidate(); ticker = nil
    }

    func toggle() { isRunning ? pause() : resume() }

    func reset() {
        endsAt = nil
        ticker?.invalidate(); ticker = nil
        remainingWhenPaused = total
    }

    private func tick() {
        guard let endsAt, endsAt <= Date() else { return }
        ticker?.invalidate(); ticker = nil
        self.endsAt = nil
        remainingWhenPaused = total
        NSSound(named: "Glass")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        onFinish?()
    }
}
