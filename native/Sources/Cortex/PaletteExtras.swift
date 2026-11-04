import AppKit
import ApplicationServices
import CoreServices
import Carbon.HIToolbox

// MARK: toasts

/// A short message shown in the Island from anywhere in the app.
enum Toast {
    static let name = Notification.Name("cortex.island.toast")
    static func show(_ symbol: String, _ text: String) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: nil, userInfo: ["symbol": symbol, "text": text]) }
    }
}

// MARK: paste

enum PasteService {
    /// Types ⌘V into whatever app is in front (needs Accessibility).
    static func pasteIntoFront(after delay: TimeInterval = 0.2) {
        guard WindowManager.isTrusted else { WindowManager.requestAccess(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: snippets

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    var keyword = ""
}

@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    @Published var items: [Snippet] = []

    private static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/snippets.json") }

    init() {
        if let data = try? Data(contentsOf: Self.url), let list = try? JSONDecoder().decode([Snippet].self, from: data) { items = list }
    }

    func save() {
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }

    func add(name: String, text: String) { items.insert(Snippet(name: name, text: text), at: 0); save() }
    func remove(_ s: Snippet) { items.removeAll { $0.id == s.id }; save() }

    func matching(_ q: String) -> [Snippet] {
        let t = q.lowercased().trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return Array(items.prefix(8)) }
        return items.filter { $0.name.lowercased().contains(t) || $0.keyword.lowercased() == t || $0.text.lowercased().contains(t) }
    }
}

// MARK: quicklinks

struct Quicklink: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var keyword: String
    var url: String          // may contain {query}
}

@MainActor
final class QuicklinkStore: ObservableObject {
    static let shared = QuicklinkStore()
    @Published var items: [Quicklink] = []

    private static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/quicklinks.json") }

    static let defaults: [Quicklink] = [
        Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}"),
        Quicklink(name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query={query}"),
        Quicklink(name: "Google Maps", keyword: "maps", url: "https://www.google.com/maps/search/{query}"),
        Quicklink(name: "Wikipedia", keyword: "wiki", url: "https://en.wikipedia.org/w/index.php?search={query}"),
        Quicklink(name: "Stack Overflow", keyword: "so", url: "https://stackoverflow.com/search?q={query}"),
        Quicklink(name: "MDN", keyword: "mdn", url: "https://developer.mozilla.org/en-US/search?q={query}"),
        Quicklink(name: "npm", keyword: "npm", url: "https://www.npmjs.com/search?q={query}"),
        Quicklink(name: "Amazon", keyword: "amz", url: "https://www.amazon.com/s?k={query}"),
        Quicklink(name: "DuckDuckGo", keyword: "ddg", url: "https://duckduckgo.com/?q={query}"),
        Quicklink(name: "Google Translate", keyword: "tr", url: "https://translate.google.com/?sl=auto&tl=en&text={query}"),
    ]

    init() {
        if let data = try? Data(contentsOf: Self.url), let list = try? JSONDecoder().decode([Quicklink].self, from: data) { items = list }
        else { items = Self.defaults }
    }

    func save() {
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }

    /// "gh swiftui" → the GitHub search URL for "swiftui".
    func resolve(_ q: String) -> (link: Quicklink, url: String)? {
        let parts = q.split(separator: " ", maxSplits: 1).map(String.init)
        guard let key = parts.first?.lowercased(),
              let link = items.first(where: { $0.keyword.lowercased() == key }) else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""
        let encoded = rest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rest
        return (link, link.url.replacingOccurrences(of: "{query}", with: encoded))
    }
}

// MARK: currency

enum CurrencyService {
    private static var cache: [String: (Date, Double)] = [:]

    static func parse(_ q: String) -> (amount: Double, from: String, to: String)? {
        let pattern = #"^(\d+(?:\.\d+)?)\s*([a-zA-Z]{3})\s*(?:to|in|=|->)\s*([a-zA-Z]{3})$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), m.numberOfRanges == 4,
              let a = Range(m.range(at: 1), in: q), let f = Range(m.range(at: 2), in: q), let t = Range(m.range(at: 3), in: q),
              let amount = Double(q[a]) else { return nil }
        return (amount, q[f].uppercased(), q[t].uppercased())
    }

    /// Rates from frankfurter.app (free, no key, European Central Bank data).
    static func convert(_ amount: Double, from: String, to: String) async -> Double? {
        let key = "\(from)>\(to)"
        if let c = cache[key], Date().timeIntervalSince(c.0) < 3600 { return c.1 * amount }
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=\(from)&to=\(to)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rates = obj["rates"] as? [String: Any], let rate = (rates[to] as? NSNumber)?.doubleValue else { return nil }
        cache[key] = (Date(), rate)
        return rate * amount
    }
}

// MARK: dictionary

enum DictionaryLookup {
    static func define(_ word: String) -> String? {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        let range = CFRangeMake(0, w.utf16.count)
        guard let def = DCSCopyTextDefinition(nil, w as CFString, range)?.takeRetainedValue() else { return nil }
        return def as String
    }
}

// MARK: menu items of the front app

struct MenuEntry {
    let id: String
    let title: String
    let path: String
    let element: AXUIElement
}

enum MenuItemService {
    static func entries(forPID pid: pid_t) -> [MenuEntry] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let barEl = bar else { return [] }
        var out: [MenuEntry] = []
        func children(_ el: AXUIElement) -> [AXUIElement] {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
            return (v as? [AXUIElement]) ?? []
        }
        func walk(_ el: AXUIElement, path: [String], depth: Int) {
            guard depth < 5, out.count < 500 else { return }
            for child in children(el) {
                let role = WindowService.stringAttr(child, kAXRoleAttribute as String) ?? ""
                let title = WindowService.stringAttr(child, kAXTitleAttribute as String) ?? ""
                if role == "AXMenu" || role == "AXMenuBar" { walk(child, path: path, depth: depth + 1); continue }
                guard role == "AXMenuItem" || role == "AXMenuBarItem", !title.isEmpty else { continue }
                if depth == 0 && title == "Apple" { continue }
                let subs = children(child)
                if subs.isEmpty || role == "AXMenuBarItem" {
                    if role == "AXMenuItem", WindowService.boolAttr(child, kAXEnabledAttribute as String) != false {
                        out.append(MenuEntry(id: "menu:\((path + [title]).joined(separator: "/"))", title: title, path: path.joined(separator: " › "), element: child))
                    }
                    walk(child, path: path + [title], depth: depth + 1)
                } else {
                    walk(child, path: path + [title], depth: depth + 1)
                }
            }
        }
        walk(barEl as! AXUIElement, path: [], depth: 0)
        return out
    }

    static func press(_ entry: MenuEntry) {
        AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
    }
}

// MARK: scripts

struct ScriptCommand {
    let name: String
    let path: String
}

enum ScriptService {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/scripts", isDirectory: true) }

    static func list() -> [ScriptCommand] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { n in
            let path = directory.appendingPathComponent(n).path
            guard fm.isExecutableFile(atPath: path) else { return nil }
            let base = (n as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return ScriptCommand(name: base, path: path)
        }
    }

    /// Runs the script quietly and shows its first line of output in the Island.
    static func run(_ s: ScriptCommand) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: s.path)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do { try p.run() } catch { Toast.show("exclamationmark.triangle", "Couldn't run \(s.name)"); return }
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").first.map(String.init) ?? ""
            Toast.show(p.terminationStatus == 0 ? "checkmark.circle" : "xmark.circle", text.isEmpty ? "\(s.name) finished" : String(text.prefix(40)))
        }
    }
}

// MARK: colour picker

enum ColorPicker {
    private static var sampler: NSColorSampler?

    @MainActor
    static func pick() {
        let s = NSColorSampler()
        sampler = s
        s.show { color in
            sampler = nil
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
            PasteService.copy(hex)
            Toast.show("eyedropper", "Copied \(hex)")
        }
    }
}

// MARK: radios

enum Radios {
    static func wifi(_ on: Bool) {
        DispatchQueue.global().async {
            // The Wi-Fi interface is usually en0; ask networksetup to be sure.
            let list = SystemCommands.shell("/usr/sbin/networksetup", ["-listallhardwareports"])
            var device = "en0"
            let lines = list.split(separator: "\n").map(String.init)
            for (i, l) in lines.enumerated() where l.contains("Wi-Fi") && i + 1 < lines.count {
                if let d = lines[i + 1].split(separator: ":").last { device = d.trimmingCharacters(in: .whitespaces) }
            }
            _ = SystemCommands.shell("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"])
            Toast.show(on ? "wifi" : "wifi.slash", "Wi-Fi \(on ? "on" : "off")")
        }
    }

    /// Bluetooth power through IOBluetooth's long-standing (private) preference call.
    static func bluetooth(_ on: Bool) {
        typealias SetPower = @convention(c) (Int32) -> Void
        guard let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let sym = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else { Toast.show("exclamationmark.triangle", "Bluetooth control unavailable"); return }
        unsafeBitCast(sym, to: SetPower.self)(on ? 1 : 0)
        Toast.show(on ? "dot.radiowaves.left.and.right" : "wifi.slash", "Bluetooth \(on ? "on" : "off")")
    }
}


// MARK: Translate (MyMemory, free, no key)

enum TranslateService {
    /// `tr es good morning` / `translate fr where is the station` → (language code, text)
    static func parse(_ q: String) -> (to: String, text: String)? {
        let parts = q.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, ["tr", "translate"].contains(parts[0].lowercased()),
              parts[1].count == 2 || parts[1].count == 5, !parts[2].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (parts[1].lowercased(), parts[2])
    }

    static func translate(_ text: String, to code: String) async -> String? {
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")
        comps?.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "langpair", value: "autodetect|\(code)")]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let r = obj["responseData"] as? [String: Any], let out = r["translatedText"] as? String, !out.isEmpty else { return nil }
        return out
    }
}
