import SwiftUI
import AppKit

/// Small live tiles that sit in the Dock between the icons: music, clock, battery, weather, timer, system, next meeting.
struct DockWidgetKind: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    /// Width as a multiple of the icon size (on a horizontal Dock).
    let span: CGFloat

    static let all: [DockWidgetKind] = [
        DockWidgetKind(id: "music", title: "Now Playing", symbol: "music.note", span: 4.4),
        DockWidgetKind(id: "clock", title: "Clock", symbol: "clock", span: 1.9),
        DockWidgetKind(id: "date", title: "Date", symbol: "calendar", span: 1.0),
        DockWidgetKind(id: "analog", title: "Analog Clock", symbol: "clock.circle", span: 1.0),
        DockWidgetKind(id: "battery", title: "Battery", symbol: "battery.100", span: 1.0),
        DockWidgetKind(id: "weather", title: "Weather", symbol: "cloud.sun", span: 2.2),
        DockWidgetKind(id: "timer", title: "Focus Timer", symbol: "timer", span: 1.0),
        DockWidgetKind(id: "stats", title: "System", symbol: "cpu", span: 1.7),
        DockWidgetKind(id: "github", title: "GitHub", symbol: "bell", span: 1.0),
        DockWidgetKind(id: "meeting", title: "Next Meeting", symbol: "calendar", span: 2.8),
    ]
    /// Not offered in "Add widget": the Dock adds it itself when running apps are grouped.
    static let running = DockWidgetKind(id: "running", title: "Active Apps", symbol: "square.grid.2x2", span: 2.2)

    static func find(_ id: String) -> DockWidgetKind? { id == "running" ? running : all.first { $0.id == id } }
}

/// Looks for the Dock's widget tiles, like LaunchMe's presets: glass by default, or a colour family.
struct DockWidgetTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let colors: [Color]          // top-left → bottom-right gradient; empty = glass
    let ink: Color

    static let all: [DockWidgetTheme] = [
        DockWidgetTheme(id: "glass", name: "Glass", colors: [], ink: .white),
        DockWidgetTheme(id: "graphite", name: "Graphite", colors: [Color(white: 0.22), Color(white: 0.08)], ink: .white),
        DockWidgetTheme(id: "paper", name: "Paper", colors: [Color(white: 0.97), Color(white: 0.86)], ink: Color(white: 0.08)),
        DockWidgetTheme(id: "sunrise", name: "Morning Tide", colors: [Color(red: 1.0, green: 0.80, blue: 0.47), Color(red: 0.96, green: 0.55, blue: 0.30)], ink: Color(red: 0.25, green: 0.12, blue: 0.04)),
        DockWidgetTheme(id: "ember", name: "Ember", colors: [Color(red: 0.98, green: 0.45, blue: 0.25), Color(red: 0.78, green: 0.16, blue: 0.20)], ink: .white),
        DockWidgetTheme(id: "ocean", name: "Ocean", colors: [Color(red: 0.25, green: 0.62, blue: 0.98), Color(red: 0.10, green: 0.25, blue: 0.68)], ink: .white),
        DockWidgetTheme(id: "mint", name: "Mint", colors: [Color(red: 0.62, green: 0.93, blue: 0.80), Color(red: 0.22, green: 0.66, blue: 0.56)], ink: Color(red: 0.03, green: 0.20, blue: 0.16)),
        DockWidgetTheme(id: "midnight", name: "Midnight Focus", colors: [Color(red: 0.24, green: 0.20, blue: 0.48), Color(red: 0.06, green: 0.06, blue: 0.16)], ink: .white),
        DockWidgetTheme(id: "rose", name: "Rose", colors: [Color(red: 1.0, green: 0.70, blue: 0.80), Color(red: 0.86, green: 0.36, blue: 0.56)], ink: .white),
    ]

    static func named(_ id: String) -> DockWidgetTheme { all.first { $0.id == id } ?? all[0] }
}

/// Ready-made Dock looks, LaunchMe-style: a set of widgets plus a colour style, applied in one click.
struct DockPreset: Identifiable {
    let id: String
    let name: String
    let detail: String
    let theme: String
    let widgets: [String]

    static let all: [DockPreset] = [
        DockPreset(id: "morning", name: "Morning Tide", detail: "Clock · Weather · Date · Now Playing", theme: "sunrise", widgets: ["clock", "weather", "date", "music"]),
        DockPreset(id: "midnight", name: "Midnight Focus", detail: "Clock · Focus timer · Now Playing · System", theme: "midnight", widgets: ["clock", "timer", "music", "stats"]),
        DockPreset(id: "studio", name: "Studio", detail: "Now Playing · System · Battery", theme: "graphite", widgets: ["music", "stats", "battery"]),
        DockPreset(id: "ocean", name: "Ocean Desk", detail: "Date · Weather · Next meeting · Now Playing", theme: "ocean", widgets: ["date", "weather", "meeting", "music"]),
        DockPreset(id: "developer", name: "Developer", detail: "GitHub · System · Focus timer · Clock", theme: "graphite", widgets: ["github", "stats", "timer", "clock"]),
        DockPreset(id: "paper", name: "Paper", detail: "Date · Clock · Weather", theme: "paper", widgets: ["date", "clock", "weather"]),
        DockPreset(id: "minimal", name: "Minimal", detail: "Just your apps, on glass", theme: "glass", widgets: []),
    ]

    @MainActor
    func apply(to model: DockModel) {
        for k in DockWidgetKind.all where model.hasWidget(k.id) { model.removeWidget(k.id) }
        // Each new widget is inserted at the same spot, so add them back to front to keep the listed order.
        for w in widgets.reversed() { model.addWidget(w) }
        Prefs.shared.dockWidgetTheme = theme
        Toast.show("dock.rectangle", "Dock: \(name)")
    }
}

struct DockWidgetTile: View {
    let kind: String
    let size: CGFloat
    let compact: Bool
    let model: DockModel
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let theme = DockWidgetTheme.named(prefs.dockWidgetTheme)
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if theme.colors.isEmpty {
                    shape.fill(Color.white.opacity(0.10))
                } else {
                    shape.fill(LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(theme.colors.isEmpty ? 0.16 : 0.28), lineWidth: 0.6))
            .clipShape(shape)
            .foregroundStyle(theme.ink)
            .environment(\.colorScheme, theme.ink == .white ? .dark : .light)
            .animation(.easeInOut(duration: 0.35), value: prefs.dockWidgetTheme)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case "music":
            if let bridge = model.bridge { MusicDockWidget(bridge: bridge, size: size, compact: compact) } else { Image(systemName: "music.note") }
        case "clock": ClockDockWidget(size: size, compact: compact)
        case "date": DateDockWidget(size: size)
        case "analog": AnalogDockClock(size: size)
        case "battery":
            if let power = model.power { BatteryDockWidget(power: power, size: size) } else { Image(systemName: "battery.100") }
        case "weather": WeatherDockWidget(size: size, compact: compact)
        case "timer": TimerDockWidget(size: size)
        case "stats": StatsDockWidget(size: size, compact: compact)
        case "meeting": MeetingDockWidget(size: size, compact: compact)
        case "running": RunningAppsTile(model: model, size: size)
        case "github": GitHubDockWidget(size: size)
        default: Image(systemName: "questionmark")
        }
    }
}

private struct MusicDockWidget: View {
    @ObservedObject var bridge: MediaRemoteBridge
    let size: CGFloat
    let compact: Bool

    var body: some View {
        let art = size - 10
        // Pick the richest layout that fits: artwork + title + progress + controls, then fewer controls,
        // then artwork alone. The tile is tinted with the blurred artwork, like the Island.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                artwork(art)
                titles.frame(minWidth: 44, idealWidth: 60, maxWidth: .infinity, alignment: .leading)
                controls(full: true)
            }
            HStack(spacing: 6) {
                artwork(art)
                titles.frame(minWidth: 30, idealWidth: 40, maxWidth: .infinity, alignment: .leading)
                controls(full: false)
            }
            HStack(spacing: 4) {
                artwork(art)
                controls(full: false)
            }
            artwork(art).overlay { playGlyph }
        }
        .padding(.horizontal, 6)
        // Fill the whole tile so the artwork tint reaches every edge (not just the box the content needs).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if let image = bridge.info?.artwork {
                Color.clear.overlay {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 18).opacity(0.55).scaleEffect(1.4)
                }
                .clipped()
                .overlay(Color.black.opacity(0.18))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: bridge.info?.title)
    }

    private func artwork(_ side: CGFloat) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) { NotificationCenter.default.post(name: .openMusicPlayer, object: nil) }
            else { bridge.send(.toggle) }
        } label: {
            ArtworkView(image: bridge.info?.artwork, size: side, radius: size * 0.16)
                .overlay { if compact { playGlyph } }
                .opacity(bridge.info == nil ? 0.55 : 1)
        }
        .buttonStyle(.plain)
    }

    private var playGlyph: some View {
        Image(systemName: bridge.info?.playing == true ? "pause.fill" : "play.fill")
            .font(.system(size: size * 0.28)).shadow(color: .black.opacity(0.6), radius: 3)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bridge.info?.title ?? "Not playing").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            if let artist = bridge.info?.artist, !artist.isEmpty {
                Text(artist).font(.system(size: 9)).foregroundStyle(.primary.opacity(0.65)).lineLimit(1)
            }
            if let t = bridge.info, t.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.22))
                            Capsule().fill(.primary.opacity(0.9)).frame(width: geo.size.width * min(1, max(0, t.position(at: ctx.date) / t.duration)))
                        }
                    }
                    .frame(height: 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NotificationCenter.default.post(name: .openMusicPlayer, object: nil) }
        .help("Open the full-screen player")
    }

    private func controls(full: Bool) -> some View {
        HStack(spacing: 0) {
            if full { control("backward.fill", .previous) }
            control(bridge.info?.playing == true ? "pause.fill" : "play.fill", .toggle)
            control("forward.fill", .next)
        }
        .opacity(bridge.info == nil ? 0.45 : 1)
    }

    private func control(_ symbol: String, _ command: MRCommand) -> some View {
        Button { bridge.send(command) } label: {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 17, height: 24).contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }.buttonStyle(.plain)
    }
}

/// A calendar-page tile: weekday in red, the day big underneath (like the Calendar icon). Click opens Calendar.
private struct DateDockWidget: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: -size * 0.04) {
                Text(ctx.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
                Text(ctx.date.formatted(.dateTime.day()))
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.open(url) }
            }
            .help(ctx.date.formatted(date: .complete, time: .omitted))
        }
    }
}

/// A watch face with big 12 · 3 · 6 · 9 numerals, like LaunchMe's Dock clock. Moves once a minute.
private struct AnalogDockClock: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let c = Calendar.current.dateComponents([.hour, .minute], from: ctx.date)
            let minute = Double(c.minute ?? 0)
            let hour = Double((c.hour ?? 0) % 12) + minute / 60
            ZStack {
                ForEach([(12, 0.0), (3, 90.0), (6, 180.0), (9, 270.0)], id: \.0) { n, angle in
                    Text("\(n)").font(.system(size: size * 0.2, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .offset(x: sin(angle * .pi / 180) * size * 0.3, y: -cos(angle * .pi / 180) * size * 0.3)
                }
                Capsule().fill(Color.primary).frame(width: size * 0.06, height: size * 0.24)
                    .offset(y: -size * 0.1).rotationEffect(.degrees(hour * 30))
                Capsule().fill(Color.primary).frame(width: size * 0.04, height: size * 0.34)
                    .offset(y: -size * 0.15).rotationEffect(.degrees(minute * 6))
                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: size * 0.08, height: size * 0.08)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help(ctx.date.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

private struct ClockDockWidget: View {
    let size: CGFloat
    let compact: Bool

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 0) {
                Text(ctx.date.formatted(.dateTime.hour().minute()))
                    .font(.system(size: size * (compact ? 0.26 : 0.34), weight: .semibold, design: .rounded).monospacedDigit())
                if !compact {
                    Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.system(size: size * 0.18)).foregroundStyle(.primary.opacity(0.6))
                }
            }
        }
    }
}

private struct BatteryDockWidget: View {
    @ObservedObject var power: PowerMonitor
    let size: CGFloat

    var body: some View {
        let p = power.percent ?? 0
        let low = p <= 20 && !power.charging
        let ring: Color = power.charging ? Color(red: 0.3, green: 0.85, blue: 0.45) : low ? Color(red: 1, green: 0.3, blue: 0.25) : .primary
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: 3.5)
            Circle().trim(from: 0, to: max(0.02, Double(p) / 100))
                .stroke(ring, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: p)
            VStack(spacing: -1) {
                Image(systemName: power.charging ? "bolt.fill" : low ? "battery.25" : "battery.100")
                    .font(.system(size: size * 0.15, weight: .semibold))
                    .foregroundStyle(power.charging || low ? ring : Color.primary.opacity(0.6))
                Text(power.percent.map { "\($0)%" } ?? "–")
                    .font(.system(size: size * 0.2, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(size * 0.12)
        .help(power.charging ? "Charging — \(p)%" : "Battery \(p)%")
    }
}

/// LaunchMe-style weather tile: "Day · Clear" and the temperature over a horizon with the sun (or moon) rising.
private struct WeatherDockWidget: View {
    @ObservedObject private var service = WeatherService.shared
    let size: CGFloat
    let compact: Bool

    var body: some View {
        Group {
            if let w = service.weather {
                ZStack(alignment: .bottom) {
                    // Horizon glow: warm by day, cool by night.
                    Circle()
                        .fill(RadialGradient(colors: w.isDay ? [Color(red: 1, green: 0.45, blue: 0.2), Color(red: 1, green: 0.3, blue: 0.2).opacity(0)]
                                                          : [Color(red: 0.55, green: 0.65, blue: 1), Color(red: 0.4, green: 0.5, blue: 1).opacity(0)],
                                             center: .center, startRadius: 0, endRadius: size * 0.45))
                        .frame(width: size * 0.9, height: size * 0.9)
                        .offset(y: size * 0.55)
                    Circle().fill(w.isDay ? Color(red: 1, green: 0.42, blue: 0.18) : Color(white: 0.92))
                        .frame(width: size * 0.32, height: size * 0.32)
                        .offset(y: size * 0.22)
                    HStack(alignment: .top) {
                        if !compact {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(w.isDay ? "Day" : "Night").font(.system(size: size * 0.2, weight: .semibold))
                                Text(w.summary).font(.system(size: size * 0.15)).foregroundStyle(.primary.opacity(0.65)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 2)
                        Text("\(Int(w.temperature.rounded()))°").font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, size * 0.12)
                    .padding(.top, size * 0.1)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .help("\(w.place): \(Int(w.temperature.rounded()))°, \(w.summary), H \(Int(w.high.rounded()))° L \(Int(w.low.rounded()))°")
            } else {
                Image(systemName: "cloud.sun").font(.system(size: size * 0.34)).foregroundStyle(.primary.opacity(0.6))
            }
        }
        .onAppear { service.watch() }
        .onDisappear { service.unwatch() }
    }
}

private struct TimerDockWidget: View {
    @ObservedObject private var timer = FocusTimer.shared
    let size: CGFloat

    var body: some View {
        Button {
            if timer.isActive { timer.toggle() } else { timer.start(minutes: 25) }
        } label: {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let remaining = Int(timer.remaining(at: ctx.date))
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.18), lineWidth: 3.5)
                    Circle().trim(from: 0, to: max(0.02, timer.isActive ? timer.progress(at: ctx.date) : 0))
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if timer.isActive {
                        Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                            .font(.system(size: size * 0.22, weight: .semibold, design: .rounded).monospacedDigit())
                    } else {
                        Image(systemName: "play.fill").font(.system(size: size * 0.24))
                    }
                }
                .padding(size * 0.14)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("25 minutes") { timer.start(minutes: 25) }
            Button("50 minutes") { timer.start(minutes: 50) }
            Button("5-minute break") { timer.start(minutes: 5, label: "Break") }
            if timer.isActive { Button("Reset") { timer.reset() } }
        }
    }
}

private struct StatsDockWidget: View {
    @ObservedObject private var stats = SystemStats.shared
    let size: CGFloat
    let compact: Bool

    var body: some View {
        let mem = stats.memoryTotal > 0 ? stats.memoryUsed / stats.memoryTotal : 0
        HStack(spacing: 8) {
            ring("CPU", stats.cpu)
            if !compact { ring("MEM", mem) }
        }
        .padding(4)
        .onAppear { stats.watch() }
        .onDisappear { stats.unwatch() }
    }

    private func ring(_ label: String, _ value: Double) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(Int(value * 100))").font(.system(size: size * 0.24, weight: .semibold, design: .rounded).monospacedDigit())
                Text(label).font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(.primary.opacity(0.55))
            }
        }
        .frame(width: size - 12, height: size - 12)
    }
}

private struct MeetingDockWidget: View {
    @ObservedObject private var calendar = CalendarService.shared
    let size: CGFloat
    let compact: Bool

    var body: some View {
        Group {
            if let e = calendar.next {
                if compact {
                    Image(systemName: "calendar").font(.system(size: size * 0.34))
                } else {
                    Button {
                        if let u = e.joinURL { NSWorkspace.shared.open(u) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: e.joinURL != nil ? "video.fill" : "calendar").font(.system(size: size * 0.28))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text(e.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 9.5)).foregroundStyle(.primary.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                }
            } else if !compact, let e = calendar.events.first(where: { $0.end > Date() }) {
                // No timed meeting left: show what's next anyway (an all-day item or tomorrow's first event).
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: size * 0.26))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(Calendar.current.isDateInToday(e.start) ? (e.allDay ? "Today" : e.start.formatted(date: .omitted, time: .shortened))
                             : "Tomorrow" + (e.allDay ? "" : " · " + e.start.formatted(date: .omitted, time: .shortened)))
                            .font(.system(size: 9.5)).foregroundStyle(.primary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: size * 0.28))
                    if !compact {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Day is clear").font(.system(size: 11, weight: .semibold))
                            Text("No more meetings").font(.system(size: 9.5)).foregroundStyle(.primary.opacity(0.55))
                        }
                    }
                }
            }
        }
        .onAppear { calendar.start() }
    }
}


/// Every running app that isn't pinned, gathered into one tile (like LaunchMe's Active Apps folder).
private struct RunningAppsTile: View {
    @ObservedObject var model: DockModel
    let size: CGFloat

    var body: some View {
        let icon = size * 0.36
        let apps = Array(model.runningGroup.prefix(8))
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(icon), spacing: 4), count: max(1, min(4, (apps.count + 1) / 2))), spacing: 4) {
            ForEach(apps) { item in
                Button { model.activate(item) } label: {
                    Image(nsImage: model.icon(for: item)).resizable().interpolation(.high).frame(width: icon, height: icon)
                }
                .buttonStyle(.plain)
                .help(item.name)
            }
        }
        .padding(4)
        .contextMenu {
            ForEach(model.runningGroup) { item in Button(item.name) { model.activate(item) } }
        }
    }
}
