import Foundation

/// Claude Code and Codex usage, read from their local session logs. Nothing leaves the Mac.
///   Claude Code: ~/.claude/projects/**/*.jsonl — assistant messages carry `message.usage` and `message.model`.
///   Codex CLI:   ~/.codex/sessions/**/*.jsonl  — `token_count` payloads carry `info.last_token_usage`.
/// Files are read incrementally (a byte offset per file), so refreshing only parses new lines.
struct ToolUsage: Equatable {
    var installed = false
    var todayTokens = 0
    var todayMessages = 0
    var week = [Int](repeating: 0, count: 7)   // oldest first, last = today
    var blockTokens = 0                         // current 5-hour block (how Claude plans meter usage)
    var blockEndsAt: Date?
    var lastActive: Date?
    var active = false                          // activity in the last 2 minutes
    var model = ""
    var project = ""
}

final class CodingUsageService: ObservableObject {
    static let shared = CodingUsageService()

    @Published private(set) var claude = ToolUsage()
    @Published private(set) var codex = ToolUsage()

    private struct Entry { let ts: Int; let tokens: Int }
    private final class FileState {
        var offset: UInt64 = 0
        var entries: [Entry] = []
        var seen = Set<String>()
        var model = ""
        var project = ""
        var lastTs = 0
    }

    private var states: [String: FileState] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "cortex.coding", qos: .utility)
    private var watchers = 0

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let c = self.collect(root: home.appendingPathComponent(".claude/projects"), codex: false)
            let x = self.collect(root: home.appendingPathComponent(".codex/sessions"), codex: true)
            DispatchQueue.main.async {
                if c != self.claude { self.claude = c }
                if x != self.codex { self.codex = x }
            }
        }
    }

    // MARK: reading

    private func files(in root: URL, maxAgeDays: Double) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        var out: [URL] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]), let m = v.contentModificationDate, m >= cutoff else { continue }
            out.append(url)
        }
        return out
    }

    private func timestamp(_ obj: [String: Any]) -> Int? {
        guard let s = obj["timestamp"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map { Int($0.timeIntervalSince1970) }
    }

    private func refresh(_ url: URL, codex: Bool, state st: FileState) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < st.offset { st.offset = 0; st.entries = []; st.seen = []; st.model = ""; st.project = ""; st.lastTs = 0 }
        if size == st.offset { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: st.offset) } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only whole lines: keep a partial last line for next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data.subdata(in: data.startIndex..<data.index(after: lastNewline))
        st.offset += UInt64(complete.count)

        for lineData in complete.split(separator: 0x0A) {
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if codex {
                guard line.contains("token_count") || line.contains("\"model\"") else { continue }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(lineData))) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { continue }
                if (payload["type"] as? String) == "token_count" {
                    let last = (payload["info"] as? [String: Any])?["last_token_usage"] as? [String: Any] ?? [:]
                    let total = (last["total_tokens"] as? NSNumber)?.intValue
                        ?? ((last["input_tokens"] as? NSNumber)?.intValue ?? 0) + ((last["output_tokens"] as? NSNumber)?.intValue ?? 0)
                    if let ts = timestamp(obj), total > 0 { st.entries.append(Entry(ts: ts, tokens: total)); st.lastTs = max(st.lastTs, ts) }
                } else if let m = payload["model"] as? String { st.model = m }
            } else {
                guard line.contains("\"usage\"") else { continue }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(lineData))) as? [String: Any],
                      let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any], let ts = timestamp(obj) else { continue }
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let tokens = n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
                // Streaming writes the same message more than once; count it once.
                let key = "\(msg["id"] as? String ?? ""):\(obj["requestId"] as? String ?? "")"
                if !st.seen.insert(key).inserted { continue }
                if let m = msg["model"] as? String, !m.isEmpty, !m.hasPrefix("<") { st.model = m }
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty { st.project = URL(fileURLWithPath: cwd).lastPathComponent }
                st.lastTs = max(st.lastTs, ts)
                st.entries.append(Entry(ts: ts, tokens: tokens))
            }
        }
        let cutoff = Int(Date().timeIntervalSince1970) - 8 * 86400
        st.entries.removeAll { $0.ts < cutoff }
    }

    private func collect(root: URL, codex: Bool) -> ToolUsage {
        guard FileManager.default.fileExists(atPath: root.path) else { return ToolUsage() }
        var all: [Entry] = []
        var model = "", project = "", latest = 0
        for f in files(in: root, maxAgeDays: 8) {
            let st = states[f.path] ?? FileState()
            states[f.path] = st
            refresh(f, codex: codex, state: st)
            all += st.entries
            if st.lastTs >= latest { latest = st.lastTs; model = st.model; project = st.project }
        }
        var u = Self.summarize(all, now: Int(Date().timeIntervalSince1970), tzOffset: TimeZone.current.secondsFromGMT())
        u.model = Self.prettyModel(model)
        u.project = project
        return u
    }

    private static func summarize(_ input: [Entry], now: Int, tzOffset: Int) -> ToolUsage {
        let entries = input.sorted { $0.ts < $1.ts }
        func day(_ ts: Int) -> Int { Int(floor(Double(ts + tzOffset) / 86400)) }
        let today = day(now)
        var u = ToolUsage(installed: true)
        for e in entries {
            let d = today - day(e.ts)
            if (0..<7).contains(d) { u.week[6 - d] += e.tokens }
            if d == 0 { u.todayTokens += e.tokens; u.todayMessages += 1 }
        }
        var blockStart: Int?
        var prev = Int.min
        for e in entries {
            let expired = blockStart.map { e.ts >= $0 + 5 * 3600 } ?? false
            if blockStart == nil || expired || (prev != Int.min && e.ts - prev > 5 * 3600) { blockStart = e.ts - (e.ts % 3600) }
            prev = e.ts
        }
        if let s = blockStart, now < s + 5 * 3600 {
            u.blockTokens = entries.filter { $0.ts >= s }.reduce(0) { $0 + $1.tokens }
            u.blockEndsAt = Date(timeIntervalSince1970: TimeInterval(s + 5 * 3600))
        }
        if let last = entries.last {
            u.lastActive = Date(timeIntervalSince1970: TimeInterval(last.ts))
            u.active = now - last.ts < 120
        }
        return u
    }

    /// "claude-sonnet-4-5-20250929" → "Sonnet 4.5"
    static func prettyModel(_ m: String) -> String {
        guard m.hasPrefix("claude-") else { return m }
        let parts = m.dropFirst(7).split(separator: "-").filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        let name = parts.first(where: { $0.contains(where: \.isLetter) }).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        let ver = parts.filter { !$0.contains(where: \.isLetter) }.joined(separator: ".")
        return ver.isEmpty ? name : "\(name) \(ver)"
    }
}

func tokenString(_ n: Int) -> String {
    switch n {
    case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
    case 1_000_000...: return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", Double(n) / 1e6)
    case 1_000...: return String(format: n >= 10_000 ? "%.0fK" : "%.1fK", Double(n) / 1e3)
    default: return String(n)
    }
}
