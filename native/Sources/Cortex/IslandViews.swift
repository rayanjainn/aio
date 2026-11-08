import SwiftUI
import AVFoundation

/// Flush with the top edge, rounded at the bottom — reads as an extension of the notch.
struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

func clock(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct EqualizerBars: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = abs(sin(t * (2.2 + Double(i) * 0.7) + Double(i)))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 3, height: active ? CGFloat(5 + 10 * wave) : 4)
                }
            }
            .frame(height: 16)
        }
    }
}

/// A thin progress ring (focus timer).
struct RingView: View {
    let progress: Double
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: root

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    let bridge: MediaRemoteBridge
    var onSwipe: ((Int) -> Void)? = nil

    var body: some View {
        let size = model.pillSize()
        let radius: CGFloat = model.expanded ? 28 : 11
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: radius).fill(Color.black)
            if model.expanded, model.page == .player, let art = model.track?.artwork {
                ArtworkBackdrop(image: art, strength: 0.5)
                    .frame(width: size.width, height: size.height)
                    .clipShape(NotchShape(bottomRadius: radius))
            }
            if model.expanded {
                ExpandedView(model: model, bridge: bridge).transition(.opacity)
            } else if model.hasActivity {
                CompactView(model: model).transition(.opacity)
            } else if !model.geometry.hasNotch {
                // Idle virtual notch: a faint dot says "hover me".
                Circle().fill(Color.white.opacity(0.28)).frame(width: 4, height: 4)
                    .frame(height: model.geometry.menuBarHeight)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(bottomRadius: radius))
        .overlay(alignment: .top) {
            if model.expanded {
                NotchShape(bottomRadius: radius)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.16)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if model.dragTargeted {
                NotchShape(bottomRadius: radius).stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [.fileURL], isTargeted: $model.dragTargeted) { providers in
            ShelfStore.shared.handleDrop(providers)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.hasActivity)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.wingWidth)
    }
}

// MARK: compact (the two "wings" either side of the camera)

struct CompactView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        let g = model.geometry
        let wing = model.wingWidth
        // Content hugs the outer edges with the same inset on both sides, so the pill reads balanced.
        HStack(spacing: 0) {
            left.padding(.leading, IslandModel.wingInset).frame(width: wing, alignment: .leading)
            Color.clear.frame(width: g.hasNotch ? g.notchWidth : IslandModel.virtualNotchWidth)
            right.padding(.trailing, IslandModel.wingInset).frame(width: wing, alignment: .trailing)
        }
        .frame(height: g.menuBarHeight)
    }

    @ViewBuilder private var left: some View {
        switch model.activity {
        case .hud(let e):
            Image(systemName: Self.hudSymbol(e)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .flash(let f):
            switch f {
            case .charging: Image(systemName: "bolt.fill").foregroundStyle(.white).symbolEffect(.pulse, options: .repeating)
            case .bluetooth: Image(systemName: "airpods").foregroundStyle(.white)
            case .message(let symbol, _): Image(systemName: symbol).foregroundStyle(.white)
            }
        case .meeting(let m):
            HStack(spacing: 6) {
                Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(.white)
                Text(m.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }.padding(.horizontal, 8)
        case .timer:
            RingView(progress: timer.progress(), size: 16)
        case .download:
            Image(systemName: "arrow.down.circle").font(.system(size: 14)).foregroundStyle(.white).symbolEffect(.pulse, options: .repeating)
        case .music:
            if let t = model.track {
                // Playing: full size and bright. Paused: a little smaller and dimmer, like a resting record.
                ArtworkView(image: t.artwork, size: 22, radius: 5)
                    .scaleEffect(t.playing ? 1 : 0.86)
                    .opacity(t.playing ? 1 : 0.6)
                    .shadow(color: .white.opacity(t.playing ? 0.18 : 0), radius: 4)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: t.playing)
            }
        case .privacy:
            Image(systemName: model.cameraInUse ? "video.fill" : "mic.fill").font(.system(size: 12)).foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
        case .idle:
            Color.clear
        }
    }

    @ViewBuilder private var right: some View {
        switch model.activity {
        case .hud(let e):
            HStack(spacing: 8) {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 52, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.white).frame(width: max(6, 52 * CGFloat(e.muted ? 0 : e.level)), height: 6)
                            .opacity(e.muted ? 0.3 : 1)
                            .shadow(color: .white.opacity(0.55), radius: 3)
                    }
            }
            .animation(.easeOut(duration: 0.12), value: e.level)
        case .flash(let f):
            switch f {
            case .charging(let p):
                HStack(spacing: 5) {
                    Text("\(p)%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    Capsule().fill(Color.white.opacity(0.2)).frame(width: 22, height: 8)
                        .overlay(alignment: .leading) { Capsule().fill(Color.white).frame(width: max(3, 22 * CGFloat(p) / 100), height: 8) }
                }
                .foregroundStyle(.white)
            case .bluetooth(let name, let battery):
                Text(battery ?? name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8)
            case .message(_, let text): Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8)
            }
        case .meeting(let m):
            TimelineView(.periodic(from: .now, by: 20)) { ctx in
                let mins = Int((m.start.timeIntervalSince(ctx.date) / 60).rounded(.up))
                Text(mins <= 0 ? "now" : "in \(mins)m").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
            }
        case .timer:
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(clock(timer.remaining(at: ctx.date))).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            }
        case .download(let names):
            Text(names.count > 1 ? "\(names.count) files" : (names.first ?? "")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8)
        case .music:
            HStack(spacing: 6) {
                if model.micInUse { Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(.white) }
                if model.cameraInUse { Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(.white) }
                EqualizerBars(active: model.track?.playing ?? false)
            }
        case .privacy:
            HStack(spacing: 6) {
                if model.micInUse { Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(.white) }
                if model.cameraInUse { Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(.white) }
            }
        case .idle:
            Color.clear
        }
    }

    static func hudSymbol(_ e: HUDEvent) -> String {
        switch e.kind {
        case .brightness: return e.level > 0.5 ? "sun.max.fill" : "sun.min.fill"
        case .volume:
            if e.muted || e.level == 0 { return "speaker.slash.fill" }
            return e.level < 0.34 ? "speaker.wave.1.fill" : (e.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }
}

// MARK: expanded

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    let bridge: MediaRemoteBridge
    @Namespace private var tabNS

    @ViewBuilder private var page: some View {
        switch model.page {
        case .home: HomePage(model: model, bridge: bridge)
        case .player: PlayerPage(model: model, bridge: bridge)
        case .calendar: CalendarPage(model: model)
        case .shelf: ShelfPage()
        case .clipboard: ClipboardPage()
        case .rewind: RewindPage()
        case .tools: ToolsPage(model: model)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.topBand)   // the hardware notch (a thin margin on Macs without one)
            page
                .padding(.horizontal, 22)
                .frame(maxHeight: .infinity)
                .id(model.page)
                .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.97)))

            HStack(spacing: 4) {
                ForEach(IslandPage.allCases) { p in
                    Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.page = p } } label: {
                        Image(systemName: p.symbol).font(.system(size: 12, weight: .medium))
                            .symbolEffect(.bounce, value: model.page == p)
                            .frame(width: 34, height: 24)
                            .background {
                                if model.page == p {
                                    Capsule().fill(Color.white.opacity(0.18))
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6))
                                        .matchedGeometryEffect(id: "tab", in: tabNS)
                                }
                            }
                            .foregroundStyle(model.page == p ? Color.white : Color.white.opacity(0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(p.title)
                }
            }
            .padding(.bottom, 10).padding(.top, 4)
        }
    }
}

// MARK: pages

struct PlayerPage: View {
    @ObservedObject var model: IslandModel
    let bridge: MediaRemoteBridge

    var body: some View {
        if let t = model.track {
            NowPlayingCard(track: t, lyric: model.lyric, bridge: bridge)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
                Text("Nothing playing").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Music, Spotify, browsers — anything that plays audio shows up here.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                if let b = model.battery {
                    Label("\(b)%", systemImage: model.charging ? "battery.100.bolt" : "battery.75")
                        .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct NowPlayingCard: View {
    let track: NowPlayingInfo
    let lyric: String?
    let bridge: MediaRemoteBridge

    var body: some View {
        // The artwork fills the page height so the text column's bottom (progress + controls) lines up with it.
        GeometryReader { geo in
            let side = max(72, min(geo.size.height - 16, 150))
            HStack(alignment: .center, spacing: 16) {
                ArtworkView(image: track.artwork, size: side, radius: side * 0.16)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .scaleEffect(track.playing ? 1 : 0.94)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: track.playing)
                    .onTapGesture(count: 2) { NotificationCenter.default.post(name: .openMusicPlayer, object: nil) }
                    .help("Double-click for the full-screen player")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Text(track.artist.isEmpty ? track.appName : track.artist)
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button { NotificationCenter.default.post(name: .openMusicPlayer, object: nil) } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                                .background(Circle().fill(.white.opacity(0.1))).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.8))
                        .help("Full-screen player with lyrics")
                    }
                    if let lyric {
                        Text(lyric).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                            .id(lyric)
                    }
                    Spacer(minLength: 4)
                    ProgressRow(track: track, bridge: bridge)
                    HStack(spacing: 28) {
                        control("backward.fill", .previous, size: 16)
                        control(track.playing ? "pause.fill" : "play.fill", .toggle, size: 22)
                        control("forward.fill", .next, size: 16)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.3), value: lyric)
        }
        .padding(.vertical, 4)
    }

    private func control(_ symbol: String, _ command: MRCommand, size: CGFloat) -> some View {
        Button { bridge.send(command) } label: {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 34, height: 28).contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressDipStyle())
        .foregroundStyle(.white)
    }
}

struct ProgressRow: View {
    let track: NowPlayingInfo
    let bridge: MediaRemoteBridge

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let pos = track.position(at: context.date)
            let fraction: Double = track.duration > 0 ? pos / track.duration : 0
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white.opacity(0.9)).frame(width: max(4, geo.size.width * CGFloat(fraction)))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard track.duration > 0, geo.size.width > 0 else { return }
                        bridge.seek(to: Double(value.location.x / geo.size.width) * track.duration)
                    })
                }
                .frame(height: 4)
                HStack {
                    Text(clock(pos))
                    Spacer()
                    Text("-" + clock(max(0, track.duration - pos)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

struct CalendarPage: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        Group {
            if !calendar.authorized {
                VStack(spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
                    Text(calendar.denied ? "Calendar access is off" : "See your next meeting here")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    if calendar.denied {
                        Button("Open Privacy settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    } else {
                        Button("Allow calendar access") { calendar.requestAccess() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 14) {
                    dateTile
                    if events.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing coming up").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            Text("Your day is clear.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 6) {
                            // Rows share the page height, so their top and bottom line up with the date tile.
                            ForEach(events.prefix(3)) { e in row(e) }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear { CalendarService.shared.refresh() }
    }

    /// Holiday calendars often list the same day twice ("Diwali/Deepavali", "Diwali (Deepawali)"): keep one.
    private var events: [MeetingEvent] {
        var seen = Set<String>()
        return calendar.events.filter { e in
            guard e.allDay else { return true }
            let first = e.title.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? e.title
            let key = "\(Calendar.current.startOfDay(for: e.start).timeIntervalSince1970)|\(first)"
            return seen.insert(key).inserted
        }
    }

    private var dateTile: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 0) {
                Text(ctx.date.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
                Text(ctx.date.formatted(.dateTime.day()))
                    .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                Text(ctx.date.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 104)
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.open(url) }
            }
            .help("Open Calendar")
        }
    }

    private func when(_ e: MeetingEvent) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(e.start) ? "" : cal.isDateInTomorrow(e.start) ? "Tomorrow · " : e.start.formatted(.dateTime.weekday(.abbreviated)) + " · "
        if e.allDay { return day + "All day" }
        return day + "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"
    }

    private func row(_ e: MeetingEvent) -> some View {
        let now = Date()
        let live = !e.allDay && e.start <= now && e.end > now
        return HStack(spacing: 10) {
            Capsule().fill(.white.opacity(live ? 1 : 0.35)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(live ? "Now · until \(e.end.formatted(date: .omitted, time: .shortened))" : when(e))
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if let join = e.joinURL {
                Button { NSWorkspace.shared.open(join) } label: {
                    Label("Join", systemImage: "video.fill").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white, in: Capsule()).foregroundStyle(.black)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(live ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct ShelfPage: View {
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.6))
                Text("Drop files here").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Park them on the Island, then drag them out or AirDrop them.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
            .padding(.vertical, 10)
        } else {
            VStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(shelf.items) { item in
                            VStack(spacing: 4) {
                                Image(nsImage: IconCache.icon(forPath: item.path)).resizable().frame(width: 52, height: 52)
                                Text(item.name).font(.system(size: 10)).lineLimit(1).frame(width: 74)
                            }
                            .frame(width: 80)
                            .overlay(alignment: .topTrailing) {
                                Button { shelf.remove(item) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                                }.buttonStyle(.plain)
                            }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(item.url) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Button("AirDrop…") { shelf.airDrop([item.url]) }
                                Button("Remove from shelf") { shelf.remove(item) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                HStack {
                    Button { shelf.airDrop(shelf.items.map(\.url)) } label: { Label("AirDrop all", systemImage: "airplayaudio") }
                    Spacer()
                    Button("Clear") { shelf.clear() }
                }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.vertical, 8)
        }
    }
}

struct ToolsPage: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var timer = FocusTimer.shared
    @State private var mirror = false
    @ObservedObject private var prefs = Prefs.shared

    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Focus timer
            card {
                VStack(spacing: 7) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        ZStack {
                            RingView(progress: timer.progress(at: ctx.date), size: 62)
                            Text(clock(timer.remaining(at: ctx.date))).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        }
                    }
                    HStack(spacing: 4) {
                        chip("25") { timer.start(minutes: 25) }
                        chip("50") { timer.start(minutes: 50) }
                        chip("5") { timer.start(minutes: 5, label: "Break") }
                    }
                    HStack(spacing: 18) {
                        Button { timer.toggle() } label: { Image(systemName: timer.isRunning ? "pause.fill" : "play.fill").frame(width: 20, height: 18) }
                        Button { timer.reset() } label: { Image(systemName: "arrow.counterclockwise").frame(width: 20, height: 18) }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 158)

            // Mirror
            card {
                ZStack {
                    if mirror { CameraPreview().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                    else {
                        VStack(spacing: 6) {
                            Image(systemName: "person.crop.square").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.6))
                            Text("Mirror").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                            Text("Check yourself before a call").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { mirror.toggle() } }
                .help(mirror ? "Turn the camera off" : "Turn the camera on")
            }
            .frame(width: 128)

            // Quick toggles + apps
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    toggle("cup.and.saucer.fill", "Awake", on: awake.on) { awake.toggle() }
                    toggle("circle.lefthalf.filled", "Dark", on: false) {
                        SystemCommands.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
                    }
                    toggle("camera.viewfinder", "Capture", on: false) {
                        withAnimation { model.expanded = false }
                        DispatchQueue.global().async { _ = SystemCommands.shell("/usr/sbin/screencapture", ["-i", "-c"]) }
                    }
                    toggle("eyedropper", "Color", on: false) { withAnimation { model.expanded = false }; ColorPicker.pick() }
                }
                if prefs.islandApps.isEmpty {
                    Text("Add apps for one-tap launching in Settings → Island.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(prefs.islandApps, id: \.self) { bundle in
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                                Button { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in } } label: {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 34, height: 34)
                                }
                                .buttonStyle(PressDipStyle())
                                .help(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .onDisappear { mirror = false }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func toggle(_ symbol: String, _ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(on ? Color.white : Color.white.opacity(0.12)))
                    .foregroundStyle(on ? Color.black : Color.white)
                Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 46)
        }
        .buttonStyle(PressDipStyle())
        .help(title)
    }

    private func chip(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize().padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.white.opacity(0.14), in: Capsule())
        }.buttonStyle(.plain)
    }
}

/// Live camera preview, mirrored like a bathroom mirror.
struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraView { CameraView() }
    func updateNSView(_ view: CameraView, context: Context) {}
    static func dismantleNSView(_ view: CameraView, coordinator: ()) { view.stop() }
}

final class CameraView: NSView {
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async { self.start() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func start() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async {
            self.preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        }
    }

    func stop() { if session.isRunning { session.stopRunning() } }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }
}


// MARK: Home — widget cards side by side (music, date, weather, timer)

struct HomePage: View {
    @ObservedObject var model: IslandModel
    let bridge: MediaRemoteBridge
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        HStack(spacing: 10) {
            HomeMusicCard(model: model, bridge: bridge)
                .frame(maxWidth: .infinity)
            if timer.isActive {
                HomeTimerCard(timer: timer).frame(width: 112)
            } else {
                HomeDateCard().frame(width: 100)
            }
            HomeWeatherCard(weather: weather).frame(width: 128)
        }
        .padding(.vertical, 8)
        .onAppear { weather.watch() }
        .onDisappear { weather.unwatch() }
    }
}

private struct HomeCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
    }
}

/// The song over its own artwork, like LaunchMe's notch player.
struct HomeMusicCard: View {
    @ObservedObject var model: IslandModel
    let bridge: MediaRemoteBridge

    var body: some View {
        HomeCard {
            if let t = model.track {
                ZStack(alignment: .bottomLeading) {
                    if let art = t.artwork {
                        Color.clear.overlay { Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill) }
                            .clipped()
                    }
                    LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer(minLength: 0)
                        Text(t.title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        Text(t.artist).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let f = t.duration > 0 ? min(1, t.position(at: ctx.date) / t.duration) : 0
                            VStack(spacing: 2) {
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.25))
                                        Capsule().fill(.white).frame(width: max(3, g.size.width * f))
                                    }
                                }
                                .frame(height: 3)
                                HStack {
                                    Text(clock(t.position(at: ctx.date))); Spacer(); Text("-" + clock(max(0, t.duration - t.position(at: ctx.date))))
                                }
                                .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        HStack(spacing: 18) {
                            Spacer()
                            control("backward.fill", .previous, 13)
                            control(t.playing ? "pause.fill" : "play.fill", .toggle, 17)
                            control("forward.fill", .next, 13)
                            Spacer()
                        }
                    }
                    .padding(12)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { NotificationCenter.default.post(name: .openMusicPlayer, object: nil) }
                .help("Double-click for the full-screen player")
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.5))
                    Text("Nothing playing").font(.system(size: 12, weight: .semibold))
                    Text("Play something in any app").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func control(_ symbol: String, _ cmd: MRCommand, _ size: CGFloat) -> some View {
        Button { bridge.send(cmd) } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 26, height: 22).contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressDipStyle())
    }
}

/// A calendar page: weekday in red, the day huge, the month under it.
struct HomeDateCard: View {
    var body: some View {
        HomeCard {
            TimelineView(.everyMinute) { ctx in
                VStack(spacing: -4) {
                    Text(ctx.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
                    Text(ctx.date.formatted(.dateTime.day()))
                        .font(.system(size: 58, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(ctx.date.formatted(.dateTime.month(.wide)))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.open(url) }
        }
    }
}

/// Weather as a sentence in big type: "27° now in Mumbai, feels 30°, Clear".
struct HomeWeatherCard: View {
    @ObservedObject var weather: WeatherService

    var body: some View {
        HomeCard {
            if let w = weather.weather {
                VStack(alignment: .leading, spacing: 0) {
                    (Text("\(Int(w.temperature.rounded()))°").foregroundStyle(.white) + Text(" now in").foregroundStyle(.white.opacity(0.5)))
                    Text(w.place.isEmpty ? "your area" : w.place).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                    (Text("H ").foregroundStyle(.white.opacity(0.5)) + Text("\(Int(w.high.rounded()))°").foregroundStyle(.white)
                     + Text("  L ").foregroundStyle(.white.opacity(0.5)) + Text("\(Int(w.low.rounded()))°").foregroundStyle(.white))
                    HStack(spacing: 5) {
                        Image(systemName: w.symbol).symbolRenderingMode(.hierarchical)
                        Text(w.summary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(.top, 2)
                }
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cloud.sun").font(.system(size: 22, weight: .light)).symbolRenderingMode(.hierarchical)
                    Text(weather.status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                }
                .padding(8)
            }
        }
    }
}

/// The running focus timer, big and tappable.
struct HomeTimerCard: View {
    @ObservedObject var timer: FocusTimer

    var body: some View {
        HomeCard {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                VStack(spacing: 8) {
                    Text(timer.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Text(clock(timer.remaining(at: ctx.date))).font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.2))
                    HStack(spacing: 10) {
                        Button { timer.toggle() } label: {
                            Image(systemName: timer.isRunning ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                                .frame(width: 26, height: 26).background(Circle().fill(Color(red: 1, green: 0.62, blue: 0.2)))
                                .foregroundStyle(.black)
                        }
                        Button { timer.reset() } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.15)))
                        }
                    }
                    .buttonStyle(PressDipStyle())
                }
            }
        }
    }
}
