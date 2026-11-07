import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Hooks the Settings window needs from the app.
struct SettingsActions {
    var reregisterHotkeys: () -> Void
    var systemDockHidden: () -> Bool
    var setSystemDockHidden: (Bool) -> Void
    var engineSummary: () -> String
    var reindex: () -> Void
    var toggleScreenMemory: () -> Void
    var openDiagnostics: () -> Void
    var addDockFolder: () -> Void
    var dockHasWidget: (String) -> Bool
    var dockSetWidget: (String, Bool) -> Void
    var engine: EngineClient
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, snippets, quicklinks, island, dock, appearance, ai, memory, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .memory: "Screen Memory"
        case .snippets: "Snippets"
        case .quicklinks: "Quicklinks"
        case .island: "Island"
        case .dock: "Dock"
        case .appearance: "Appearance"
        case .ai: "AI"
        case .privacy: "Privacy & Permissions"
        case .about: "About & Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .memory: "clock.arrow.circlepath"
        case .snippets: "text.quote"
        case .quicklinks: "link"
        case .island: "capsule.portrait"
        case .dock: "dock.rectangle"
        case .appearance: "paintbrush"
        case .ai: "sparkles"
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
                case .memory: MemoryPane(actions: actions)
                case .snippets: SnippetsPane()
                case .quicklinks: QuicklinksPane()
                case .island: IslandPane(prefs: prefs)
                case .dock: DockPane(prefs: prefs, actions: actions)
                case .appearance: AppearancePane(prefs: prefs)
                case .ai: AIPane()
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
    @State private var appIDs: [String] = ConfigFile.shortcuts().keys.filter { $0.hasPrefix("app:") }.sorted()

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
            Section("Open an app") {
                ForEach(appIDs, id: \.self) { id in
                    LabeledContent(appName(id)) {
                        HStack {
                            ShortcutRecorder(id: id, accel: ConfigFile.shortcuts()[id] ?? "") { actions.reregisterHotkeys() }
                            Button(role: .destructive) {
                                ConfigFile.setShortcut(id, nil)
                                appIDs.removeAll { $0 == id }
                                actions.reregisterHotkeys()
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add an app…") { addApp() }
            }
            Section { Text("Click a shortcut, then press the new combination. Delete turns one off. Window shortcuts need Accessibility access (Privacy & Permissions).").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(id.dropFirst(4))) else { return String(id.dropFirst(4)) }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bid = Bundle(url: url)?.bundleIdentifier else { return }
        let id = "app:" + bid
        if ConfigFile.shortcuts()[id] == nil { ConfigFile.setShortcut(id, "") }
        if !appIDs.contains(id) { appIDs.append(id) }
    }
}

struct IslandPane: View {
    @ObservedObject var prefs: Prefs
    var body: some View {
        Form {
            Section {
                Toggle("Show the Island", isOn: $prefs.islandEnabled)
                Toggle("Expand when the pointer touches it", isOn: $prefs.islandHoverExpand)
                Toggle("Hide it while a full-screen app is showing", isOn: $prefs.islandHideFullscreen)
                Picker("Show the Island on", selection: $prefs.islandDisplay) {
                    Text("Automatic (the display with the notch)").tag("auto")
                    ForEach(NSScreen.screens, id: \.localizedName) { s in Text(s.localizedName).tag(s.localizedName) }
                }
                Text("Swipe sideways with two fingers to change page. Drop files on it to park them on the Shelf.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Apps in the Island") {
                ForEach(prefs.islandApps, id: \.self) { bundle in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else { Text(bundle) }
                        Spacer()
                        Button("Remove") { prefs.islandApps.removeAll { $0 == bundle } }.buttonStyle(.borderless)
                    }
                }
                Button("Add an app…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowsMultipleSelection = true
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK {
                        for u in panel.urls { if let id = Bundle(url: u)?.bundleIdentifier, !prefs.islandApps.contains(id) { prefs.islandApps.append(id) } }
                    }
                }
                Text("They appear on the Island's Tools page, one tap to open.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Live activities") {
                Toggle("Now Playing (any app)", isOn: $prefs.islandMusic)
                Toggle("Synced lyrics", isOn: $prefs.islandLyrics)
                Toggle("Volume and brightness HUD (replaces the macOS overlay)", isOn: $prefs.islandHUD)
                Toggle("Next meeting, with a Join button", isOn: $prefs.islandCalendar)
                Toggle("Charging when you plug in", isOn: $prefs.islandCharging)
                Toggle("AirPods and Bluetooth devices connecting", isOn: $prefs.islandBluetooth)
                Toggle("Downloads in progress", isOn: $prefs.islandDownloads)
                Toggle("Microphone / camera in use", isOn: $prefs.islandPrivacy)
            }
            Section {
                Text("The HUD needs Accessibility access to take over the volume and brightness keys. Calendar and Bluetooth ask for their own permission the first time they're used.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct DockPane: View {
    static func apply(_ p: Prefs, size: Double, magnification: Double, spacing: Double, roundness: Double, dots: Bool = true) {
        p.dockIconSize = size; p.dockMagnification = magnification; p.dockSpacing = spacing; p.dockRoundness = roundness
        p.dockMagnify = magnification > 1.01; p.dockIndicators = dots
    }

    @ObservedObject var prefs: Prefs
    let actions: SettingsActions
    @State private var hidden = false
    @State private var widgetTick = 0

    var body: some View {
        Form {
            Section {
                Toggle("Show the Cortex Dock", isOn: $prefs.dockEnabled)
                Picker("Position", selection: $prefs.dockEdge) {
                    Text("Bottom").tag("bottom")
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                .pickerStyle(.segmented)
                Toggle("Hide automatically (reveal at the screen edge)", isOn: $prefs.dockAutohide)
                Toggle("Magnify icons under the pointer", isOn: $prefs.dockMagnify)
                LabeledContent("Icon size") {
                    HStack {
                        Slider(value: $prefs.dockIconSize, in: 36...80, step: 2).frame(width: 220)
                        Text("\(Int(prefs.dockIconSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section("Presets") {
                HStack {
                    Button("Classic") { Self.apply(prefs, size: 48, magnification: 1.7, spacing: 8, roundness: 0.42) }
                    Button("Compact") { Self.apply(prefs, size: 36, magnification: 1.35, spacing: 4, roundness: 0.3) }
                    Button("Large") { Self.apply(prefs, size: 64, magnification: 1.3, spacing: 10, roundness: 0.5) }
                    Button("Minimal") { Self.apply(prefs, size: 40, magnification: 1.0, spacing: 6, roundness: 0.2, dots: false) }
                    Button("Showy") { Self.apply(prefs, size: 52, magnification: 2.1, spacing: 9, roundness: 0.6) }
                }
                Picker("Show the Dock on", selection: $prefs.dockDisplay) {
                    Text("Main display").tag("main")
                    ForEach(NSScreen.screens.dropFirst(), id: \.localizedName) { s in Text(s.localizedName).tag(s.localizedName) }
                }
            }
            Section("Feel") {
                LabeledContent("Magnification") {
                    HStack {
                        Slider(value: $prefs.dockMagnification, in: 1.1...2.2).frame(width: 220)
                        Text(String(format: "%.0f%%", (prefs.dockMagnification - 1) * 100)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }.disabled(!prefs.dockMagnify)
                LabeledContent("Spacing") {
                    HStack {
                        Slider(value: $prefs.dockSpacing, in: 0...20, step: 1).frame(width: 220)
                        Text("\(Int(prefs.dockSpacing)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Corner roundness") {
                    HStack {
                        Slider(value: $prefs.dockRoundness, in: 0.1...0.7).frame(width: 220)
                        Text(String(format: "%.0f%%", prefs.dockRoundness * 100)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("Click the active app's icon to hide it", isOn: $prefs.dockClickHides)
                Toggle("Running-app dots", isOn: $prefs.dockIndicators)
                Toggle("Bounce while an app launches", isOn: $prefs.dockBounce)
                Toggle("Show running apps that aren't pinned", isOn: $prefs.dockShowRunning)
                Button("Reset Dock look to defaults") {
                    prefs.dockIconSize = 44; prefs.dockMagnification = 1.55; prefs.dockSpacing = 7; prefs.dockRoundness = 0.42
                    prefs.dockDarken = 0; prefs.dockIndicators = true; prefs.dockBounce = true; prefs.dockShowRunning = true
                }
            }
            Section("Look") {
                HStack {
                    Button("Clear") { prefs.dockDarken = 0 }
                    Button("Smoky") { prefs.dockDarken = 0.3 }
                    Button("Midnight") { prefs.dockDarken = 0.6 }
                }
                LabeledContent("Glass darkness") {
                    HStack {
                        Slider(value: $prefs.dockDarken, in: 0...0.8).frame(width: 220)
                        Text("\(Int(prefs.dockDarken * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section("Dock widgets") {
                ForEach(DockWidgetKind.all) { k in
                    Toggle(isOn: Binding(get: { actions.dockHasWidget(k.id) }, set: { actions.dockSetWidget(k.id, $0); widgetTick += 1 })) {
                        Label(k.title, systemImage: k.symbol)
                    }
                }
                .id(widgetTick)
                Text("Live tiles that sit in the Dock between your apps. Right-click a tile to remove it; drag to reorder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Items") {
                Toggle("Window previews when hovering an app", isOn: $prefs.dockPreviews)
                Toggle("Show the Trash", isOn: $prefs.dockShowTrash)
                Button("Add a folder…") { actions.addDockFolder() }
                Text("Drag icons to reorder, drag one away to remove it, drop files on an app to open them with it, right-click for more. Previews need Screen Recording access.")
                    .font(.callout).foregroundStyle(.secondary)
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
    @ObservedObject private var updater = SelfUpdater.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            Section("Updates") {
                LabeledContent("Status", value: updater.message.isEmpty ? status : updater.message)
                HStack {
                    Button(checking ? "Checking…" : "Check for updates") { Task { await check() } }.disabled(checking)
                    if let update {
                        Button("Install \(update.tag)") { Task { await SelfUpdater.shared.install(update) } }
                        Button("Download only") { NSWorkspace.shared.open(update.url) }
                    }
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


struct SnippetsPane: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section("New snippet") {
                TextField("Name", text: $name)
                TextEditor(text: $text).frame(height: 90).font(.system(size: 12))
                Button("Add snippet") {
                    guard !text.isEmpty else { return }
                    store.add(name: name.isEmpty ? String(text.prefix(40)) : name, text: text)
                    name = ""; text = ""
                }
            }
            Section("Your snippets") {
                if store.items.isEmpty { Text("None yet. In the palette, type  snip  to paste one into any app.").foregroundStyle(.secondary) }
                ForEach($store.items) { $item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: $item.name).textFieldStyle(.roundedBorder)
                            TextField("Keyword", text: $item.keyword).textFieldStyle(.roundedBorder).frame(width: 110)
                            Button(role: .destructive) { store.remove(item) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .onChange(of: item) { _, _ in store.save() }
                }
            }
        }
    }
}

struct QuicklinksPane: View {
    @ObservedObject private var store = QuicklinkStore.shared
    @State private var name = ""
    @State private var keyword = ""
    @State private var url = ""

    var body: some View {
        Form {
            Section("New quicklink") {
                TextField("Name", text: $name)
                TextField("Keyword (type it in the palette)", text: $keyword)
                TextField("URL — use {query} for the text you type", text: $url)
                Button("Add quicklink") {
                    guard !name.isEmpty, !keyword.isEmpty, !url.isEmpty else { return }
                    store.items.append(Quicklink(name: name, keyword: keyword, url: url)); store.save()
                    name = ""; keyword = ""; url = ""
                }
            }
            Section("Your quicklinks") {
                ForEach($store.items) { $item in
                    HStack {
                        TextField("Name", text: $item.name).textFieldStyle(.roundedBorder).frame(width: 150)
                        TextField("Keyword", text: $item.keyword).textFieldStyle(.roundedBorder).frame(width: 80)
                        TextField("URL", text: $item.url).textFieldStyle(.roundedBorder)
                        Button(role: .destructive) { store.items.removeAll { $0.id == item.id }; store.save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .onChange(of: item) { _, _ in store.save() }
                }
                Button("Restore defaults") { store.items = QuicklinkStore.defaults; store.save() }
            }
        }
    }
}


struct MemoryPane: View {
    let actions: SettingsActions
    @State private var recording = false
    @State private var retention = 30
    @State private var blocked = ""
    @State private var raw = false
    @State private var status = "Checking…"

    var body: some View {
        Form {
            Section {
                Toggle("Remember what's on my screen", isOn: Binding(get: { recording }, set: { want in
                    if want != recording { Task { await toggle() } }
                }))
                Text("Cortex reads the text on your screen (on this Mac only) so you can search it later: type  mem  in the palette. It never captures password fields or blocked apps. Needs Screen Recording access. ⌘⇧P pauses it.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Engine", value: status)
            }
            Section("Retention & privacy") {
                Stepper("Keep \(retention) days", value: $retention, in: 1...365).onChange(of: retention) { _, _ in Task { await save() } }
                Toggle("Keep screenshots (uses much more disk)", isOn: $raw).onChange(of: raw) { _, _ in Task { await save() } }
                TextField("Never capture these apps (comma-separated)", text: $blocked).onSubmit { Task { await save() } }
                Button("Save") { Task { await save() } }
            }
        }
        .task { await load() }
    }

    private func config() async -> [String: Any] {
        guard let data = try? await actions.engine.call("config_get"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }

    private func load() async {
        let cfg = await config()
        retention = (cfg["retentionDays"] as? NSNumber)?.intValue ?? 30
        raw = (cfg["rawStorage"] as? Bool) ?? false
        blocked = ((cfg["blockedApps"] as? [String]) ?? []).joined(separator: ", ")
        if let d = try? await actions.engine.call("recording_get"), let v = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? Bool {
            recording = v
            status = v ? "Remembering" : "Paused"
        } else { status = "Engine not running" }
    }

    private func toggle() async {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        _ = try? await actions.engine.call("recording_toggle")
        await load()
    }

    private func save() async {
        var cfg = await config()
        cfg["retentionDays"] = retention
        cfg["rawStorage"] = raw
        cfg["blockedApps"] = blocked.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        _ = try? await actions.engine.call("config_set", cfg)
    }
}
