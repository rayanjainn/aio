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
        HStack(spacing: 0) {
            left.frame(width: wing)
            Color.clear.frame(width: g.hasNotch ? g.notchWidth : IslandModel.virtualNotchWidth)
            right.frame(width: wing)
        }
        .frame(height: g.menuBarHeight)
    }

    @ViewBuilder private var left: some View {
        switch model.activity {
        case .hud(let e):
            Image(systemName: Self.hudSymbol(e)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
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
            if let t = model.track { ArtworkView(image: t.artwork, size: 22, radius: 5) }
        case .privacy:
            Image(systemName: model.cameraInUse ? "video.fill" : "mic.fill").font(.system(size: 12)).foregroundStyle(.white)
        case .idle:
            Color.clear
        }
    }

    @ViewBuilder private var right: some View {
        switch model.activity {
        case .hud(let e):
            HStack(spacing: 8) {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: 52, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.white).frame(width: 52 * CGFloat(e.muted ? 0 : e.level), height: 5)
                    }
            }
            .animation(.easeOut(duration: 0.12), value: e.level)
        case .flash(let f):
            switch f {
            case .charging(let p): Text("\(p)%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
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

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.geometry.menuBarHeight)   // the hardware notch
            Group {
                switch model.page {
                case .player: PlayerPage(model: model, bridge: bridge)
                case .calendar: CalendarPage(model: model)
                case .shelf: ShelfPage()
                case .tools: ToolsPage(model: model)
                }
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            .id(model.page)
            .transition(.opacity)

            HStack(spacing: 4) {
                ForEach(IslandPage.allCases) { p in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { model.page = p } } label: {
                        Image(systemName: p.symbol).font(.system(size: 12, weight: .medium))
                            .frame(width: 34, height: 24)
                            .background(model.page == p ? Color.white.opacity(0.18) : Color.clear, in: Capsule())
                            .foregroundStyle(model.page == p ? Color.white : Color.white.opacity(0.5))
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
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(image: track.artwork, size: 112, radius: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(track.artist.isEmpty ? track.appName : track.artist)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                if let lyric {
                    Text(lyric).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        .transition(.opacity).id(lyric)
                }
                Spacer(minLength: 2)
                ProgressRow(track: track, bridge: bridge)
                HStack(spacing: 28) {
                    control("backward.fill", .previous, size: 16)
                    control(track.playing ? "pause.fill" : "play.fill", .toggle, size: 22)
                    control("forward.fill", .next, size: 16)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    private func control(_ symbol: String, _ command: MRCommand, size: CGFloat) -> some View {
        Button { bridge.send(command) } label: {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 34, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            } else if calendar.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
                    Text("Nothing coming up").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ForEach(calendar.events.prefix(3)) { e in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text(e.allDay ? "All day" : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
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
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear { CalendarService.shared.refresh() }
    }
}

struct ShelfPage: View {
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundStyle(.white.opacity(0.5))
                Text("Drop files here").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Park them on the Island, then drag them out or AirDrop them.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var shortcuts: [String] = []
    @State private var mirror = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Focus timer
            VStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    ZStack {
                        RingView(progress: timer.progress(at: ctx.date), size: 74)
                        Text(clock(timer.remaining(at: ctx.date))).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                }
                HStack(spacing: 6) {
                    chip("25") { timer.start(minutes: 25) }
                    chip("50") { timer.start(minutes: 50) }
                    chip("5") { timer.start(minutes: 5, label: "Break") }
                }
                HStack(spacing: 14) {
                    Button { timer.toggle() } label: { Image(systemName: timer.isRunning ? "pause.fill" : "play.fill") }
                    Button { timer.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 150)

            // Mirror
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07))
                    if mirror { CameraPreview().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                    else { Image(systemName: "person.crop.square").font(.system(size: 28)).foregroundStyle(.white.opacity(0.4)) }
                }
                .frame(width: 150, height: 112)
                Button(mirror ? "Turn mirror off" : "Mirror") { mirror.toggle() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            }

            // Shortcuts
            VStack(alignment: .leading, spacing: 5) {
                Text("Shortcuts").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                if shortcuts.isEmpty {
                    Text("None found").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(shortcuts.prefix(30), id: \.self) { name in
                                Button { ShortcutsService.run(name) } label: {
                                    Text(name).font(.system(size: 11.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .task { shortcuts = await ShortcutsService.list() }
        .onDisappear { mirror = false }
    }

    private func chip(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 3)
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
