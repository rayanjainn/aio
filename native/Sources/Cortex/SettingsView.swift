import SwiftUI
import AppKit

/// Hooks the Settings window needs from the app.
struct SettingsActions {
    var reregisterHotkeys: () -> Void
    var systemDockHidden: () -> Bool
    var setSystemDockHidden: (Bool) -> Void
    var engineSummary: () -> String
    var reindex: () -> Void
    var toggleScreenMemory: () -> Void
    var openDiagnostics: () -> Void
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, island, dock, appearance, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .island: "Island"
        case .dock: "Dock"
        case .appearance: "Appearance"
        case .privacy: "Privacy & Permissions"
        case .about: "About & Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .island: "capsule.portrait"
        case .dock: "dock.rectangle"
        case .appearance: "paintbrush"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    let actions: SettingsActions
    @State var section: SettingsSection

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
        } detail: {
            Group {
                switch section {
                case .general: GeneralPane(prefs: prefs, actions: actions)
                case .shortcuts: ShortcutsPane(actions: actions)
                case .island: IslandPane(prefs: prefs)
                case .dock: DockPane(prefs: prefs, actions: actions)
                case .appearance: AppearancePane(prefs: prefs)
                case .privacy: PrivacyPane(prefs: prefs, actions: actions)
                case .about: AboutPane(actions: actions)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.title)
        }
        .frame(minWidth: 760, minHeight: 500)
    }
}

// MARK: panes

struct GeneralPane: View {
    @ObservedObject var prefs: Prefs
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Cortex at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            }
            Section("Search engine") {
                LabeledContent("Status", value: actions.engineSummary())
                Button("Re-index now") { actions.reindex() }
            }
            Section("Screen memory") {
                Text("Cortex can remember what was on your screen so you can search it later. It is off until you turn it on, and it never captures password fields or apps you block.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Pause / resume screen memory") { actions.toggleScreenMemory() }
            }
        }
    }
}

struct ShortcutRecorder: View {
    let id: String
    @State private var accel: String
    @State private var recording = false
    @State private var monitor: Any?
    let onChange: () -> Void

    init(id: String, accel: String, onChange: @escaping () -> Void) {
        self.id = id
        _accel = State(initialValue: accel)
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Type shortcut…" : Accelerator.display(accel)) { toggle() }
                .buttonStyle(.bordered)
                .frame(minWidth: 130)
            if let err = HotKeyCenter.shared.errors[id] { Text(err).font(.caption).foregroundStyle(.orange) }
            if ConfigFile.shortcuts()[id] != nil {
                Button("Reset") { set(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .onDisappear { stop() }
    }

    private var defaultAccel: String { ShortcutTable.all.first(where: { $0.id == id })?.accel ?? "" }

    private func set(_ new: String?) {
        ConfigFile.setShortcut(id, new)
        accel = new ?? defaultAccel
        onChange()
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }                     // esc cancels
            if event.keyCode == 51 { set(""); stop(); return nil }            // delete turns it off
            if let text = Accelerator.format(keyCode: event.keyCode, flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)) {
                set(text)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

struct ShortcutsPane: View {
    let actions: SettingsActions
    @State private var tick = 0

    var body: some View {
        Form {
            ForEach(["General", "Windows"], id: \.self) { group in
                Section(group) {
                    ForEach(ShortcutTable.all.filter { $0.group == group }, id: \.id) { entry in
                        LabeledContent(entry.label) {
                            ShortcutRecorder(id: entry.id, accel: ShortcutTable.effective().first(where: { $0.id == entry.id })?.accel ?? entry.accel) {
                                actions.reregisterHotkeys()
                                tick += 1
                            }
                            .id("\(entry.id)-\(tick)")
                        }
                    }
                }
            }
            Section { Text("Click a shortcut, then press the new combination. Delete turns one off. Window shortcuts need Accessibility access (Privacy & Permissions).").font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct IslandPane: View {
    @ObservedObject var prefs: Prefs
    var body: some View {
        Form {
            Section {
                Toggle("Show the Island", isOn: $prefs.islandEnabled)
                Toggle("Expand when the pointer touches it", isOn: $prefs.islandHoverExpand)
            }
            Section("Live activities") {
                Toggle("Now Playing (any app)", isOn: $prefs.islandMusic)
                Toggle("Charging when you plug in", isOn: $prefs.islandCharging)
            }
        }
    }
}

struct DockPane: View {
    @ObservedObject var prefs: Prefs
    let actions: SettingsActions
    @State private var hidden = false

    var body: some View {
        Form {
            Section {
                Toggle("Show the Cortex Dock", isOn: $prefs.dockEnabled)
                Toggle("Magnify icons under the pointer", isOn: $prefs.dockMagnify)
                LabeledContent("Icon size") {
                    HStack {
                        Slider(value: $prefs.dockIconSize, in: 36...80, step: 2).frame(width: 220)
                        Text("\(Int(prefs.dockIconSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section("macOS Dock") {
                Toggle("Hide the macOS Dock while Cortex runs", isOn: Binding(get: { hidden }, set: { hidden = $0; actions.setSystemDockHidden($0) }))
                Text("Cortex restores your Dock settings when it quits. If it ever doesn't, run:  defaults delete com.apple.dock autohide-delay; killall Dock")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onAppear { hidden = actions.systemDockHidden() }
    }
}

struct AppearancePane: View {
    @ObservedObject var prefs: Prefs
    var body: some View {
        Form {
            Section("Palette glass") {
                LabeledContent("Darkness") {
                    HStack {
                        Slider(value: $prefs.paletteDarken, in: 0...0.8).frame(width: 220)
                        Text("\(Int(prefs.paletteDarken * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("Lower is clearer Liquid Glass; higher is easier to read over busy windows.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Color.green : Color.secondary).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(button, action: action) }
        }
    }
}

struct PrivacyPane: View {
    @ObservedObject var prefs: Prefs
    let actions: SettingsActions
    @State private var accessibility = WindowManager.isTrusted
    @State private var screen = CGPreflightScreenCaptureAccess()
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !prefs.onboardingDone {
                Section {
                    Text("Welcome to Cortex. Grant what you want to use — everything is optional, and you can change it later.")
                    Button("Done") { prefs.onboardingDone = true }
                }
            }
            Section("Permissions") {
                PermissionRow(title: "Accessibility", detail: "Lets Cortex move and resize windows with the keyboard.",
                              granted: accessibility, button: "Grant…") { WindowManager.requestAccess() }
                PermissionRow(title: "Screen Recording", detail: "Only needed for screen memory and Dock window previews.",
                              granted: screen, button: "Grant…") { _ = CGRequestScreenCaptureAccess() }
                Button("Open Privacy & Security settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
            }
            Section("Now Playing") {
                Text("Cortex reads what's playing from macOS itself, so Apple Music, Spotify, browsers and more need no permission.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in
            accessibility = WindowManager.isTrusted
            screen = CGPreflightScreenCaptureAccess()
        }
    }
}

struct AboutPane: View {
    let actions: SettingsActions
    @State private var status = "Not checked yet"
    @State private var update: UpdateInfo?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            Section("Updates") {
                LabeledContent("Status", value: status)
                HStack {
                    Button(checking ? "Checking…" : "Check for updates") { Task { await check() } }.disabled(checking)
                    if let update { Button("Download \(update.tag)") { NSWorkspace.shared.open(update.url) } }
                }
            }
            Section("Troubleshooting") {
                Button("Open Diagnostics") { actions.openDiagnostics() }
                Button("Reveal log files") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
            }
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            if let u = try await UpdateChecker.check(current: AppInfo.version) {
                update = u
                status = "\(u.tag) is available"
            } else {
                update = nil
                status = "You're up to date"
            }
        } catch {
            status = "Couldn't check: \(error.localizedDescription)"
        }
    }
}

// MARK: window

@MainActor
final class SettingsController {
    private var window: NSWindow?
    private let actions: SettingsActions

    init(actions: SettingsActions) { self.actions = actions }

    func show(_ section: SettingsSection = .general) {
        let view = SettingsView(prefs: .shared, actions: actions, section: section)
        let host = NSHostingView(rootView: view)
        if let w = window {
            w.contentView = host
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Cortex Settings"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = host
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
