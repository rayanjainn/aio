import AppKit

/// Built-in system actions for the palette. Each runs a short, permission-light command.
struct SystemCommand {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let run: () -> Void
}

enum SystemCommands {
    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static func osascript(_ script: String) {
        DispatchQueue.global().async { _ = shell("/usr/bin/osascript", ["-e", script]) }
    }

    static let all: [SystemCommand] = [
        SystemCommand(id: "sys.lock", title: "Lock Screen", subtitle: "Turn off the display and require your password", symbol: "lock",
                      keywords: ["lock", "sleep display"]) { DispatchQueue.global().async { _ = shell("/usr/bin/pmset", ["displaysleepnow"]) } },
        SystemCommand(id: "sys.sleep", title: "Sleep", subtitle: "Put the Mac to sleep", symbol: "moon.zzz",
                      keywords: ["sleep", "suspend"]) { DispatchQueue.global().async { _ = shell("/usr/bin/pmset", ["sleepnow"]) } },
        SystemCommand(id: "sys.darkmode", title: "Toggle Dark Mode", subtitle: "Switch between light and dark appearance", symbol: "circle.lefthalf.filled",
                      keywords: ["dark", "light", "appearance", "theme"]) {
            osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        },
        SystemCommand(id: "sys.mute", title: "Mute / Unmute", subtitle: "Toggle the output volume", symbol: "speaker.slash",
                      keywords: ["mute", "volume", "sound", "audio"]) {
            osascript("set volume output muted (not (output muted of (get volume settings)))")
        },
        SystemCommand(id: "sys.volumeMax", title: "Volume to 100%", subtitle: "", symbol: "speaker.wave.3",
                      keywords: ["volume", "loud", "max"]) { osascript("set volume output volume 100") },
        SystemCommand(id: "sys.volumeHalf", title: "Volume to 50%", subtitle: "", symbol: "speaker.wave.2",
                      keywords: ["volume", "half"]) { osascript("set volume output volume 50") },
        SystemCommand(id: "sys.emptyTrash", title: "Empty Trash", subtitle: "Permanently delete everything in the Trash", symbol: "trash",
                      keywords: ["trash", "bin", "delete"]) { osascript("tell application \"Finder\" to empty trash") },
        SystemCommand(id: "sys.screenshot", title: "Screenshot Selection", subtitle: "Capture part of the screen to the clipboard", symbol: "camera.viewfinder",
                      keywords: ["screenshot", "capture", "screen"]) { DispatchQueue.global().async { _ = shell("/usr/sbin/screencapture", ["-i", "-c"]) } },
        SystemCommand(id: "sys.settings", title: "System Settings", subtitle: "", symbol: "gearshape.2",
                      keywords: ["preferences", "settings", "system"]) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        },
        SystemCommand(id: "sys.activity", title: "Activity Monitor", subtitle: "", symbol: "chart.bar",
                      keywords: ["cpu", "memory", "processes", "kill"]) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        },
        SystemCommand(id: "sys.pickColor", title: "Pick Color", subtitle: "Sample any pixel and copy its hex", symbol: "eyedropper",
                      keywords: ["color", "colour", "picker", "hex", "eyedropper"]) { Task { @MainActor in ColorPicker.pick() } },
        SystemCommand(id: "sys.wifiOn", title: "Wi-Fi On", subtitle: "", symbol: "wifi", keywords: ["wifi", "wi-fi", "network", "internet"]) { Radios.wifi(true) },
        SystemCommand(id: "sys.wifiOff", title: "Wi-Fi Off", subtitle: "", symbol: "wifi.slash", keywords: ["wifi", "wi-fi", "network", "internet"]) { Radios.wifi(false) },
        SystemCommand(id: "sys.btOn", title: "Bluetooth On", subtitle: "", symbol: "dot.radiowaves.left.and.right", keywords: ["bluetooth", "airpods"]) { Radios.bluetooth(true) },
        SystemCommand(id: "sys.btOff", title: "Bluetooth Off", subtitle: "", symbol: "wifi.slash", keywords: ["bluetooth", "airpods"]) { Radios.bluetooth(false) },
        SystemCommand(id: "sys.joinMeeting", title: "Join Next Meeting", subtitle: "Opens the video-call link of your next event", symbol: "video",
                      keywords: ["join", "meeting", "zoom", "meet", "teams", "call"]) {
            Task { @MainActor in
                if let url = CalendarService.shared.next?.joinURL { NSWorkspace.shared.open(url) } else { Toast.show("calendar", "No meeting link found") }
            }
        },
        SystemCommand(id: "sys.snippetFromClipboard", title: "Create Snippet from Clipboard", subtitle: "Save what you copied for pasting later", symbol: "text.badge.plus",
                      keywords: ["snippet", "save", "clipboard", "text"]) {
            Task { @MainActor in
                if let t = NSPasteboard.general.string(forType: .string), !t.isEmpty {
                    SnippetStore.shared.add(name: String(t.prefix(40)).replacingOccurrences(of: "\n", with: " "), text: t)
                    Toast.show("text.badge.plus", "Snippet saved")
                }
            }
        },
        SystemCommand(id: "sys.hideOthers", title: "Hide All Other Apps", subtitle: "Clear the screen of everything but the front app", symbol: "eye.slash",
                      keywords: ["hide", "focus", "declutter"]) {
            let front = NSWorkspace.shared.frontmostApplication
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != front { app.hide() }
        },
    ]

    /// Runs `command` in the user's terminal via a temp `.command` file — no Apple Events permission needed.
    static func runInTerminal(_ command: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("run-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh\n\(command)\nprintf '\\n[done — press any key]'; read -k 1\nrm -f \"$0\"\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let terminal = (ConfigFile.load()["terminal"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Terminal"
            _ = shell("/usr/bin/open", ["-a", terminal, file.path])
        } catch {
            Log.warn("could not write terminal script: \(error.localizedDescription)")
        }
    }
}
