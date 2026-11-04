import Foundation
import os

/// Logs to the unified log AND ~/.cortex/logs/native.log (so a bundled app is never a black box).
enum Log {
    private static let logger = Logger(subsystem: "dev.cortex.native", category: "app")
    private static let queue = DispatchQueue(label: "cortex.log")

    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cortex/logs", isDirectory: true)
    static let fileURL: URL = directory.appendingPathComponent("native.log")

    private static let handle: FileHandle? = {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = (attrs[.size] as? NSNumber)?.intValue, size > 5_000_000 {
            let old = fileURL.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(message)\n"
        queue.async { handle?.write(Data(line.utf8)) }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
