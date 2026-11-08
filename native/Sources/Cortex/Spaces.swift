import AppKit

/// A Space is a whole setup you can switch to in one go: the Dock (apps, folders, widgets),
/// where your windows and browser tabs are, the launcher's wallpaper and the glass tint.
struct CortexSpace: Codable, Equatable {
    var name: String
    var launcherWallpaper: String
    var launcherDim: Double
    var dockDarken: Double
    var paletteDarken: Double
    var saved = Date()
}

enum Spaces {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/spaces.json")
    }

    static func all() -> [String: CortexSpace] {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([String: CortexSpace].self, from: d) else { return [:] }
        return s
    }

    private static func write(_ s: [String: CortexSpace]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    @MainActor
    static func save(_ name: String, dock: DockModel?) {
        let p = Prefs.shared
        var s = all()
        s[name] = CortexSpace(name: name, launcherWallpaper: p.launcherWallpaper, launcherDim: p.launcherDim,
                              dockDarken: p.dockDarken, paletteDarken: p.paletteDarken)
        write(s)
        dock?.saveProfile("space:" + name)
        let windows = WindowLayouts.save("space:" + name)
        Toast.show("square.stack.3d.up", "Saved Space “\(name)” — Dock, look and \(windows) windows")
    }

    @MainActor
    static func apply(_ name: String, dock: DockModel?) {
        guard let space = all()[name] else { return }
        let p = Prefs.shared
        p.launcherWallpaper = space.launcherWallpaper
        p.launcherDim = space.launcherDim
        p.dockDarken = space.dockDarken
        p.paletteDarken = space.paletteDarken
        dock?.applyProfile("space:" + name)
        WindowLayouts.restore("space:" + name)
        Toast.show("square.stack.3d.up", "Space “\(name)”")
    }

    static func delete(_ name: String) {
        var s = all(); s[name] = nil; write(s)
        WindowLayouts.delete("space:" + name)
    }
}
