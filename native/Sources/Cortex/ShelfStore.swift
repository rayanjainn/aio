import Foundation
import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var added = Date()
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// A temporary shelf: drop files on the Island to park them, drag them out later or AirDrop them.
/// Files stay where they are; the shelf only remembers the paths.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/shelf.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url), let list = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = list.filter(\.exists)
        }
    }

    /// Lines like  "png jpg heic -> ~/Pictures/Shelf"  copy matching dropped files to that folder.
    static func route(_ urls: [URL], rules: String) -> Int {
        var copied = 0
        for line in rules.split(separator: "\n") {
            let parts = line.components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            let exts = Set(parts[0].lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
            let folder = (parts[1].trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            guard !exts.isEmpty, !folder.isEmpty else { continue }
            for u in urls where exts.contains(u.pathExtension.lowercased()) || exts.contains("*") {
                let dir = URL(fileURLWithPath: folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(u.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path), (try? FileManager.default.copyItem(at: u, to: dest)) != nil { copied += 1 }
            }
        }
        return copied
    }

    func add(_ urls: [URL]) {
        let rules = Prefs.shared.shelfRules
        if !rules.isEmpty {
            let n = Self.route(urls, rules: rules)
            if n > 0 { Toast.show("folder.badge.plus", "Filed \(n) item\(n == 1 ? "" : "s") by your Shelf rules") }
        }
        var changed = false
        for u in urls where !items.contains(where: { $0.path == u.path }) {
            items.insert(ShelfItem(path: u.path), at: 0)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id }; save() }
    func clear() { items.removeAll(); save() }

    /// Takes file URLs out of a drop.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                guard let url else { return }
                Task { @MainActor in self.add([url]) }
            }
        }
        return accepted
    }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func save() {
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }
}
