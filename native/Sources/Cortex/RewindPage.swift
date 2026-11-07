import SwiftUI
import AppKit

/// Scrub back through the last two hours of Screen Memory from the Island.
struct RewindPage: View {
    @State private var frames: [FrameHit] = []
    @State private var index: Double = 0
    @State private var message: String?

    private var current: FrameHit? {
        guard !frames.isEmpty else { return nil }
        return frames[min(frames.count - 1, max(0, Int(index.rounded())))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let f = current {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.appName).font(.system(size: 14, weight: .semibold))
                        if !f.windowTitle.isEmpty { Text(f.windowTitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
                        if !f.snippet.isEmpty { Text(f.snippet).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(2) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(Date(timeIntervalSince1970: TimeInterval(f.timestamp)).formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        Button("Open") { open(f) }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.white.opacity(0.16), in: Capsule())
                    }
                }
                Slider(value: $index, in: 0...Double(max(1, frames.count - 1)), step: 1)
                    .tint(.white)
                HStack {
                    Text("Earlier").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Text("Now").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            } else {
                Spacer()
                Text(message ?? "Loading…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .task { await load() }
    }

    private func load() async {
        guard let client = Engine.client else { message = "The search engine isn't running."; return }
        do {
            let hits = try await client.timeline(hours: 2).sorted { $0.timestamp < $1.timestamp }
            frames = hits
            index = Double(max(0, hits.count - 1))
            if hits.isEmpty { message = "Nothing remembered yet. Turn on Screen Memory in Settings to scrub back through your day." }
        } catch {
            message = "Screen Memory isn't available right now."
        }
    }

    private func open(_ f: FrameHit) {
        if let u = f.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u); return }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == f.appName }) { app.activate() }
    }
}
