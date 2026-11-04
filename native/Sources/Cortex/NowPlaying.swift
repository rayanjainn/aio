import AppKit
import Combine

/// One snapshot of the system-wide "Now Playing" session.
struct NowPlayingInfo {
    var bundleID: String
    var appName: String
    var title: String
    var artist: String
    var album: String
    var playing: Bool
    var duration: Double      // seconds (0 = unknown / live)
    var elapsed: Double       // seconds, as of `stamp`
    var rate: Double
    var stamp: Date
    var artwork: NSImage?

    /// Playhead now, extrapolated from the last report.
    func position(at now: Date = Date()) -> Double {
        let p = playing ? elapsed + now.timeIntervalSince(stamp) * (rate > 0 ? rate : 1) : elapsed
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

enum MRCommand: Int {
    case play = 0, pause = 1, toggle = 2, stop = 3, next = 4, previous = 5
}

/// Reads and controls the *system* Now Playing session (Apple Music, Spotify,
/// browsers, VLC… anything), through the vendored mediaremote-adapter.
///
/// Why not AppleScript: on macOS 26 Music's `current track` fails (-1728) for
/// streamed / autoplayed tracks, and since macOS 15.4 apps can't use the
/// MediaRemote framework directly. `/usr/bin/perl` is Apple-signed and allowed
/// to, so the adapter loads its helper framework inside perl and streams JSON.
final class MediaRemoteBridge: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    /// Human-readable health, shown in Diagnostics.
    @Published private(set) var status: String = "not started"
    private(set) var lastLineAt: Date?
    private(set) var lines = 0
    /// Last payload without the (huge) artwork, for Diagnostics.
    private(set) var lastPayloadSummary = "none"

    private var process: Process?
    private var buffer = Data()
    private var stopped = false
    private var restartDelay: TimeInterval = 1
    private var artCache: (key: String, image: NSImage?)?
    private let io = DispatchQueue(label: "cortex.mediaremote")

    // MARK: lifecycle

    func start() {
        stopped = false
        io.async { self.launch() }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private var adapterURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("mediaremote", isDirectory: true)
    }

    private func perlArguments(_ rest: [String]) -> [String]? {
        guard let dir = adapterURL else { return nil }
        let script = dir.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework").path
        guard FileManager.default.fileExists(atPath: script),
              FileManager.default.fileExists(atPath: framework) else { return nil }
        return [script, framework] + rest
    }

    private func launch() {
        guard !stopped else { return }
        guard let args = perlArguments(["stream", "--no-diff", "--micros"]) else {
            setStatus("adapter files missing from the app bundle")
            Log.error("mediaremote adapter missing from bundle")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.io.async { self?.ingest(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                Log.warn("mediaremote stderr: \(s)")
            }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Log.warn("mediaremote adapter exited (\(proc.terminationStatus))")
            self.setStatus("adapter exited (\(proc.terminationStatus)), restarting")
            self.io.asyncAfter(deadline: .now() + self.restartDelay) {
                self.restartDelay = min(self.restartDelay * 2, 30)
                self.launch()
            }
        }
        do {
            try p.run()
            process = p
            setStatus("running")
            Log.info("mediaremote adapter started (pid \(p.processIdentifier))")
        } catch {
            setStatus("could not start perl: \(error.localizedDescription)")
            Log.error("could not start mediaremote adapter: \(error)")
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: parsing

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            lines += 1
            lastLineAt = Date()
            restartDelay = 1
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            Log.warn("mediaremote: unparseable line (\(line.count) bytes)")
            return
        }
        let payload = obj["payload"] as? [String: Any]
        if let payload {
            let summary = payload.filter { $0.key != "artworkData" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            lastPayloadSummary = summary
        } else {
            lastPayloadSummary = "payload: null"
        }
        let parsed = payload.flatMap { parse(payload: $0) }
        DispatchQueue.main.async {
            if self.info?.title != parsed?.title || self.info?.playing != parsed?.playing {
                Log.info("now playing: \(parsed.map { "\($0.appName) — \($0.title) [\($0.playing ? "playing" : "paused")]" } ?? "nothing")")
            }
            self.info = parsed
        }
    }

    /// Turns one adapter payload into a snapshot. Exposed for tests/diagnostics.
    func parse(payload p: [String: Any]) -> NowPlayingInfo? {
        guard let title = p["title"] as? String, !title.isEmpty else { return nil }
        let bundle = (p["parentApplicationBundleIdentifier"] as? String) ?? (p["bundleIdentifier"] as? String) ?? ""
        func num(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
        let duration = (num("durationMicros") ?? 0) / 1_000_000
        let elapsed = (num("elapsedTimeMicros") ?? 0) / 1_000_000
        let stamp = num("timestampEpochMicros").map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        let rate = num("playbackRate") ?? ((p["playing"] as? Bool) == true ? 1 : 0)
        let playing = (p["playing"] as? Bool) ?? (rate > 0)

        var art: NSImage?
        if let b64 = p["artworkData"] as? String, !b64.isEmpty {
            let key = "\(title)|\(p["artist"] as? String ?? "")|\(b64.count)"
            if let c = artCache, c.key == key { art = c.image }
            else {
                art = Data(base64Encoded: b64, options: .ignoreUnknownCharacters).flatMap { NSImage(data: $0) }
                artCache = (key, art)
            }
        }
        return NowPlayingInfo(
            bundleID: bundle, appName: Self.displayName(forBundle: bundle),
            title: title, artist: (p["artist"] as? String) ?? "", album: (p["album"] as? String) ?? "",
            playing: playing, duration: duration, elapsed: elapsed, rate: rate, stamp: stamp, artwork: art
        )
    }

    private static func displayName(forBundle id: String) -> String {
        if id.isEmpty { return "" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id.split(separator: ".").last.map(String.init) ?? id
    }

    // MARK: control

    func send(_ command: MRCommand) { run(["send", String(command.rawValue)]) }

    func seek(to seconds: Double) { run(["seek", String(Int(max(0, seconds) * 1_000_000))]) }

    private func run(_ rest: [String]) {
        io.async {
            guard let args = self.perlArguments(rest) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit() }
            catch { Log.error("mediaremote \(rest.first ?? ""): \(error)") }
        }
    }
}
