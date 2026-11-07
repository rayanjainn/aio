import Foundation
import Combine
import ServiceManagement

/// App settings, saved to ~/.cortex/native/prefs.json. Windows observe the published values,
/// so changing one in Settings applies live.
final class Prefs: ObservableObject {
    static let shared = Prefs()

    @Published var dockEnabled = true { didSet { save() } }
    @Published var dockIconSize = 44.0 { didSet { save() } }
    @Published var dockMagnify = true { didSet { save() } }
    @Published var dockEdge = "bottom" { didSet { save() } }
    @Published var dockAutohide = false { didSet { save() } }
    @Published var dockDarken = 0.0 { didSet { save() } }
    @Published var dockShowTrash = true { didSet { save() } }
    @Published var dockPreviews = true { didSet { save() } }
    @Published var dockMagnification = 1.55 { didSet { save() } }
    @Published var dockSpacing = 7.0 { didSet { save() } }
    @Published var dockRoundness = 0.42 { didSet { save() } }
    @Published var dockIndicators = true { didSet { save() } }
    @Published var dockBounce = true { didSet { save() } }
    @Published var dockShowRunning = true { didSet { save() } }
    @Published var dockDisplay = "main" { didSet { save() } }
    @Published var dockClickHides = false { didSet { save() } }
    @Published var islandHideFullscreen = true { didSet { save() } }
    @Published var islandApps: [String] = [] { didSet { save() } }
    @Published var islandDisplay = "auto" { didSet { save() } }
    @Published var islandEnabled = true { didSet { save() } }
    @Published var islandMusic = true { didSet { save() } }
    @Published var islandHUD = true { didSet { save() } }
    @Published var islandCalendar = true { didSet { save() } }
    @Published var islandBluetooth = true { didSet { save() } }
    @Published var islandDownloads = true { didSet { save() } }
    @Published var islandPrivacy = true { didSet { save() } }
    @Published var islandLyrics = true { didSet { save() } }
    @Published var islandCharging = true { didSet { save() } }
    @Published var islandHoverExpand = true { didSet { save() } }
    @Published var paletteDarken = 0.42 { didSet { save() } }
    @Published var onboardingDone = false { didSet { save() } }

    private var loading = true

    private struct Stored: Codable {
        var dockEnabled: Bool?, dockIconSize: Double?, dockMagnify: Bool?
        var dockEdge: String?, dockAutohide: Bool?, dockDarken: Double?, dockShowTrash: Bool?, dockPreviews: Bool?
        var islandEnabled: Bool?, islandMusic: Bool?, islandCharging: Bool?, islandHoverExpand: Bool?
        var islandHUD: Bool?, islandCalendar: Bool?, islandBluetooth: Bool?, islandDownloads: Bool?, islandPrivacy: Bool?, islandLyrics: Bool?
        var paletteDarken: Double?, onboardingDone: Bool?
        var dockMagnification: Double?, dockSpacing: Double?, dockRoundness: Double?
        var dockIndicators: Bool?, dockBounce: Bool?, dockShowRunning: Bool?, dockDisplay: String?, islandDisplay: String?, dockClickHides: Bool?, islandApps: [String]?, islandHideFullscreen: Bool?
    }

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/prefs.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            dockEnabled = s.dockEnabled ?? true
            dockIconSize = (s.dockIconSize == 54 ? 44 : s.dockIconSize) ?? 44
            dockMagnify = s.dockMagnify ?? true
            dockEdge = s.dockEdge ?? "bottom"
            dockAutohide = s.dockAutohide ?? false
            dockDarken = s.dockDarken ?? 0
            dockShowTrash = s.dockShowTrash ?? true
            dockPreviews = s.dockPreviews ?? true
            dockMagnification = s.dockMagnification ?? 1.55
            dockSpacing = s.dockSpacing ?? 7
            dockRoundness = s.dockRoundness ?? 0.42
            dockIndicators = s.dockIndicators ?? true
            dockBounce = s.dockBounce ?? true
            dockShowRunning = s.dockShowRunning ?? true
            dockDisplay = s.dockDisplay ?? "main"
            islandDisplay = s.islandDisplay ?? "auto"
            dockClickHides = s.dockClickHides ?? false
            islandHideFullscreen = s.islandHideFullscreen ?? true
            islandApps = s.islandApps ?? []
            islandEnabled = s.islandEnabled ?? true
            islandMusic = s.islandMusic ?? true
            islandHUD = s.islandHUD ?? true
            islandCalendar = s.islandCalendar ?? true
            islandBluetooth = s.islandBluetooth ?? true
            islandDownloads = s.islandDownloads ?? true
            islandPrivacy = s.islandPrivacy ?? true
            islandLyrics = s.islandLyrics ?? true
            islandCharging = s.islandCharging ?? true
            islandHoverExpand = s.islandHoverExpand ?? true
            paletteDarken = s.paletteDarken ?? 0.42
            onboardingDone = s.onboardingDone ?? false
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(dockEnabled: dockEnabled, dockIconSize: dockIconSize, dockMagnify: dockMagnify,
                       dockEdge: dockEdge, dockAutohide: dockAutohide, dockDarken: dockDarken, dockShowTrash: dockShowTrash, dockPreviews: dockPreviews,
                       islandEnabled: islandEnabled, islandMusic: islandMusic, islandCharging: islandCharging,
                       islandHoverExpand: islandHoverExpand,
                       islandHUD: islandHUD, islandCalendar: islandCalendar, islandBluetooth: islandBluetooth, islandDownloads: islandDownloads,
                       islandPrivacy: islandPrivacy, islandLyrics: islandLyrics, paletteDarken: paletteDarken, onboardingDone: onboardingDone,
                       dockMagnification: dockMagnification, dockSpacing: dockSpacing, dockRoundness: dockRoundness,
                       dockIndicators: dockIndicators, dockBounce: dockBounce, dockShowRunning: dockShowRunning, dockDisplay: dockDisplay, islandDisplay: islandDisplay, dockClickHides: dockClickHides, islandApps: islandApps, islandHideFullscreen: islandHideFullscreen)
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.warn("launch at login: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}

/// Reads and writes `~/.cortex/config.json` while keeping every key we don't know about
/// (the engine and the old app share this file).
enum ConfigFile {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/config.json") }

    static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }

    static func save(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Log.warn("could not save config.json: \(error.localizedDescription)")
        }
    }

    static func shortcuts() -> [String: String] {
        (load()["shortcuts"] as? [String: String]) ?? [:]
    }

    static func setShortcut(_ id: String, _ accel: String?) {
        var cfg = load()
        var map = (cfg["shortcuts"] as? [String: String]) ?? [:]
        if let accel { map[id] = accel } else { map.removeValue(forKey: id) }
        cfg["shortcuts"] = map
        save(cfg)
    }
}
