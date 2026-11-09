import AppKit
import IOKit.ps

/// Gentle nudges: an app draining the battery, and "welcome back" after the Mac wakes.
@MainActor
final class Coach {
    static let shared = Coach()
    private var timer: Timer?
    private var strikes: [String: Int] = [:]
    private var lastWarned: [String: Date] = [:]
    private var beforeSleep: String?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in Coach.shared.checkBattery() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            let name = NSWorkspace.shared.frontmostApplication?.localizedName
            Task { @MainActor in Coach.shared.beforeSleep = name }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard let app = Coach.shared.beforeSleep else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    Toast.show("arrow.uturn.backward", "Welcome back — you were in \(app)")
                }
            }
        }
    }

    private static var onBattery: Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    private func checkBattery() {
        guard Prefs.shared.batteryCoach, Self.onBattery else { strikes = [:]; return }
        DispatchQueue.global(qos: .utility).async {
            let out = SystemCommands.shell("/bin/ps", ["-Aco", "pcpu=,comm=", "-r"])
            let top = out.split(separator: "\n").prefix(3).compactMap { line -> (Double, String)? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " "), let cpu = Double(t[..<sp]) else { return nil }
                return (cpu, String(t[sp...]).trimmingCharacters(in: .whitespaces))
            }
            Task { @MainActor in Coach.shared.evaluate(top) }
        }
    }

    private func evaluate(_ top: [(Double, String)]) {
        let ignore: Set<String> = ["kernel_task", "WindowServer", "Cortex", "cortexd", "AIO", "aiod", "mds_stores", "mds", "backupd"]
        var next: [String: Int] = [:]
        for (cpu, name) in top where cpu > 60 && !ignore.contains(name) {
            next[name] = (strikes[name] ?? 0) + 1
            if next[name]! >= 3, Date().timeIntervalSince(lastWarned[name] ?? .distantPast) > 1800 {
                lastWarned[name] = Date()
                Toast.show("battery.25", "\(name) is using a lot of power (\(Int(cpu))% CPU)")
            }
        }
        strikes = next
    }
}
