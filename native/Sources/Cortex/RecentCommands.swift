import Foundation

/// The last things you ran from the palette, offered first next time (like Raycast's "Recent").
struct RecentCommand: Codable, Equatable {
    var title: String
    var subtitle: String
    var symbol: String
    var iconPath: String?
    var type: String      // command | system | web | file
    var value: String
}

enum RecentCommands {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/recent.json")
    }

    static func all() -> [RecentCommand] {
        guard let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([RecentCommand].self, from: d) else { return [] }
        return a
    }

    static func record(_ r: RecentCommand) {
        var a = all().filter { !($0.type == r.type && $0.value == r.value) }
        a.insert(r, at: 0)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Array(a.prefix(12))) { try? d.write(to: url, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
