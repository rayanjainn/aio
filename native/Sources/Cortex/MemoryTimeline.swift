import SwiftUI
import AppKit

/// A window onto Screen Memory: what was on screen, by hour, with search.
struct MemoryTimelineView: View {
    let client: EngineClient
    @State private var query = ""
    @State private var hours = 6
    @State private var hits: [FrameHit] = []
    @State private var loading = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    private var groups: [(String, [FrameHit])] {
        var order: [String] = []
        var buckets: [String: [FrameHit]] = [:]
        let cal = Calendar.current
        for h in hits.sorted(by: { $0.timestamp > $1.timestamp }) {
            let d = Date(timeIntervalSince1970: TimeInterval(h.timestamp))
            let key = cal.isDateInToday(d)
                ? d.formatted(.dateTime.hour()) + " today"
                : d.formatted(.dateTime.weekday(.abbreviated).hour())
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(h)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search what you've seen…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .onSubmit { reload() }
                Picker("", selection: $hours) {
                    Text("1 h").tag(1); Text("6 h").tag(6); Text("24 h").tag(24); Text("7 d").tag(168)
                }
                .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                .disabled(!query.isEmpty)
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(14)
            Divider()
            if let message {
                Spacer()
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                Spacer()
            } else {
                List {
                    ForEach(groups, id: \.0) { title, items in
                        Section(title) {
                            ForEach(items) { h in
                                Button { open(h) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(h.appName).font(.system(size: 13, weight: .semibold))
                                            Spacer()
                                            Text(Date(timeIntervalSince1970: TimeInterval(h.timestamp)).formatted(date: .omitted, time: .shortened))
                                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                        if !h.windowTitle.isEmpty { Text(h.windowTitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                                        if !h.snippet.isEmpty { Text(h.snippet).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(2) }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { reload() }
        .onChange(of: hours) { _, _ in reload() }
        .onChange(of: query) { _, new in if new.isEmpty { reload() } }
    }

    private func open(_ h: FrameHit) {
        if let u = h.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
    }

    private func reload() {
        task?.cancel()
        loading = true
        let q = query.trimmingCharacters(in: .whitespaces)
        let h = hours
        task = Task {
            do {
                let result = q.isEmpty ? try await client.timeline(hours: h) : try await client.searchMemory(q)
                if Task.isCancelled { return }
                await MainActor.run {
                    hits = result
                    loading = false
                    message = result.isEmpty
                        ? (q.isEmpty ? "Nothing remembered in this period.\nTurn on Screen Memory in Settings → Screen Memory (it is off by default)."
                                     : "No matches for “\(q)”.")
                        : nil
                }
            } catch {
                await MainActor.run { loading = false; message = "The search engine isn't ready yet — try again in a moment." }
            }
        }
    }
}
