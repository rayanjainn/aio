import Foundation
import AppKit
import AVFoundation
import CoreAudio
import IOBluetooth

// MARK: Bluetooth

struct BluetoothDevice: Identifiable, Equatable {
    let id: String
    let name: String
    var battery: String?
}

/// Connected Bluetooth devices (AirPods, keyboards…), with battery levels from system_profiler.
final class BluetoothService: ObservableObject {
    static let shared = BluetoothService()

    @Published private(set) var connected: [BluetoothDevice] = []
    var onConnect: ((BluetoothDevice) -> Void)?
    private var timer: Timer?
    private var known: Set<String>?   // touched only on btQueue

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private let btQueue = DispatchQueue(label: "cortex.bluetooth", qos: .utility)

    private func poll() {
        btQueue.async { [weak self] in
            guard let self else { return }
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let now = paired.filter { $0.isConnected() }
            let ids = Set(now.compactMap { $0.addressString })
            let base = now.map { BluetoothDevice(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? "Bluetooth device", battery: nil) }
            let previous = self.known
            let newcomers = ids.subtracting(previous ?? ids)
            self.known = ids
            let current = DispatchQueue.main.sync { self.connected.map(\.id) }
            guard base.map(\.id) != current || !newcomers.isEmpty else { return }
            let levels = Self.batteryLevels()
            let enriched = base.map { d -> BluetoothDevice in
                var x = d
                x.battery = levels[d.name]
                return x
            }
            DispatchQueue.main.async {
                self.connected = enriched
                for d in enriched where newcomers.contains(d.id) { self.onConnect?(d) }
            }
        }
    }

    /// name → "85%" (or "L 80% · R 78%") for connected devices.
    static func batteryLevels() -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for section in sections {
            for entry in (section["device_connected"] as? [[String: Any]]) ?? [] {
                for (name, props) in entry {
                    guard let d = props as? [String: Any] else { continue }
                    let main = d["device_batteryLevelMain"] as? String
                    let left = d["device_batteryLevelLeft"] as? String
                    let right = d["device_batteryLevelRight"] as? String
                    if let l = left, let r = right { result[name] = "L \(l) · R \(r)" }
                    else if let m = main { result[name] = m }
                }
            }
        }
        return result
    }
}

// MARK: Downloads

/// Notices files being downloaded into ~/Downloads (Safari, Chrome, Firefox, Arc…).
final class DownloadWatcher: ObservableObject {
    static let shared = DownloadWatcher()

    @Published private(set) var active: [String] = []     // file names in progress
    private var timer: Timer?
    private let suffixes = [".crdownload", ".download", ".part", ".opdownload", ".partial"]

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private var lastSizes: [String: (UInt64, Date)] = [:]   // touched only on the utility queue

    private func poll() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var seen: [String: (UInt64, Date)] = [:]
            var busy: [String] = []
            for n in names where self.suffixes.contains(where: { n.hasSuffix($0) }) {
                let path = dir.appendingPathComponent(n).path
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < 15 else { continue }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                var base = n
                for s in self.suffixes where base.hasSuffix(s) { base = String(base.dropLast(s.count)) }
                var label = base
                if let (prev, at) = self.lastSizes[n], size > prev {
                    let rate = Double(size - prev) / max(0.5, Date().timeIntervalSince(at))
                    label += " · " + ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s"
                }
                seen[n] = (size, Date())
                busy.append(label)
            }
            self.lastSizes = seen
            DispatchQueue.main.async { if busy != self.active { self.active = busy } }
        }
    }
}

// MARK: Mic / camera in use

final class PrivacyIndicators: ObservableObject {
    static let shared = PrivacyIndicators()

    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private let queue = DispatchQueue(label: "cortex.privacy", qos: .utility)
    private lazy var cameraSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)

    private func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            let mic = Self.defaultInputRunning()
            let cam = self.cameraSession.devices.contains { $0.isInUseByAnotherApplication }
            DispatchQueue.main.async {
                if mic != self.micInUse { self.micInUse = mic }
                if cam != self.cameraInUse { self.cameraInUse = cam }
            }
        }
    }

    private static func defaultInputRunning() -> Bool {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var runAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &runAddr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

// MARK: Synced lyrics (lrclib.net)

struct LyricLine { let time: Double; let text: String }

/// Looks up time-synced lyrics for the playing track on lrclib.net (a free, open lyrics database).
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published private(set) var lines: [LyricLine] = []
    private var key = ""
    private var task: Task<Void, Never>?

    func load(for track: NowPlayingInfo?) {
        guard let t = track, !t.title.isEmpty else { key = ""; lines = []; return }
        let k = "\(t.title)|\(t.artist)|\(Int(t.duration))"
        guard k != key else { return }
        key = k
        lines = []
        task?.cancel()
        task = Task { [weak self] in
            var c = URLComponents(string: "https://lrclib.net/api/get")!
            c.queryItems = [URLQueryItem(name: "track_name", value: t.title), URLQueryItem(name: "artist_name", value: t.artist),
                            URLQueryItem(name: "album_name", value: t.album), URLQueryItem(name: "duration", value: String(Int(t.duration)))]
            guard let url = c.url else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue("Cortex (macOS launcher)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let lrc = obj["syncedLyrics"] as? String else { return }
            let parsed = Self.parse(lrc)
            if Task.isCancelled { return }
            await MainActor.run { if self?.key == k { self?.lines = parsed } }
        }
    }

    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.split(separator: "\n") {
            let line = String(raw)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { continue }
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            out.append(LyricLine(time: m * 60 + s, text: text))
        }
        return out.sorted { $0.time < $1.time }
    }

    func current(at position: Double) -> String? {
        guard !lines.isEmpty else { return nil }
        var found: String?
        for l in lines { if l.time <= position + 0.2 { found = l.text } else { break } }
        return found.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: Shortcuts app

struct ShortcutsService {
    static func list() async -> [String] {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        }.value
    }

    static func run(_ name: String) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
        }
    }
}
