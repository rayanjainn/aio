import SwiftUI
import AppKit

/// Shows the output of a shell command, refreshed every minute.
struct ScriptWidget: View {
    let config: WidgetConfig
    let store: WidgetStore
    @State private var output = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((config.title ?? "Command").uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                if running { ProgressView().controlSize(.mini) }
            }
            if (config.command ?? "").isEmpty {
                Text("Right-click → Edit Command…, or ask ⌘K:  widget battery cycle count").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(output.isEmpty ? "…" : output)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(config.size == .large ? 18 : 7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
        }
        .contextMenu {
            Button("Edit Command…") { edit() }
            Button("Refresh") { Task { await run() } }
        }
        .task(id: config.command) {
            while !Task.isCancelled {
                await run()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func run() async {
        guard let cmd = config.command, !cmd.isEmpty else { return }
        running = true
        let out = await Task.detached { ScriptWidget.execute(cmd) }.value
        output = out
        running = false
    }

    nonisolated static func execute(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "Could not run the command." }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return String(data: data.prefix(8_000), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func edit() {
        let alert = NSAlert()
        alert.messageText = "Command for this widget"
        alert.informativeText = "Runs with zsh every minute. The first lines of its output are shown."
        let title = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        title.placeholderString = "Title"
        title.stringValue = config.title ?? ""
        let cmd = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        cmd.placeholderString = "e.g. uptime"
        cmd.stringValue = config.command ?? ""
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        box.addSubview(title); box.addSubview(cmd)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.update(config.id) { $0.title = title.stringValue; $0.command = cmd.stringValue }
    }
}

/// "widget <description>" in ⌘K: the AI writes a command, you approve it, and it becomes a widget.
enum AIWidgetMaker {
    @MainActor
    static func make(_ description: String, store: WidgetStore) {
        Toast.show("sparkles", "Writing a widget…")
        Task { @MainActor in
            var text = ""
            do {
                let prompt = "Write ONE macOS zsh command (no explanation, no code fences, read-only, no sudo, no network writes) that prints: \(description). Keep output under 10 short lines."
                for try await chunk in AIChat.stream(prompt) { text += chunk }
            } catch {
                Toast.show("exclamationmark.triangle", error.localizedDescription)
                return
            }
            var cmd = text.trimmingCharacters(in: .whitespacesAndNewlines)
            cmd = cmd.replacingOccurrences(of: "```zsh", with: "").replacingOccurrences(of: "```bash", with: "").replacingOccurrences(of: "```", with: "")
            cmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return }
            // Never run AI-written commands without the person seeing them first.
            let alert = NSAlert()
            alert.messageText = "Create this widget?"
            alert.informativeText = "It will run this command every minute:\n\n\(cmd)"
            alert.addButton(withTitle: "Create Widget")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.addScript(title: String(description.prefix(40)), command: cmd)
        }
    }
}
