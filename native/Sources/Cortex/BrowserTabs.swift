import AppKit

struct BrowserTab: Identifiable, Equatable {
    let bundle: String
    let window: Int
    let index: Int
    let title: String
    let url: String
    var id: String { "\(bundle)|\(window)|\(index)" }
}

/// Lists and focuses open tabs in Safari and Chromium browsers through their AppleScript dictionaries.
enum BrowserTabs {
    private struct Browser { let bundle: String; let name: String; let safari: Bool }
    private static let browsers = [
        Browser(bundle: "com.apple.Safari", name: "Safari", safari: true),
        Browser(bundle: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", safari: true),
        Browser(bundle: "com.kagi.kagimacOS", name: "Orion", safari: true),
        Browser(bundle: "com.google.Chrome", name: "Google Chrome", safari: false),
        Browser(bundle: "com.google.Chrome.canary", name: "Google Chrome Canary", safari: false),
        Browser(bundle: "com.brave.Browser", name: "Brave Browser", safari: false),
        Browser(bundle: "com.brave.Browser.beta", name: "Brave Browser Beta", safari: false),
        Browser(bundle: "company.thebrowser.Browser", name: "Arc", safari: false),
        Browser(bundle: "com.microsoft.edgemac", name: "Microsoft Edge", safari: false),
        Browser(bundle: "org.chromium.Chromium", name: "Chromium", safari: false),
        Browser(bundle: "com.vivaldi.Vivaldi", name: "Vivaldi", safari: false),
        Browser(bundle: "com.operasoftware.Opera", name: "Opera", safari: false),
        Browser(bundle: "ai.perplexity.comet", name: "Comet", safari: false),
        Browser(bundle: "app.ferrite.browser", name: "Ferrite", safari: false),
    ]

    private static func osascript(_ source: String) -> (out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ("", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// Last problem per browser (shown by Settings → Connections → Browser tabs → Test).
    nonisolated(unsafe) static var lastErrors: [String: String] = [:]

    /// The AppleScript that lists every tab as "window<TAB>index<TAB>title<TAB>url" lines.
    /// Note: inside `tell application`, the word `tab` means the browser's tab class, not a tab character —
    /// so separators are written as `character id 9`.
    static func script(bundle: String, safari: Bool) -> String {
        let titleKey = safari ? "name" : "title"
        return """
        tell application id "\(bundle)"
          set sep to character id 9
          set out to ""
          set w to 0
          repeat with win in windows
            set w to w + 1
            set i to 0
            try
              repeat with t in tabs of win
                set i to i + 1
                set out to out & w & sep & i & sep & (\(titleKey) of t) & sep & (URL of t) & linefeed
              end repeat
            end try
          end repeat
          return out
        end tell
        """
    }

    /// Blocking: call off the main thread. Only asks browsers that are already running.
    static func list() -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        var errors: [String: String] = [:]
        for b in browsers where !NSRunningApplication.runningApplications(withBundleIdentifier: b.bundle).isEmpty {
            let result = osascript(script(bundle: b.bundle, safari: b.safari))
            if !result.err.isEmpty {
                let e = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
                errors[b.name] = e.contains("-1743") ? "Automation not allowed for \(b.name)" : e
                Log.warn("tabs: \(b.name): \(e)")
            }
            tabs += parse(result.out, bundle: b.bundle)
        }
        lastErrors = errors
        return tabs
    }

    static func parse(_ output: String, bundle: String) -> [BrowserTab] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let w = Int(f[0]), let i = Int(f[1]) else { return nil }
            return BrowserTab(bundle: bundle, window: w, index: i, title: f[2], url: f[3])
        }
    }

    static func matching(_ tabs: [BrowserTab], _ query: String) -> [BrowserTab] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return tabs }
        return tabs.filter { t in
            let hay = (t.title + " " + t.url).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    static func focus(_ tab: BrowserTab) {
        guard let b = browsers.first(where: { $0.bundle == tab.bundle }) else { return }
        let script: String
        if b.safari {
            script = """
            tell application id "\(b.bundle)"
              activate
              set current tab of window \(tab.window) to tab \(tab.index) of window \(tab.window)
              set index of window \(tab.window) to 1
            end tell
            """
        } else {
            script = """
            tell application id "\(b.bundle)"
              activate
              set active tab index of window \(tab.window) to \(tab.index)
              set index of window \(tab.window) to 1
            end tell
            """
        }
        DispatchQueue.global().async { _ = osascript(script) }
    }

    /// `tab:<bundle>|<window>|<index>` ids used by palette rows.
    static func parse(_ id: String) -> BrowserTab? {
        guard id.hasPrefix("tab:") else { return nil }
        let f = id.dropFirst(4).split(separator: "|").map(String.init)
        guard f.count == 3, let w = Int(f[1]), let i = Int(f[2]) else { return nil }
        return BrowserTab(bundle: f[0], window: w, index: i, title: "", url: "")
    }
}

/// `{date}`, `{time}`, `{clipboard}`… in snippets.
enum SnippetExpander {
    static func expand(_ text: String, now: Date = Date(), clipboard: String? = nil) -> String {
        guard text.contains("{") else { return text }
        let clip = clipboard ?? NSPasteboard.general.string(forType: .string) ?? ""
        let reps: [(String, String)] = [
            ("{datetime}", now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())),
            ("{date}", now.formatted(.iso8601.year().month().day())),
            ("{time}", now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())),
            ("{day}", now.formatted(.dateTime.weekday(.wide))),
            ("{uuid}", UUID().uuidString.lowercased()),
            ("{clipboard}", clip),
        ]
        var out = text
        for (k, v) in reps { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

/// Text you keep close: pinned from the clipboard, pasted with one command.
enum PinStore {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/pins.json")
    }

    static func all() -> [String] {
        guard let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return a
    }

    private static func write(_ pins: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(pins) { try? d.write(to: url, options: .atomic) }
    }

    static func addText(_ t: String) {
        var pins = all().filter { $0 != t }
        pins.insert(t, at: 0)
        write(Array(pins.prefix(50)))
    }

    private static var imagesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/pins", isDirectory: true)
    }

    @discardableResult
    static func addClipboard() -> Bool {
        let pb = NSPasteboard.general
        if (pb.string(forType: .string) ?? "").isEmpty,
           let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            let file = imagesDir.appendingPathComponent(UUID().uuidString + ".png")
            guard (try? png.write(to: file)) != nil else { return false }
            addText("img:" + file.path)
            return true
        }
        guard let t = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        var pins = all().filter { $0 != t }
        pins.insert(t, at: 0)
        write(Array(pins.prefix(50)))
        return true
    }

    static func remove(at index: Int) {
        var pins = all()
        guard pins.indices.contains(index) else { return }
        if pins[index].hasPrefix("img:") { try? FileManager.default.removeItem(atPath: String(pins[index].dropFirst(4))) }
        pins.remove(at: index)
        write(pins)
    }
}


/// One-line notes captured from the palette.
enum QuickNotes {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/quicknotes.md")
    }

    static func add(_ text: String) {
        let line = "- \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())) — \(text)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func recent(_ n: Int) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").suffix(n).reversed().map { line in
            let t = String(line)
            if let r = t.range(of: " — ") { return String(t[r.upperBound...]) }
            return t
        }
    }
}
