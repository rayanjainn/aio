import AppKit

/// Export / import ~/.cortex/native to a folder of your choice. Secrets (ai.json) stay on this Mac.
enum SettingsTransfer {
    private static var source: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native", isDirectory: true)
    }
    private static let skip: Set<String> = ["ai.json", "run", "icons", "pins"]

    @MainActor
    static func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let dest = dir.appendingPathComponent("Cortex Settings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var n = 0
        for f in (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" || f.pathExtension == "md" {
            guard !skip.contains(f.lastPathComponent) else { continue }
            let to = dest.appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            if (try? FileManager.default.copyItem(at: f, to: to)) != nil { n += 1 }
        }
        Toast.show("square.and.arrow.up", "Exported \(n) settings files")
    }

    @MainActor
    static func importFrom() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        panel.message = "Choose the “Cortex Settings” folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var n = 0
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" || f.pathExtension == "md" {
            guard !skip.contains(f.lastPathComponent) else { continue }
            let to = source.appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            if (try? FileManager.default.copyItem(at: f, to: to)) != nil { n += 1 }
        }
        let alert = NSAlert()
        alert.messageText = "Imported \(n) settings files"
        alert.informativeText = "Quit and reopen Cortex to use them."
        alert.runModal()
    }
}
