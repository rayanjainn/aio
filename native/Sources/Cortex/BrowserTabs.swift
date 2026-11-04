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
        Browser(bundle: "com.google.Chrome", name: "Google Chrome", safari: false),
        Browser(bundle: "com.brave.Browser", name: "Brave Browser", safari: false),
        Browser(bundle: "company.thebrowser.Browser", name: "Arc", safari: false),
        Browser(bundle: "com.microsoft.edgemac", name: "Microsoft Edge", safari: false),
    ]

    private static func osascript(_ source: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Blocking: call off the main thread. Only asks browsers that are already running.
    static func list() -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        for b in browsers where !NSRunningApplication.runningApplications(withBundleIdentifier: b.bundle).isEmpty {
            let titleKey = b.safari ? "name" : "title"
            let script = """
            tell application "\(b.name)"
              set out to ""
              set w to 0
              repeat with win in windows
                set w to w + 1
                set i to 0
                repeat with t in tabs of win
                  set i to i + 1
                  set out to out & w & tab & i & tab & (\(titleKey) of t) & tab & (URL of t) & linefeed
                end repeat
              end repeat
              return out
            end tell
            """
            for line in osascript(script).split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 4, let w = Int(f[0]), let i = Int(f[1]) else { continue }
                tabs.append(BrowserTab(bundle: b.bundle, window: w, index: i, title: f[2], url: f[3]))
            }
        }
        return tabs
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
            tell application "\(b.name)"
              activate
              set current tab of window \(tab.window) to tab \(tab.index) of window \(tab.window)
              set index of window \(tab.window) to 1
            end tell
            """
        } else {
            script = """
            tell application "\(b.name)"
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
