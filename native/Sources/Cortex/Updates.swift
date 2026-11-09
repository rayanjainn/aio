import AppKit
import Foundation
import ServiceManagement

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

/// Downloads a release and swaps it in: a small detached script waits for the app to quit,
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
            let dmg = dir.appendingPathComponent("AIO.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmp, to: dmg)

            let appPath = Bundle.main.bundleURL.path
            guard FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
                NSWorkspace.shared.open(dmg)
                message = "Open the downloaded disk image and drag AIO to Applications."
                return
            }
            let script = dir.appendingPathComponent("install.sh")
            let body = """
            #!/bin/bash
            PID="$1"; DMG="$2"; APP="$3"
            exec >>"$HOME/.cortex/logs/update.log" 2>&1
            echo "== $(date) updating $APP"
            while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
            MNT=$(mktemp -d /tmp/aio-mnt.XXXXXX)
            hdiutil attach -nobrowse -quiet -mountpoint "$MNT" "$DMG" || exit 1
            # New images hold AIO.app; older ones Cortex.app. An install still named Cortex.app moves to AIO.app.
            SRC=""
            for n in AIO.app Cortex.app; do if [ -d "$MNT/$n" ]; then SRC="$MNT/$n"; break; fi; done
            DEST="$APP"
            case "$APP" in */Cortex.app) DEST="$(dirname "$APP")/AIO.app" ;; esac
            if [ -n "$SRC" ]; then
              rm -rf "$DEST.old"
              if [ -e "$DEST" ]; then mv "$DEST" "$DEST.old"; fi
              if cp -R "$SRC" "$DEST"; then
                rm -rf "$DEST.old"
                if [ "$DEST" != "$APP" ]; then rm -rf "$APP"; fi
              else
                rm -rf "$DEST"
                if [ -e "$DEST.old" ]; then mv "$DEST.old" "$DEST"; fi
              fi
              xattr -cr "$DEST" 2>/dev/null
            fi
            hdiutil detach "$MNT" -quiet
            rm -f "$DMG"
            if [ ! -d "$DEST" ]; then DEST="$APP"; fi
            codesign -dv "$DEST" 2>&1 | grep -E "Authority|Signature|Identifier"
            open "$DEST"
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

/// One-time move to the new name. Versions up to v0.5.0 were called Cortex and their updater installs
/// "…/Cortex.app"; this release renames that bundle to AIO.app and relaunches from there. The bundle
/// identifier and signature are unchanged, so permissions and settings carry over.
enum AppRename {
    static let oldName = "Cortex.app", newName = "AIO.app"
    private static var loginFlag: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/relogin")
    }

    /// True when the app moved itself and a relaunch is on its way: the caller stops starting up.
    @MainActor static func migrateIfNeeded() -> Bool {
        let fm = FileManager.default
        let me = Bundle.main.bundleURL, dir = me.deletingLastPathComponent()
        if me.lastPathComponent == newName {
            cleanUpOldCopy(in: dir)
            if fm.fileExists(atPath: loginFlag.path) {
                try? fm.removeItem(at: loginFlag)
                try? SMAppService.mainApp.unregister()
                do { try SMAppService.mainApp.register() } catch { Log.warn("rename: login item: \(error)") }
            }
            return false
        }
        guard me.lastPathComponent == oldName, fm.isWritableFile(atPath: dir.path) else { return false }
        let target = dir.appendingPathComponent(newName)
        guard !fm.fileExists(atPath: target.path) else { return false }
        let wasLoginItem = SMAppService.mainApp.status == .enabled
        do { try fm.moveItem(at: me, to: target) } catch {
            Log.warn("rename: could not move \(me.path) to \(target.path): \(error)")
            return false
        }
        if wasLoginItem { fm.createFile(atPath: loginFlag.path, contents: Data()) }
        Log.info("rename: moved to \(target.path), relaunching")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", target.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.warn("rename: relaunch failed: \(error)")
            return false
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    /// An old Cortex.app next to AIO.app is the previous install of this same app: move it to the Trash.
    @MainActor private static func cleanUpOldCopy(in dir: URL) {
        let old = dir.appendingPathComponent(oldName)
        guard let b = Bundle(url: old), b.bundleIdentifier == Bundle.main.bundleIdentifier,
              !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == old.standardizedFileURL }) else { return }
        NSWorkspace.shared.recycle([old]) { _, error in
            if let error { Log.warn("rename: could not trash \(old.path): \(error)") } else { Log.info("rename: moved the old Cortex.app to the Trash") }
        }
    }
}
