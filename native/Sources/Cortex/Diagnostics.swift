import AppKit
import SwiftUI

@MainActor
enum Diagnostics {
    static func report(island: IslandController?, dock: DockController?, bridge: MediaRemoteBridge, engineProcess: String, engineConnected: Bool, widgets: String = "") -> String {
        var out: [String] = []
        let os = ProcessInfo.processInfo
        out.append("Cortex native \(AppInfo.version)")
        out.append("macOS \(os.operatingSystemVersionString)  arch=\(machineArch())")
        out.append("log: \(Log.fileURL.path)")
        out.append("")
        out.append("== Screens ==")
        for (i, s) in NSScreen.screens.enumerated() {
            out.append("[\(i)] frame=\(NSStringFromRect(s.frame)) scale=\(s.backingScaleFactor) safeTop=\(s.safeAreaInsets.top) auxL=\(s.auxiliaryTopLeftArea.map { NSStringFromRect($0) } ?? "nil") auxR=\(s.auxiliaryTopRightArea.map { NSStringFromRect($0) } ?? "nil")")
        }
        out.append("")
        out.append("== Island ==")
        out.append(island?.describeGeometry() ?? "not created")
        out.append(island?.describePanel() ?? "")
        out.append("")
        out.append("== Engine ==")
        out.append("cortexd: \(engineProcess)  connected=\(engineConnected)")
        out.append("Accessibility (window snapping): \(WindowManager.isTrusted ? "granted" : "not granted")")
        out.append("hotkey errors: \(HotKeyCenter.shared.errors.isEmpty ? "none" : HotKeyCenter.shared.errors.map { "\($0.key): \($0.value)" }.joined(separator: "; "))")
        out.append("")
        out.append("== Widgets ==")
        out.append(widgets.isEmpty ? "none" : widgets)
        out.append("")
        out.append("== Dock ==")
        out.append(dock?.describe() ?? "not created")
        out.append("macOS Dock hidden by Cortex: \(SystemDock.hiddenByUs)")
        out.append("")
        out.append("== Now Playing (system) ==")
        out.append("adapter: \(bridge.status)  lines=\(bridge.lines)  last=\(bridge.lastLineAt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never")")
        if let i = bridge.info {
            out.append("\(i.appName) [\(i.bundleID)] — \(i.title) / \(i.artist) / \(i.album)  playing=\(i.playing) pos=\(Int(i.position()))/\(Int(i.duration)) art=\(i.artwork != nil)")
        } else {
            out.append("nothing reported")
        }
        out.append("raw: \(bridge.lastPayloadSummary)")
        let res = Bundle.main.resourceURL?.appendingPathComponent("mediaremote")
        out.append("bundle adapter dir: \(res?.path ?? "nil") exists=\(res.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
        return out.joined(separator: "\n")
    }

    private static func machineArch() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

struct DiagnosticsView: View {
    @State var text: String
    let refresh: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Refresh") { text = refresh() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Reveal log") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 620, minHeight: 380)
    }
}
