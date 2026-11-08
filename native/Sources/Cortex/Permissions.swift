import AppKit
import AVFoundation
import CoreServices
import CoreLocation
import EventKit
import SwiftUI

/// Every macOS permission Cortex can use, with its live status, a way to ask for it, and a way to start over.
///
/// macOS has no "grant all" switch: each privacy area asks on its own, and Accessibility and Screen Recording
/// can only be switched on by you in System Settings. "Grant everything" walks through them in order and
/// opens the right Settings pane for the ones macOS won't prompt for.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum Status: Equatable { case granted, denied, notAsked, needsApp, unknown }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        var status: Status
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var walking = false
    @Published var walkNote = ""

    /// Apps Cortex talks to through Apple Events (Automation): System Events, Music, Finder and installed browsers.
    static let automationTargets: [(bundle: String, name: String, why: String)] = [
        ("com.apple.systemevents", "System Events", "Dark mode, menu search, typing snippets"),
        ("com.apple.finder", "Finder", "Empty Trash, reveal files"),
        ("com.apple.Music", "Music", "Love/shuffle in Music"),
        ("com.apple.Safari", "Safari", "Search and switch tabs"),
        ("com.google.Chrome", "Google Chrome", "Search and switch tabs"),
        ("com.brave.Browser", "Brave Browser", "Search and switch tabs"),
        ("company.thebrowser.Browser", "Arc", "Search and switch tabs"),
        ("com.microsoft.edgemac", "Microsoft Edge", "Search and switch tabs"),
    ]

    func refresh() {
        var list: [Item] = [
            Item(id: "accessibility", title: "Accessibility", detail: "Window snapping, Dock clicks, volume keys, Act on this, Hyper key",
                 symbol: "accessibility", status: AXIsProcessTrusted() ? .granted : .notAsked),
            Item(id: "screen", title: "Screen Recording", detail: "Dock window previews and Screen Memory",
                 symbol: "rectangle.dashed.badge.record", status: CGPreflightScreenCaptureAccess() ? .granted : .notAsked),
            Item(id: "calendar", title: "Calendar", detail: "Next meeting in the Island and Dock, Join buttons",
                 symbol: "calendar", status: Self.calendarStatus()),
            Item(id: "location", title: "Location", detail: "Weather for where you are",
                 symbol: "location", status: Self.locationStatus()),
            Item(id: "camera", title: "Camera", detail: "The Mirror in the Island",
                 symbol: "camera", status: Self.avStatus(.video)),
            Item(id: "microphone", title: "Microphone", detail: "Dictation",
                 symbol: "mic", status: Self.avStatus(.audio)),
        ]
        for t in Self.automationTargets where NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundle) != nil {
            list.append(Item(id: "ae:" + t.bundle, title: "Automation · \(t.name)", detail: t.why,
                             symbol: "applescript", status: items.first { $0.id == "ae:" + t.bundle }?.status ?? .unknown))
        }
        items = list
        // Automation status needs a blocking call per app: do it off the main thread.
        let targets = list.filter { $0.id.hasPrefix("ae:") }.map { String($0.id.dropFirst(3)) }
        Task.detached {
            var found: [String: Status] = [:]
            for b in targets { found[b] = Self.automationStatus(b, ask: false) }
            let snapshot = found
            await MainActor.run {
                for (b, s) in snapshot { if let i = self.items.firstIndex(where: { $0.id == "ae:" + b }) { self.items[i].status = s } }
            }
        }
    }

    var grantedCount: Int { items.filter { $0.status == .granted }.count }

    // MARK: asking

    func request(_ id: String) {
        switch id {
        case "accessibility":
            WindowManager.requestAccess()
            openPane("Privacy_Accessibility")
        case "screen":
            if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
        case "calendar":
            if Self.calendarStatus() == .denied { openPane("Privacy_Calendars") } else { CalendarService.shared.requestAccess() }
        case "location":
            if Self.locationStatus() == .denied { openPane("Privacy_LocationServices") } else { WeatherService.shared.watch() }
        case "camera", "microphone":
            let media: AVMediaType = id == "camera" ? .video : .audio
            if Self.avStatus(media) == .denied { openPane(id == "camera" ? "Privacy_Camera" : "Privacy_Microphone") }
            else { AVCaptureDevice.requestAccess(for: media) { _ in Task { @MainActor in Permissions.shared.refresh() } } }
        default:
            guard id.hasPrefix("ae:") else { return }
            let bundle = String(id.dropFirst(3))
            Task.detached {
                var s = Self.automationStatus(bundle, ask: true)
                if s == .needsApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    // The app has to be running to be asked: open it in the background, then ask.
                    await MainActor.run {
                        let cfg = NSWorkspace.OpenConfiguration()
                        cfg.activates = false
                        cfg.hides = true
                        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    s = Self.automationStatus(bundle, ask: true)
                }
                let final = s
                await MainActor.run {
                    if final == .denied { Permissions.shared.openPane("Privacy_Automation") }
                    Permissions.shared.refresh()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Permissions.shared.refresh() }
    }

    /// Asks for everything that isn't granted yet, one after another, and opens Settings for the rest.
    func grantEverything() {
        guard !walking else { return }
        walking = true
        Task { @MainActor in
            for item in items where item.status != .granted {
                walkNote = "Asking for \(item.title)…"
                request(item.id)
                // Give each prompt time to be answered before the next one stacks on top of it.
                let wait: UInt64 = item.id == "accessibility" || item.id == "screen" ? 2_500_000_000 : 3_000_000_000
                try? await Task.sleep(nanoseconds: wait)
                refresh()
            }
            walking = false
            let missing = items.filter { $0.status != .granted }.map(\.title)
            walkNote = missing.isEmpty ? "Everything is granted." :
                "Still off: \(missing.joined(separator: ", ")). Switch them on in System Settings, then come back."
            if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() {
                walkNote += " Accessibility and Screen Recording need a restart of Cortex after you switch them on."
            }
        }
    }

    /// Clears every grant macOS holds for Cortex (including stale ones from older builds) and relaunches,
    /// so the next prompts attach to this exact build. Same as removing Cortex from each list by hand.
    func resetAndRelaunch() {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.cortex.native"
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "All", bundle]
        try? p.run()
        p.waitUntilExit()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1.2; /usr/bin/open \"\(path)\" --args --grant-permissions"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    // MARK: status probes

    nonisolated static func calendarStatus() -> Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined: return .notAsked
        default: return .unknown
        }
    }

    nonisolated static func locationStatus() -> Status {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        default: return .unknown
        }
    }

    nonisolated static func avStatus(_ media: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .unknown
        }
    }

    /// Apple Events permission for one app. `ask` shows the system prompt when it hasn't been answered.
    nonisolated static func automationStatus(_ bundle: String, ask: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let desc = target.aeDesc else { return .unknown }
        let err = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch err {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .needsApp
        default: return .unknown
        }
    }
}

// MARK: Pane

struct PermissionsCenter: View {
    @ObservedObject private var perms = Permissions.shared
    @State private var confirmReset = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.25), lineWidth: 5)
                    Circle().trim(from: 0, to: perms.items.isEmpty ? 0 : CGFloat(perms.grantedCount) / CGFloat(perms.items.count))
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(perms.grantedCount)/\(perms.items.count)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .frame(width: 48, height: 48)
                .animation(.spring(response: 0.5), value: perms.grantedCount)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Permissions").font(.headline)
                    Text("macOS asks for each one separately — there is no single switch. Grant everything walks through all of them in order and opens Settings for the two you have to switch on yourself.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button {
                    perms.grantEverything()
                } label: {
                    Label(perms.walking ? "Asking…" : "Grant everything", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(perms.walking || perms.grantedCount == perms.items.count)
                Button("Reset and ask again…") { confirmReset = true }
                Spacer()
                Button("Refresh") { perms.refresh() }
            }
            if !perms.walkNote.isEmpty {
                Text(perms.walkNote).font(.callout).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Reset all of Cortex's permissions?", isPresented: $confirmReset) {
            Button("Reset and relaunch", role: .destructive) { perms.resetAndRelaunch() }
        } message: {
            Text("Use this when a switch in System Settings is on but Cortex still says it's off — that happens after an update, because macOS tied the old grant to the previous build. Cortex clears its entries, relaunches and asks again. Nothing else is touched.")
        }

        Section("Each permission") {
            ForEach(perms.items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.symbol).frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch item.status {
                    case .granted:
                        Label("On", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
                    case .denied:
                        Button("Open Settings") { perms.request(item.id) }
                    case .needsApp:
                        Button("Open app & ask") { perms.request(item.id) }
                    case .notAsked, .unknown:
                        Button("Grant…") { perms.request(item.id) }
                    }
                }
            }
            if perms.items.contains(where: { ($0.id == "accessibility" || $0.id == "screen") && $0.status != .granted }) {
                Text("Switched Accessibility or Screen Recording on but it still shows off? It's a stale entry from an older version: use Reset and ask again, or remove Cortex from that list with − and add it back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { perms.refresh() }
        .onReceive(timer) { _ in if !perms.walking { perms.refresh() } }
    }
}
