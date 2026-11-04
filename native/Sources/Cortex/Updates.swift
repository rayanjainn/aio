import Foundation

/// Looks at the GitHub releases for a newer build. (Native previews are published as
/// pre-releases, so "newest" includes those.)
struct UpdateInfo { let tag: String; let url: URL; let notes: String }

enum UpdateChecker {
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let draft: Bool
        let body: String?
        let html_url: String
        let assets: [Asset]
    }

    /// Digits in order: "v0.3.0-native.4" → [0, 3, 0, 4].
    static func numbers(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Returns the newest native release if it is newer than `current`, else nil.
    static func check(current: String) async throws -> UpdateInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/rayanjainn/aio/releases?per_page=15")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let releases = try JSONDecoder().decode([Release].self, from: data)
        let native = releases.filter { !$0.draft && $0.assets.contains(where: { $0.name.hasSuffix(".dmg") && $0.name.lowercased().contains("native") }) }
        guard let best = native.max(by: { !isNewer($0.tag_name, than: $1.tag_name) && $0.tag_name != $1.tag_name }),
              isNewer(best.tag_name, than: current) else { return nil }
        let dmg = best.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browser_download_url
        return UpdateInfo(tag: best.tag_name, url: URL(string: dmg ?? best.html_url) ?? URL(string: best.html_url)!, notes: best.body ?? "")
    }
}
