import Foundation
import Darwin

/// Any JSON value (search-result metadata is free-form).
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// One search result from the engine (same shape the Rust side serialises).
struct EngineResult: Codable, Identifiable, Equatable {
    let id: String
    let pluginId: String
    let sourceType: String
    let title: String
    let subtitle: String?
    let content: String?
    let path: String?
    let url: String?
    let score: Double
    let action: String
    let metadata: [String: JSONValue]?
}

struct EngineSearchResponse: Codable {
    let results: [EngineResult]
    let totalMs: Int
    let mode: String
}

struct EngineStatus: Codable {
    let recording: Bool
    let indexedItems: Int
    let storageBytes: Int
    let activePlugins: [String]
    let pluginCounts: [String: Int]
}

struct FrameHit: Codable, Identifiable {
    let timestamp: Int
    let appName: String
    let windowTitle: String
    let url: String?
    let snippet: String
    var id: String { "\(timestamp)-\(appName)" }
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to cortexd over `~/.cortex/cortexd.sock` (one JSON object per line). Reconnects
/// by itself, so the app can start before the engine is ready.
final class EngineClient: @unchecked Sendable {
    static let socketPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/cortexd.sock").path

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private let writeQueue = DispatchQueue(label: "cortex.engine.write")
    private var started = false

    var onConnectionChange: (@Sendable (Bool) -> Void)?

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0
    }

    // MARK: connection

    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread { [weak self] in
            while let self {
                if self.tryConnect() {
                    self.readLoop()
                    self.handleDisconnect()
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func tryConnect() -> Bool {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        if sock < 0 { return false }
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(sock); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { close(sock); return false }

        lock.lock(); fd = sock; lock.unlock()
        Log.info("engine: connected")
        onConnectionChange?(true)
        return true
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let sock: Int32 = { lock.lock(); defer { lock.unlock() }; return fd }()
        while true {
            let n = read(sock, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { deliver(line) }
            }
        }
    }

    private func handleDisconnect() {
        lock.lock()
        if fd >= 0 { close(fd) }
        fd = -1
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for (_, c) in waiting { c.resume(throwing: EngineError(message: "engine disconnected")) }
        Log.warn("engine: disconnected")
        onConnectionChange?(false)
    }

    private func deliver(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = (obj["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        guard let cont else { return }
        if let message = obj["error"] as? String {
            cont.resume(throwing: EngineError(message: message))
        } else {
            let result: Any = obj["result"] ?? NSNull()
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                cont.resume(returning: data)
            } else {
                cont.resume(throwing: EngineError(message: "unreadable reply"))
            }
        }
    }

    // MARK: calls

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            let sock = fd
            if sock < 0 {
                lock.unlock()
                cont.resume(throwing: EngineError(message: "engine is not running"))
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = cont
            lock.unlock()

            let payload: [String: Any] = ["id": id, "method": method, "params": params]
            guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
                fail(id, "could not encode request")
                return
            }
            data.append(0x0A)
            writeQueue.async { [weak self] in
                var offset = 0
                let ok: Bool = data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return false }
                    while offset < data.count {
                        let n = write(sock, base + offset, data.count - offset)
                        if n <= 0 { return false }
                        offset += n
                    }
                    return true
                }
                if !ok { self?.fail(id, "could not send to the engine") }
            }
        }
    }

    private func fail(_ id: Int, _ message: String) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(throwing: EngineError(message: message))
    }

    func decode<T: Decodable>(_ type: T.Type, _ method: String, _ params: [String: Any] = [:]) async throws -> T {
        let data = try await call(method, params)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func search(_ query: String, limit: Int = 30, sources: [String]? = nil) async throws -> EngineSearchResponse {
        var params: [String: Any] = ["query": query, "limit": limit]
        if let sources { params["sourceFilter"] = sources }
        return try await decode(EngineSearchResponse.self, "search", params)
    }

    func suggestions() async throws -> EngineSearchResponse {
        try await decode(EngineSearchResponse.self, "suggestions")
    }

    func execute(_ id: String) async throws {
        _ = try await call("execute", ["id": id])
    }

    func searchMemory(_ query: String) async throws -> [FrameHit] {
        try await decode([FrameHit].self, "search_memory", ["query": query])
    }

    func timeline(hours: Int = 6) async throws -> [FrameHit] {
        try await decode([FrameHit].self, "memory_timeline", ["hours": hours])
    }

    func status() async throws -> EngineStatus {
        try await decode(EngineStatus.self, "status")
    }
}

/// Launches `cortexd` from the app bundle and keeps it running.
final class EngineProcess {
    private var process: Process?
    private var stopped = false
    private var delay: TimeInterval = 1

    private var executable: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cortexd")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    var describe: String {
        guard let p = process else { return executable == nil ? "cortexd missing from the app bundle" : "not started" }
        return p.isRunning ? "running (pid \(p.processIdentifier))" : "exited (\(p.terminationStatus))"
    }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped else { return }
        guard let exe = executable else {
            Log.error("engine: cortexd is not in the app bundle (Contents/Helpers/cortexd)")
            return
        }
        let p = Process()
        p.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        env["CORTEX_CAPTURE_PAUSED"] = "1"   // screen memory stays off until enabled in Settings
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            guard let self, !self.stopped else { return }
            Log.warn("engine: cortexd exited (\(proc.terminationStatus)); restarting in \(self.delay)s")
            DispatchQueue.global().asyncAfter(deadline: .now() + self.delay) {
                self.delay = min(self.delay * 2, 30)
                self.launch()
            }
        }
        do {
            try p.run()
            process = p
            Log.info("engine: started cortexd (pid \(p.processIdentifier))")
        } catch {
            Log.error("engine: could not start cortexd: \(error)")
        }
    }
}
