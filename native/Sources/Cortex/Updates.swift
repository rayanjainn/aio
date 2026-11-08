import AppKit
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
        // Any published release with a disk image (older previews were named "Cortex-native-…", releases are "Cortex-vX.Y.Z.dmg").
        let native = releases.filter { !$0.draft && $0.assets.contains(where: { $0.name.lowercased().hasSuffix(".dmg") }) }
        guard let best = native.max(by: { !isNewer($0.tag_name, than: $1.tag_name) && $0.tag_name != $1.tag_name }),
              isNewer(best.tag_name, than: current) else { return nil }
        let dmg = best.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browser_download_url
        return UpdateInfo(tag: best.tag_name, url: URL(string: dmg ?? best.html_url) ?? URL(string: best.html_url)!, notes: best.body ?? "")
    }
}

/// Downloads a release and swaps it in: a small detached script waits for Cortex to quit,
/// replaces the app from the .dmg and opens the new one.
@MainActor
final class SelfUpdater: ObservableObject {
    static let shared = SelfUpdater()

    @Published private(set) var busy = false
    @Published private(set) var message = ""

    func install(_ update: UpdateInfo) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = "Downloading \(update.tag)…"
        do {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/update", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (tmp, response) = try await URLSession.shared.download(from: update.url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw EngineError(message: "Download failed (\(http.statusCode))") }
            let dmg = dir.appendingPathComponent("Cortex.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmp, to: dmg)

            let appPath = Bundle.main.bundleURL.path
            guard FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
                NSWorkspace.shared.open(dmg)
                message = "Open the downloaded disk image and drag Cortex to Applications."
                return
            }
            let script = dir.appendingPathComponent("install.sh")
            let body = """
            #!/bin/bash
            PID="$1"; DMG="$2"; APP="$3"
            exec >>"$HOME/.cortex/logs/update.log" 2>&1
            echo "== $(date) updating $APP"
            while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
            MNT=$(mktemp -d /tmp/cortex-mnt.XXXXXX)
            hdiutil attach -nobrowse -quiet -mountpoint "$MNT" "$DMG" || exit 1
            if [ -d "$MNT/Cortex.app" ]; then
              rm -rf "$APP.old"
              mv "$APP" "$APP.old"
              if cp -R "$MNT/Cortex.app" "$APP"; then rm -rf "$APP.old"; else rm -rf "$APP"; mv "$APP.old" "$APP"; fi
              xattr -cr "$APP" 2>/dev/null
            fi
            hdiutil detach "$MNT" -quiet
            rm -f "$DMG"
            codesign -dv "$APP" 2>&1 | grep -E "Authority|Signature|Identifier"
            open "$APP"
            echo "== done"
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            p.arguments = ["/bin/bash", script.path, String(ProcessInfo.processInfo.processIdentifier), dmg.path, appPath]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            message = "Restarting to finish the update…"
            try? await Task.sleep(nanoseconds: 600_000_000)
            NSApp.terminate(nil)
        } catch {
            message = "Update failed: \(error.localizedDescription)"
            Log.warn("self-update: \(error)")
        }
    }
}
