import SwiftUI

struct WidgetHostView: View {
    @ObservedObject var store: WidgetStore
    @ObservedObject var bridge: MediaRemoteBridge
    @ObservedObject var power: PowerMonitor
    let id: String

    var body: some View {
        if let config = store.config(id) {
            content(config)
                .padding(16)
                .frame(width: config.size.dimensions.width, height: config.size.dimensions.height, alignment: .topLeading)
                .cortexGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), darken: 0.18)
                .environment(\.colorScheme, .dark)
                .contextMenu {
                    Menu("Size") {
                        ForEach(WidgetSize.allCases, id: \.self) { s in
                            Button(s.title) { store.update(id) { $0.size = s } }
                        }
                    }
                    Toggle("Float above windows", isOn: Binding(get: { config.floating }, set: { v in store.update(id) { $0.floating = v } }))
                    Divider()
                    Button("Remove widget", role: .destructive) { store.remove(id) }
                }
        }
    }

    @ViewBuilder private func content(_ config: WidgetConfig) -> some View {
        switch config.kind {
        case .clock: ClockWidget(size: config.size)
        case .calendar: CalendarWidget(size: config.size)
        case .system: SystemWidget(size: config.size, power: power)
        case .nowPlaying: NowPlayingWidget(size: config.size, bridge: bridge)
        case .notes: NotesWidget(config: config, store: store)
        case .todos: TodosWidget(config: config, store: store)
        case .weather: WeatherWidget(size: config.size)
        case .claude: CodingWidget(name: "Claude Code", symbol: "sparkles", size: config.size, claude: true)
        case .codex: CodingWidget(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", size: config.size, claude: false)
        }
    }
}

// MARK: clock

struct ClockWidget: View {
    let size: WidgetSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.date.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.8)
                Text(ctx.date.formatted(.dateTime.hour().minute()))
                    .font(.system(size: size == .small ? 42 : 56, weight: .thin, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(ctx.date.formatted(.dateTime.month(.wide).day()))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if size != .small {
                    Text(TimeZone.current.localizedName(for: .standard, locale: .current) ?? "")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: calendar

struct CalendarWidget: View {
    let size: WidgetSize

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let first = cal.date(from: comps) ?? now
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let today = cal.component(.day, from: now)
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + cal.firstWeekday - 1) % 7] }

        VStack(alignment: .leading, spacing: 6) {
            Text(now.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .semibold))
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 16) }
                ForEach(1...days, id: \.self) { d in
                    Text("\(d)")
                        .font(.system(size: 10, weight: d == today ? .bold : .regular)).monospacedDigit()
                        .frame(maxWidth: .infinity).frame(height: 16)
                        .background(d == today ? Color.white.opacity(0.9) : Color.clear, in: Circle())
                        .foregroundStyle(d == today ? Color.black : Color.primary)
                }
            }
        }
    }
}

// MARK: system

struct SystemWidget: View {
    let size: WidgetSize
    @ObservedObject var power: PowerMonitor
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            meter("CPU", value: stats.cpu, text: "\(Int(stats.cpu * 100))%")
            meter("Memory", value: stats.memoryTotal > 0 ? stats.memoryUsed / stats.memoryTotal : 0,
                  text: "\(gb(stats.memoryUsed)) / \(gb(stats.memoryTotal))")
            if size != .small {
                meter("Disk", value: stats.diskTotal > 0 ? 1 - stats.diskFree / stats.diskTotal : 0, text: "\(gb(stats.diskFree)) free")
                if let p = power.percent {
                    meter("Battery", value: Double(p) / 100, text: "\(p)%\(power.charging ? " ⚡︎" : "")")
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { stats.watch() }
        .onDisappear { stats.unwatch() }
    }

    private func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }

    private func meter(_ name: String, value: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); Spacer(); Text(text).font(.system(size: 11).monospacedDigit()) }
            ProgressView(value: min(max(value, 0), 1)).progressViewStyle(.linear).tint(.white)
        }
    }
}

// MARK: now playing

struct NowPlayingWidget: View {
    let size: WidgetSize
    @ObservedObject var bridge: MediaRemoteBridge

    var body: some View {
        if let t = bridge.info {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ArtworkView(image: t.artwork, size: size == .small ? 64 : 86, radius: 14)
                    if size != .small {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text(t.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            Text(t.appName).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if size == .small { Text(t.title).font(.system(size: 12, weight: .semibold)).lineLimit(2) }
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    Spacer()
                    button("backward.fill", .previous)
                    button(t.playing ? "pause.fill" : "play.fill", .toggle, big: true)
                    button("forward.fill", .next)
                    Spacer()
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Nothing playing").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func button(_ symbol: String, _ command: MRCommand, big: Bool = false) -> some View {
        Button { bridge.send(command) } label: {
            Image(systemName: symbol).font(.system(size: big ? 22 : 15)).frame(width: 30, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: notes + to-dos

struct NotesWidget: View {
    let config: WidgetConfig
    @ObservedObject var store: WidgetStore

    var body: some View {
        TextEditor(text: Binding(get: { config.text }, set: { v in store.update(config.id) { $0.text = v } }))
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
    }
}

struct TodosWidget: View {
    let config: WidgetConfig
    @ObservedObject var store: WidgetStore
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To-Do").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(config.todos) { item in
                        HStack(spacing: 8) {
                            Button {
                                store.update(config.id) { c in
                                    if let i = c.todos.firstIndex(where: { $0.id == item.id }) { c.todos[i].done.toggle() }
                                }
                            } label: { Image(systemName: item.done ? "checkmark.circle.fill" : "circle").font(.system(size: 14)) }
                                .buttonStyle(.plain)
                            Text(item.text).font(.system(size: 12)).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary).lineLimit(2)
                            Spacer(minLength: 0)
                            Button {
                                store.update(config.id) { $0.todos.removeAll { $0.id == item.id } }
                            } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            TextField("Add…", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit {
                    let t = draft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    store.update(config.id) { $0.todos.append(TodoItem(text: t)) }
                    draft = ""
                }
        }
    }
}

// MARK: weather

struct WeatherWidget: View {
    let size: WidgetSize
    @ObservedObject private var service = WeatherService.shared

    var body: some View {
        Group {
            if let w = service.weather {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(w.place.isEmpty ? "Weather" : w.place).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: w.symbol).font(.system(size: 18)).symbolRenderingMode(.hierarchical)
                    }
                    Text("\(Int(w.temperature.rounded()))°").font(.system(size: size == .small ? 44 : 54, weight: .thin, design: .rounded))
                    Spacer(minLength: 0)
                    Text(w.summary).font(.system(size: 12, weight: .medium))
                    Text("H \(Int(w.high.rounded()))°  L \(Int(w.low.rounded()))°").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cloud.sun").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(service.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { service.watch() }
        .onDisappear { service.unwatch() }
    }
}

// MARK: coding usage

struct CodingWidget: View {
    let name: String
    let symbol: String
    let size: WidgetSize
    let claude: Bool
    @ObservedObject private var usage = CodingUsageService.shared

    var body: some View {
        let u = claude ? usage.claude : usage.codex
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(name).font(.system(size: 12, weight: .semibold))
                Spacer()
                if u.active { Circle().fill(Color.white).frame(width: 6, height: 6) }
            }
            if !u.installed {
                Text("No sessions found").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Text(tokenString(u.todayTokens)).font(.system(size: size == .small ? 34 : 40, weight: .thin, design: .rounded))
                Text("tokens today · \(u.todayMessages) messages").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                sparkline(u.week)
                if size != .small {
                    HStack {
                        if !u.model.isEmpty { Text(u.model).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                        Spacer()
                        if let end = u.blockEndsAt {
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                let left = max(0, end.timeIntervalSince(ctx.date))
                                Text("5h block · \(tokenString(u.blockTokens)) · \(Int(left / 3600))h \(Int(left.truncatingRemainder(dividingBy: 3600) / 60))m left")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { usage.watch() }
        .onDisappear { usage.unwatch() }
    }

    private func sparkline(_ week: [Int]) -> some View {
        let peak = max(week.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(week.enumerated()), id: \.offset) { i, v in
                Capsule().fill(Color.white.opacity(i == week.count - 1 ? 0.95 : 0.4))
                    .frame(maxWidth: .infinity).frame(height: max(3, 28 * CGFloat(v) / CGFloat(peak)))
            }
        }
        .frame(height: 30, alignment: .bottom)
    }
}

// MARK: gallery

struct WidgetGalleryView: View {
    @ObservedObject var store: WidgetStore

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(WidgetKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: kind.symbol).font(.system(size: 26)).foregroundStyle(.secondary)
                        Text(kind.title).font(.system(size: 14, weight: .semibold))
                        Text(kind.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Add to desktop") { store.add(kind) }.buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(18)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}
