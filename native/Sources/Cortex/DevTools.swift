import Foundation
import CryptoKit

/// Small developer utilities in the palette: uuid, epoch ⇄ date, base64, URL encoding, hashes.
enum DevTools {
    struct Result: Equatable { let title: String; let value: String; let symbol: String }

    static func results(for q: String, now: Date = Date()) -> [Result] {
        let t = q.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        var out: [Result] = []

        if lower == "uuid" || lower == "guid" {
            out.append(Result(title: UUID().uuidString.lowercased(), value: UUID().uuidString.lowercased(), symbol: "number"))
        }
        if lower == "now" || lower == "epoch" || lower == "timestamp" {
            let s = String(Int(now.timeIntervalSince1970))
            out.append(Result(title: s, value: s, symbol: "clock"))
            let iso = ISO8601DateFormatter().string(from: now)
            out.append(Result(title: iso, value: iso, symbol: "calendar"))
        }
        // 10-digit seconds or 13-digit milliseconds → a readable date
        if t.allSatisfy(\.isNumber), t.count == 10 || t.count == 13, let n = Double(t) {
            let date = Date(timeIntervalSince1970: t.count == 13 ? n / 1000 : n)
            let text = date.formatted(date: .complete, time: .standard)
            out.append(Result(title: text, value: ISO8601DateFormatter().string(from: date), symbol: "calendar.badge.clock"))
        }
        func arg(_ prefixes: [String]) -> String? {
            for p in prefixes where lower.hasPrefix(p + " ") {
                let rest = String(t.dropFirst(p.count + 1))
                return rest.isEmpty ? nil : rest
            }
            return nil
        }
        if let s = arg(["b64", "base64"]) {
            out.append(Result(title: Data(s.utf8).base64EncodedString(), value: Data(s.utf8).base64EncodedString(), symbol: "lock.doc"))
            if let d = Data(base64Encoded: s), let decoded = String(data: d, encoding: .utf8) {
                out.append(Result(title: decoded, value: decoded, symbol: "lock.open"))
            }
        }
        if let s = arg(["urlencode", "encode"]) {
            let e = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            out.append(Result(title: e, value: e, symbol: "link"))
        }
        if let s = arg(["urldecode", "decode"]) {
            let d = s.removingPercentEncoding ?? s
            out.append(Result(title: d, value: d, symbol: "link"))
        }
        if let s = arg(["sha256"]) {
            let h = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
            out.append(Result(title: h, value: h, symbol: "number.square"))
        }
        if let s = arg(["md5"]) {
            let h = Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
            out.append(Result(title: h, value: h, symbol: "number.square"))
        }
        return out
    }

    /// `port 3000` → processes listening on it (pid, name).
    static func listeners(port: Int) -> [(pid: Int32, name: String)] {
        let out = SystemCommands.shell("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        var res: [(Int32, String)] = []
        var pid: Int32?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("c"), let p = pid { res.append((p, String(line.dropFirst()))); pid = nil }
        }
        return res
    }

    static func localIP() -> String? {
        for iface in ["en0", "en1"] {
            let ip = SystemCommands.shell("/usr/sbin/ipconfig", ["getifaddr", iface]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty { return ip }
        }
        return nil
    }
}
