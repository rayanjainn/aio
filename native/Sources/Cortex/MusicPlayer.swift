import AppKit
import CoreAudio
import SwiftUI

extension Notification.Name {
    static let openMusicPlayer = Notification.Name("cortex.music.open")
}

// MARK: Controller

/// The full-screen music player: an animated backdrop in the artwork's colours, the record / cover / waves
/// centrepiece, time-synced lyrics, transport, volume, output picker and a sleep timer.
@MainActor
final class MusicPlayerController {
    private var panel: LauncherPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    weak var bridge: MediaRemoteBridge? { didSet { model.bridge = bridge } }
    let model = MusicPlayerModel()

    var isVisible: Bool { panel?.isVisible ?? false }
    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let bridge else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let p = panel ?? {
            let p = LauncherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.animationBehavior = .none
            p.acceptsMouseMovedEvents = true
            let host = NSHostingView(rootView: MusicPlayerView(bridge: bridge, model: model, onClose: { [weak self] in self?.hide() }))
            host.sizingOptions = []
            p.contentView = host
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    // Menus (output, sleep timer) and alerts don't count as leaving.
                    guard NSApp.modalWindow == nil else { return }
                    self?.hide()
                }
            }
            panel = p
            return p
        }()
        p.setFrame(screen.frame, display: true)
        p.alphaValue = 0
        // The player is a full-screen, keyboard-driven surface: make Cortex the active app so Space, arrows,
        // L, 1/2/3 and Esc reach it (a non-activating panel gets clicks but keys go to the app in front).
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        model.visible = true
        model.start()
        LyricsService.shared.playerWants = true
        LyricsService.shared.update(bridge.info)
        installKeys()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; p.animator().alphaValue = 1 }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        LyricsService.shared.playerWants = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.unhide()
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.model.visible = false
        })
        // Hand focus back to where the user was, unless they already moved on to another app.
        if NSApp.isActive, let prev = previousApp, !prev.isTerminated { prev.activate() }
        previousApp = nil
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let p = self.panel, p.isKeyWindow else { return false }
                return self.handle(keyCode: event.keyCode, chars: event.charactersIgnoringModifiers ?? "",
                                   command: event.modifierFlags.contains(.command))
            }
            return handled ? nil : event
        }
    }

    /// Space play/pause · ←/→ 10 s · ⌘←/⌘→ previous/next · ↑/↓ volume · L lyrics · 1–5 style · M mute · Esc close.
    private func handle(keyCode: UInt16, chars: String, command: Bool) -> Bool {
        guard let bridge else { return false }
        model.poke()
        switch keyCode {
        case 53: hide()
        case 49: bridge.send(.toggle)
        case 123: if command { bridge.send(.previous) } else { model.skip(-10) }
        case 124: if command { bridge.send(.next) } else { model.skip(10) }
        case 126: model.nudgeVolume(1.0 / 16)
        case 125: model.nudgeVolume(-1.0 / 16)
        default:
            switch chars.lowercased() {
            case "l": withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { Prefs.shared.musicPlayerLyrics.toggle() }
            case "1", "2", "3", "4", "5":
                let id = MusicStyle.all[Int(chars)! - 1].id
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { Prefs.shared.musicPlayerStyle = id }
            case "m": model.toggleMute()
            default: return false
            }
        }
        return true
    }
}

// MARK: Model

struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let symbol: String
}

/// Output devices through CoreAudio: list them and switch the default one (speakers, AirPods, AirPlay, displays).
enum AudioOutputs {
    private static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func current() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return id
    }

    static func setCurrent(_ id: AudioDeviceID) {
        var dev = id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    static func list() -> [AudioOutput] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &ssize) == noErr, ssize > 0 else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, $0) }
            let title = status == noErr ? (name?.takeRetainedValue() as String?) ?? "Output" : "Output"
            var transAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &transAddr, 0, nil, &tsize, &transport)
            return AudioOutput(id: id, name: title, symbol: symbol(transport: transport, name: title))
        }
    }

    static func symbol(transport: UInt32, name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up"
        default: return n.contains("headphone") ? "headphones" : "laptopcomputer"
        }
    }
}

@MainActor
final class MusicPlayerModel: ObservableObject {
    weak var bridge: MediaRemoteBridge?
    /// False while the player is closed: the view renders nothing, so its clock-driven animations stop.
    @Published var visible = false

    @Published private(set) var lyricIndex: Int?
    @Published var volume: Double = HUDService.shared.volume() ?? 0.5
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var currentOutput: AudioDeviceID = 0
    @Published private(set) var chromeHidden = false
    @Published private(set) var sleepEndsAt: Date?
    @Published private(set) var sleepAtTrackEnd = false

    private var timer: Timer?
    private var ticks = 0
    private var hideTask: Task<Void, Never>?
    private var lastPoke = Date.distantPast
    private var mutedFrom: Double?

    func start() {
        refreshOutputs()
        volume = HUDService.shared.volume() ?? volume
        poke()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        ticks += 1
        let info = bridge?.info
        if visible, let info {
            let idx = LyricsService.index(in: LyricsService.shared.lines, at: info.position())
            if idx != lyricIndex { lyricIndex = idx }
        }
        if visible, ticks % 5 == 0, let v = HUDService.shared.volume(), abs(v - volume) > 0.005 { volume = v }
        if let end = sleepEndsAt, Date() >= end { fireSleep() }
        if sleepAtTrackEnd, let info, info.duration > 0, info.position() >= info.duration - 1.2 { fireSleep() }
        if !visible && sleepEndsAt == nil && !sleepAtTrackEnd { timer?.invalidate(); timer = nil }
    }

    func resetLyrics() { lyricIndex = nil }

    // Chrome fades after 3 s without the pointer moving, like Apple Music.
    func poke() {
        let now = Date()
        if chromeHidden { withAnimation(.easeOut(duration: 0.25)) { chromeHidden = false } }
        guard now.timeIntervalSince(lastPoke) > 0.25 else { return }
        lastPoke = now
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.visible else { return }
            withAnimation(.easeInOut(duration: 0.7)) { self.chromeHidden = true }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func skip(_ seconds: Double) {
        guard let bridge, let info = bridge.info, info.duration > 0 else { return }
        bridge.seek(to: min(max(0, info.position() + seconds), info.duration - 1))
    }

    func setVolume(_ v: Double) {
        volume = min(max(v, 0), 1)
        HUDService.shared.setVolume(volume)
        mutedFrom = nil
    }

    func nudgeVolume(_ delta: Double) { setVolume(volume + delta) }

    func toggleMute() {
        if let from = mutedFrom { setVolume(from) } else { let v = volume; setVolume(0); mutedFrom = v }
    }

    func refreshOutputs() {
        outputs = AudioOutputs.list()
        currentOutput = AudioOutputs.current()
    }

    func choose(_ output: AudioOutput) {
        AudioOutputs.setCurrent(output.id)
        currentOutput = output.id
        Haptics.tap()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.volume = HUDService.shared.volume() ?? self?.volume ?? 0.5
        }
    }

    func sleep(minutes: Int?) {
        sleepAtTrackEnd = false
        sleepEndsAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        start()
    }

    func sleepAtEndOfTrack() {
        sleepEndsAt = nil
        sleepAtTrackEnd = true
        start()
    }

    private func fireSleep() {
        sleepEndsAt = nil
        sleepAtTrackEnd = false
        if bridge?.info?.playing == true { bridge?.send(.pause) }
    }
}

// MARK: Colours

/// The artwork reduced to a 3×3 grid of colours (top-left first), tuned to sit behind white text.
enum ArtworkPalette {
    static func grid(_ image: NSImage, side: Int = 3) -> [NSColor] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let px = side * 8
        var data = [UInt8](repeating: 0, count: px * px * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
            return true
        }
        guard ok else { return [] }
        var out: [NSColor] = []
        for gy in 0..<side {
            for gx in 0..<side {
                var r = 0.0, g = 0.0, b = 0.0
                for y in gy * 8..<(gy + 1) * 8 {
                    for x in gx * 8..<(gx + 1) * 8 {
                        let i = (y * px + x) * 4
                        r += Double(data[i]); g += Double(data[i + 1]); b += Double(data[i + 2])
                    }
                }
                let n = 64.0 * 255
                out.append(tuned(NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)))
            }
        }
        return out
    }

    /// The artwork's most vivid colour, for tinting a coloured vinyl.
    static func accent(_ image: NSImage) -> NSColor? {
        let grid = grid(image)
        guard !grid.isEmpty else { return nil }
        func sat(_ c: NSColor) -> CGFloat { var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; c.getHue(&h, saturation: &s, brightness: &b, alpha: &a); return s * (0.4 + b) }
        guard let best = grid.max(by: { sat($0) < sat($1) }) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        best.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, max(0.35, s * 1.2)), brightness: min(0.75, max(0.45, b * 1.2)), alpha: 1)
    }

    /// A little more saturation, brightness kept in a band where white text stays readable.
    static func tuned(_ c: NSColor) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (c.usingColorSpace(.sRGB) ?? c).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.25), brightness: min(max(b * 0.85, 0.14), 0.62), alpha: 1)
    }
}

// MARK: View

struct MusicPlayerView: View {
    @ObservedObject var bridge: MediaRemoteBridge
    @ObservedObject var model: MusicPlayerModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var lyrics = LyricsService.shared
    @Namespace private var styleNS
    let onClose: () -> Void

    private var trackKey: String { "\(bridge.info?.title ?? "")|\(bridge.info?.artist ?? "")" }

    var body: some View {
        if model.visible { content } else { Color.clear }
    }

    private var content: some View {
        GeometryReader { geo in
            let showLyrics = prefs.musicPlayerLyrics && geo.size.width > 900
            ZStack {
                MusicBackdrop(artwork: bridge.info?.artwork, key: trackKey, playing: bridge.info?.playing ?? false)

                if prefs.musicPlayerStyle == "art" {
                    artLayout(in: geo.size, showLyrics: showLyrics)
                        .transition(.opacity)
                } else {
                HStack(spacing: geo.size.width * 0.05) {
                    nowPlaying(in: geo.size, compact: showLyrics)
                        .frame(width: showLyrics ? geo.size.width * 0.36 : min(620, geo.size.width * 0.6))
                    if showLyrics {
                        LyricsPane(bridge: bridge, model: model, lyrics: lyrics)
                            .frame(width: geo.size.width * 0.44, height: geo.size.height * 0.78)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack {
                    topBar
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .opacity(model.chromeHidden ? 0 : 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onContinuousHover { _ in model.poke() }
        .onChange(of: trackKey) { _, _ in
            model.resetLyrics()
            LyricsService.shared.update(bridge.info)
            updateTint()
        }
        .onAppear { updateTint() }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: prefs.musicPlayerLyrics)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: prefs.musicPlayerStyle)
    }

    // MARK: Now playing column

    private func nowPlaying(in size: CGSize, compact: Bool) -> some View {
        let column = compact ? size.width * 0.36 : min(620, size.width * 0.6)
        var art = min(size.height * 0.42, compact ? size.width * 0.27 : size.width * 0.34, 470)
        let wide: CGFloat = prefs.musicPlayerStyle == "sleeve" ? 1.5 : prefs.musicPlayerStyle == "waves" ? 1.35 : 1
        art = min(art, column / wide)
        return VStack(spacing: 0) {
            centerpiece(size: art)
                .frame(width: art * wide, height: art)
                .contentShape(Rectangle())
                .onTapGesture { bridge.send(.toggle); Haptics.tap() }
                .help("Click to play or pause")
                .padding(.bottom, size.height * 0.05)

            titleBlock
                .padding(.bottom, 18)

            if let t = bridge.info, t.duration > 0 {
                ScrubBar(track: t, bridge: bridge)
                    .padding(.bottom, 14)
            }

            transport
                .padding(.bottom, 22)

            HStack(spacing: 14) {
                VolumeRow(model: model)
                accessoryButtons
            }
        }
    }

    @ViewBuilder private func centerpiece(size: CGFloat) -> some View {
        let playing = bridge.info?.playing ?? false
        let art = bridge.info?.artwork
        switch prefs.musicPlayerStyle {
        case "cover":
            ArtworkView(image: art, size: size, radius: size * 0.06)
                .overlay(RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 40, y: 22)
                .scaleEffect(playing ? 1 : 0.86)
                .animation(.spring(response: 0.55, dampingFraction: 0.68), value: playing)
                .id(trackKey)
                .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
        case "waves":
            ZStack {
                WavesView(active: playing)
                ArtworkView(image: art, size: size * 0.56, radius: size * 0.28)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 30)
                    .scaleEffect(playing ? 1 : 0.9)
                    .animation(.spring(response: 0.55, dampingFraction: 0.68), value: playing)
            }
        case "sleeve":
            SleeveView(artwork: art, playing: playing, tint: tint,
                       label: [bridge.info?.title, bridge.info?.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                .id(trackKey)
                .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
        default:
            VinylView(artwork: art, playing: playing)
        }
    }

    // MARK: Full-bleed art

    /// The artwork fills the screen; one floating glass bar carries everything else (LaunchMe/Apple TV style).
    private func artLayout(in size: CGSize, showLyrics: Bool) -> some View {
        ZStack {
            if let art = bridge.info?.artwork {
                Color.clear.overlay {
                    Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                }
                .clipped()
                .id(trackKey)
                .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            HStack {
                Spacer()
                if showLyrics {
                    LyricsPane(bridge: bridge, model: model, lyrics: lyrics)
                        .frame(width: size.width * 0.4, height: size.height * 0.62)
                        .padding(.trailing, size.width * 0.04)
                        .shadow(color: .black.opacity(0.6), radius: 12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            VStack {
                Spacer()
                MusicControlBar(bridge: bridge, model: model, prefs: prefs)
                    .frame(width: min(860, size.width * 0.66))
                    .padding(.bottom, size.height * 0.06)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: trackKey)
    }

    @State private var tint: Color = Color(red: 0.55, green: 0.12, blue: 0.14)

    private func updateTint() {
        guard let art = bridge.info?.artwork, let c = ArtworkPalette.accent(art) else { return }
        withAnimation(.easeInOut(duration: 0.8)) { tint = Color(nsColor: c) }
    }

    private var titleBlock: some View {
        VStack(spacing: 5) {
            Text(bridge.info?.title ?? "Nothing playing")
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
            Text(bridge.info.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " — ") }
                 ?? "Play something in Music, Spotify or a browser")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .id(trackKey)
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    private var transport: some View {
        HStack(spacing: 40) {
            TransportButton(symbol: "backward.fill", size: 24, help: "Previous (⌘←)") { bridge.send(.previous) }
            TransportButton(symbol: bridge.info?.playing == true ? "pause.fill" : "play.fill", size: 40, help: "Play/Pause (Space)") { bridge.send(.toggle) }
            TransportButton(symbol: "forward.fill", size: 24, help: "Next (⌘→)") { bridge.send(.next) }
        }
    }

    private var accessoryButtons: some View {
        HStack(spacing: 6) {
            ChromeIcon(symbol: prefs.musicPlayerLyrics ? "quote.bubble.fill" : "quote.bubble", active: prefs.musicPlayerLyrics, help: "Lyrics (L)") {
                prefs.musicPlayerLyrics.toggle()
            }
            Menu {
                Section("Play on") {
                    ForEach(model.outputs) { o in
                        Button { model.choose(o) } label: {
                            Label(o.name, systemImage: o.id == model.currentOutput ? "checkmark" : o.symbol)
                        }
                    }
                }
            } label: {
                Image(systemName: model.outputs.first { $0.id == model.currentOutput }?.symbol ?? "airplayaudio")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Output")
            .simultaneousGesture(TapGesture().onEnded { model.refreshOutputs() })

            Menu {
                Section(sleepTitle) {
                    ForEach([10, 15, 30, 45, 60], id: \.self) { m in Button("In \(m) minutes") { model.sleep(minutes: m) } }
                    Button("At the end of this song") { model.sleepAtEndOfTrack() }
                    if model.sleepEndsAt != nil || model.sleepAtTrackEnd { Button("Turn off") { model.sleep(minutes: nil) } }
                }
                Divider()
                if let i = model.lyricIndex, LyricsService.shared.lines.indices.contains(i), !LyricsService.shared.lines[i].text.isEmpty {
                    Button("Copy this lyric") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(LyricsService.shared.lines[i].text, forType: .string)
                    }
                }
                Button("Copy song and artist") {
                    guard let t = bridge.info else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(t.title) — \(t.artist)", forType: .string)
                }
                Button("Search the web for this song") {
                    guard let t = bridge.info,
                          let q = "\(t.title) \(t.artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                          let url = URL(string: "https://www.google.com/search?q=\(q)") else { return }
                    NSWorkspace.shared.open(url)
                }
                if let app = sourceApp {
                    Button("Open \(app.localizedName ?? "player")") { app.activate() }
                }
            } label: {
                Image(systemName: model.sleepEndsAt != nil || model.sleepAtTrackEnd ? "moon.zzz.fill" : "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private var sleepTitle: String {
        if model.sleepAtTrackEnd { return "Sleep timer — end of this song" }
        if let end = model.sleepEndsAt { return "Sleep timer — pauses at \(end.formatted(date: .omitted, time: .shortened))" }
        return "Sleep timer"
    }

    private var sourceApp: NSRunningApplication? {
        guard let id = bridge.info?.bundleID, !id.isEmpty else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if let info = bridge.info, let app = sourceApp {
                Button { app.activate() } label: {
                    HStack(spacing: 8) {
                        if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                        Text("Playing from \(app.localizedName ?? info.appName)").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .cortexGlass(in: Capsule(), darken: 0.15)
                }
                .buttonStyle(.plain)
                .help("Open the app that is playing")
            }
            Spacer()
            styleSwitcher
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                    .contentShape(Circle())
                    .cortexGlass(in: Circle(), darken: 0.15)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
    }

    private var styleSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(Array(MusicStyle.all.enumerated()), id: \.element.id) { i, style in
                let id = style.id, symbol = style.symbol, help = "\(style.name) (\(i + 1))"
                let on = prefs.musicPlayerStyle == id
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { prefs.musicPlayerStyle = id }
                    Haptics.tap()
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(on ? 1 : 0.6))
                        .frame(width: 46, height: 30)
                        .background {
                            if on { Capsule().fill(.white.opacity(0.22)).matchedGeometryEffect(id: "sel", in: styleNS) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help)
            }
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 16).padding(.horizontal, 4)
            Button {
                prefs.musicPlayerLyrics.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(prefs.musicPlayerLyrics ? 1 : 0.6))
                    .frame(width: 46, height: 30)
                    .background(Capsule().fill(.white.opacity(prefs.musicPlayerLyrics ? 0.22 : 0)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Lyrics (L)")
        }
        .padding(4)
        .cortexGlass(in: Capsule(), darken: 0.15)
    }
}

// MARK: Pieces

/// The artwork's colours as a slowly moving mesh (macOS 15+), or the blurred artwork before that.
struct MusicBackdrop: View {
    let artwork: NSImage?
    let key: String
    let playing: Bool
    @State private var colors: [Color] = Array(repeating: Color(white: 0.14), count: 9)

    var body: some View {
        ZStack {
            Color.black
            if #available(macOS 15.0, *) {
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { ctx in
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(Float(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000) * 0.22)),
                                 colors: colors, smoothsColors: true)
                }
            } else if let artwork {
                Color.clear.overlay {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 90).opacity(0.8).scaleEffect(1.3)
                }
                .clipped()
            }
            // Depth: darker at the bottom where the controls sit, a soft vignette at the edges.
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.18), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 300, endRadius: 1300)
        }
        .onAppear { recolor(animated: false) }
        .onChange(of: key) { _, _ in recolor(animated: true) }
        .onChange(of: artwork != nil) { _, _ in recolor(animated: true) }
    }

    private func recolor(animated: Bool) {
        guard let artwork else { return }
        let grid = ArtworkPalette.grid(artwork)
        guard grid.count == 9 else { return }
        let next = grid.map { Color(nsColor: $0) }
        if animated { withAnimation(.easeInOut(duration: 1.4)) { colors = next } } else { colors = next }
    }

    static func points(_ t: Float) -> [SIMD2<Float>] {
        [SIMD2(0, 0), SIMD2(0.5 + 0.22 * sin(t), 0), SIMD2(1, 0),
         SIMD2(0, 0.5 + 0.2 * cos(t * 1.3)), SIMD2(0.5 + 0.24 * sin(t * 0.8 + 1), 0.5 + 0.22 * cos(t * 1.1)), SIMD2(1, 0.5 + 0.2 * sin(t * 1.2 + 2)),
         SIMD2(0, 1), SIMD2(0.5 + 0.22 * cos(t * 0.9), 1), SIMD2(1, 1)]
    }
}

/// A playhead that thickens on hover and follows the pointer while dragging (seeks on release).
struct ScrubBar: View {
    let track: NowPlayingInfo
    let bridge: MediaRemoteBridge
    @State private var hovering = false
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let dur = track.duration
            let pos = track.position(at: ctx.date)
            let f = dragFraction ?? (dur > 0 ? min(1, max(0, pos / dur)) : 0)
            let active = hovering || dragFraction != nil
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white.opacity(active ? 1 : 0.88))
                            .frame(width: max(active ? 10 : 6, geo.size.width * f))
                    }
                    .frame(height: active ? 10 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(1, max(0, v.location.x / max(1, geo.size.width))) }
                        .onEnded { v in
                            let target = min(1, max(0, v.location.x / max(1, geo.size.width)))
                            bridge.seek(to: target * dur)
                            Haptics.tap()
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                dragFraction = nil
                            }
                        })
                }
                .frame(height: 16)
                HStack {
                    Text(clock(f * dur))
                    Spacer()
                    Text("-" + clock(max(0, dur - f * dur)))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(active ? 0.8 : 0.5))
            }
        }
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { hovering = h } }
    }
}

/// A transport button that dips when pressed and shows a soft disc on hover.
struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { action(); Haptics.tap() } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 1.9, height: size * 1.9)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressDipStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(help)
    }
}

struct PressDipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ChromeIcon: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { action(); Haptics.tap() } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.8))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(active ? 0.2 : hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressDipStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// System output volume, live: drag or scroll on it.
struct VolumeRow: View {
    @ObservedObject var model: MusicPlayerModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggleMute() } label: {
                Image(systemName: model.volume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 12, weight: .semibold)).frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("Mute (M)")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(hovering ? 1 : 0.85)).frame(width: max(6, geo.size.width * model.volume))
                }
                .frame(height: hovering ? 8 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    model.setVolume(Double(v.location.x / max(1, geo.size.width)))
                })
            }
            .frame(height: 16)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.75))
        .onHover { h in withAnimation(.spring(response: 0.25)) { hovering = h } }
        .help("Volume (↑ ↓)")
    }
}

/// Time-synced lyrics that scroll with the song: the line being sung is bright, the rest fall back and
/// soften with distance. Click a line to jump there. Plain lyrics when the song has no timing.
struct LyricsPane: View {
    @ObservedObject var bridge: MediaRemoteBridge
    @ObservedObject var model: MusicPlayerModel
    @ObservedObject var lyrics: LyricsService
    @State private var hovering = false

    var body: some View {
        Group {
            switch lyrics.state {
            case .synced: synced
            case .plain: plain
            case .loading, .idle:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.regular).tint(.white)
                    Text("Finding lyrics…").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .none:
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble").font(.system(size: 34, weight: .light))
                    Text("No lyrics for this song").font(.system(size: 20, weight: .semibold))
                    Text("Lyrics come from lrclib.net, an open community database.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .onHover { hovering = $0 }
    }

    private var synced: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Color.clear.frame(height: geo.size.height * 0.3).id(-1)
                        if let first = lyrics.lines.first, first.time > 4, model.lyricIndex == nil {
                            InterludeDots(active: bridge.info?.playing ?? false).padding(.leading, 14).padding(.bottom, 8)
                        }
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                            LyricRow(text: line.text, index: i, current: model.lyricIndex, paneHovered: hovering,
                                     playing: bridge.info?.playing ?? false, track: bridge.info,
                                     start: line.time, end: i + 1 < lyrics.lines.count ? lyrics.lines[i + 1].time : line.time + 5) {
                                bridge.seek(to: line.time)
                                Haptics.tap()
                            }
                            .id(i)
                        }
                        Color.clear.frame(height: geo.size.height * 0.6)
                    }
                    .padding(.horizontal, 8)
                }
                .onAppear { proxy.scrollTo(model.lyricIndex ?? -1, anchor: UnitPoint(x: 0, y: 0.3)) }
                .onChange(of: model.lyricIndex) { _, idx in
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) { proxy.scrollTo(idx ?? -1, anchor: UnitPoint(x: 0, y: 0.3)) }
                }
                .onChange(of: lyrics.lines) { _, _ in proxy.scrollTo(-1, anchor: .top) }
            }
        }
    }

    private var plain: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Color.clear.frame(height: 60)
                Label("These lyrics aren't time-synced", systemImage: "text.alignleft")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                ForEach(Array(lyrics.plain.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 22)
        }
    }
}

struct LyricRow: View {
    let text: String
    let index: Int
    let current: Int?
    let paneHovered: Bool
    let playing: Bool
    var track: NowPlayingInfo? = nil
    var start: Double = 0
    var end: Double = 0
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        let isActive = index == current
        let distance = abs(index - (current ?? -1))
        let past = current.map { index < $0 } ?? false
        Group {
            if text.isEmpty {
                if isActive { InterludeDots(active: playing) } else { Text("♪").font(.system(size: 30, weight: .bold)) }
            } else {
                if isActive, let track {
                    KaraokeLine(text: text, track: track, start: start, end: end, playing: playing)
                } else {
                    Text(text)
                        .font(.system(size: 34, weight: .bold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.white.opacity(isActive ? 1 : past ? 0.3 : 0.42))
        .shadow(color: .white.opacity(isActive ? 0.35 : 0), radius: 14)
        .blur(radius: paneHovered || isActive || distance > 5 ? 0 : Double(distance) * 0.55)
        .scaleEffect(isActive ? 1 : 0.95, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: paneHovered)
    }
}

/// The line being sung fills with light from left to right over its duration, like karaoke.
struct KaraokeLine: View {
    let text: String
    let track: NowPlayingInfo
    let start: Double
    let end: Double
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
            let p = min(1, max(0, (track.position(at: ctx.date) - start) / max(0.3, end - start)))
            let label = Text(text).font(.system(size: 34, weight: .bold))
            label
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.45))
                .overlay(alignment: .leading) {
                    label
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white)
                        .mask(alignment: .leading) {
                            GeometryReader { g in
                                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: max(0, p - 0.04)),
                                                       .init(color: .clear, location: min(1, p + 0.04))],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: g.size.width)
                            }
                        }
                }
        }
    }
}

/// Three breathing dots for instrumental breaks.
struct InterludeDots: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin(t * 3 - Double(i) * 0.7) + 1) / 2
                    Circle().fill(.white.opacity(0.45 + 0.55 * phase))
                        .frame(width: 12, height: 12)
                        .scaleEffect(0.75 + 0.35 * phase)
                }
            }
            .frame(height: 40)
        }
    }
}

/// A spinning record with the album art as its label and a tonearm that swings on while playing.
struct VinylView: View {
    let artwork: NSImage?
    let playing: Bool

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
                    let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 360
                    record(d)
                        .rotationEffect(.degrees(playing ? angle : 0))
                }
                // Static sheen: light stays put while the record turns under it.
                Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.07), .clear], center: .center))
                    .frame(width: d, height: d)
                    .allowsHitTesting(false)
                // On the record while playing, lifted off to the side when paused.
                Tonearm(d: d)
                    .rotationEffect(.degrees(playing ? 24 : -16), anchor: UnitPoint(x: 0.5, y: 0.06))
                    .offset(x: d * 0.45, y: -d * 0.12)
                    .animation(.spring(response: 0.9, dampingFraction: 0.75), value: playing)
            }
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.55), radius: 34, y: 18)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func record(_ d: CGFloat) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.11), Color(white: 0.04)], center: .center, startRadius: 0, endRadius: d / 2))
            ForEach(0..<16, id: \.self) { i in
                Circle().stroke(Color.white.opacity(i % 3 == 0 ? 0.075 : 0.035), lineWidth: 0.8)
                    .frame(width: d * (0.40 + CGFloat(i) * 0.036), height: d * (0.40 + CGFloat(i) * 0.036))
            }
            ArtworkView(image: artwork, size: d * 0.36, radius: d * 0.18)
            Circle().fill(Color(white: 0.02)).frame(width: d * 0.035, height: d * 0.035)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
        .frame(width: d, height: d)
    }
}

struct Tonearm: View {
    let d: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: d * 0.1, height: d * 0.1)
                .overlay(Circle().fill(Color(white: 0.25)).frame(width: d * 0.035, height: d * 0.035))
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.55)], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(3, d * 0.012), height: d * 0.5)
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.35)], startPoint: .top, endPoint: .bottom))
                .frame(width: d * 0.045, height: d * 0.08)
        }
        .shadow(color: .black.opacity(0.5), radius: 6, x: 3, y: 4)
        .frame(width: d * 0.1, height: d * 0.68, alignment: .top)
    }
}

/// Soft animated waves around the artwork, moving only while music plays.
struct WavesView: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            Canvas { context, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                for layer in 0..<6 {
                    var path = Path()
                    let amp = size.height * (0.05 + Double(layer) * 0.022)
                    let freq = 1.2 + Double(layer) * 0.3
                    let phase = t * (0.7 + Double(layer) * 0.22)
                    let mid = size.height / 2
                    path.move(to: CGPoint(x: 0, y: mid))
                    for x in stride(from: 0.0, through: Double(size.width), by: 3) {
                        let edge = sin(x / Double(size.width) * .pi)        // taper at both ends
                        let y = mid + CGFloat(sin(x / Double(size.width) * .pi * 2 * freq + phase) * amp * edge)
                        path.addLine(to: CGPoint(x: x, y: Double(y)))
                    }
                    context.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.14 + Double(layer) * 0.05), .white.opacity(0)]),
                                                               startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                                   lineWidth: 1.6)
                }
            }
        }
    }
}

/// A light trackpad tick for direct manipulation.
@MainActor
enum Haptics {
    static func tap() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
}


// MARK: Styles

struct MusicStyle: Identifiable {
    let id: String
    let name: String
    let symbol: String

    static let all: [MusicStyle] = [
        MusicStyle(id: "sleeve", name: "Sleeve", symbol: "opticaldisc"),
        MusicStyle(id: "vinyl", name: "Vinyl", symbol: "record.circle"),
        MusicStyle(id: "cover", name: "Cover", symbol: "square.fill"),
        MusicStyle(id: "art", name: "Full-screen art", symbol: "photo.fill"),
        MusicStyle(id: "waves", name: "Waves", symbol: "waveform"),
    ]
}

/// The album sleeve with its record slid half out: a coloured vinyl in the artwork's hue, the title printed
/// around the label, spinning while the song plays and sliding back into the sleeve when paused.
struct SleeveView: View {
    let artwork: NSImage?
    let playing: Bool
    let tint: Color
    let label: String

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.height, geo.size.width / 1.5)
            ZStack(alignment: .leading) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
                    ColoredRecord(d: s * 0.96, tint: tint, label: label)
                        .rotationEffect(.degrees(playing ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5 * 360 : 0))
                }
                .frame(width: s * 0.96, height: s * 0.96)
                .offset(x: playing ? s * 0.52 : s * 0.16)
                .animation(.spring(response: 1.0, dampingFraction: 0.82), value: playing)
                .shadow(color: .black.opacity(0.45), radius: 18, x: 8, y: 10)

                ArtworkView(image: artwork, size: s, radius: s * 0.012)
                    .overlay(alignment: .trailing) {
                        // The sleeve's open edge: a thin shadow line where the record slides in.
                        LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .leading, endPoint: .trailing).frame(width: s * 0.03)
                    }
                    .shadow(color: .black.opacity(0.55), radius: 30, x: 6, y: 16)
            }
            .frame(width: s * 1.5, height: s, alignment: .leading)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// A translucent coloured record: tinted body, fine grooves, a black label with text around it.
struct ColoredRecord: View {
    let d: CGFloat
    let tint: Color
    let label: String

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.95), tint.opacity(0.75), Color.black.opacity(0.85)],
                                         center: .center, startRadius: d * 0.18, endRadius: d * 0.5))
            // Marbled splashes, like a splatter pressing.
            ForEach(0..<7, id: \.self) { i in
                Capsule().fill(Color.black.opacity(0.28))
                    .frame(width: d * 0.06, height: d * 0.22)
                    .offset(y: -d * 0.33)
                    .rotationEffect(.degrees(Double(i) * 51 + 12))
            }
            ForEach(0..<18, id: \.self) { i in
                Circle().stroke(Color.black.opacity(i % 4 == 0 ? 0.22 : 0.1), lineWidth: 0.7)
                    .frame(width: d * (0.42 + CGFloat(i) * 0.031), height: d * (0.42 + CGFloat(i) * 0.031))
            }
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.16), .clear, .clear, .white.opacity(0.1), .clear], center: .center))
            Circle().fill(Color(white: 0.06)).frame(width: d * 0.38, height: d * 0.38)
            CircularText(text: String((label.uppercased() + "  •  " + label.uppercased() + "  •  ").prefix(70)), radius: d * 0.15, size: d * 0.022)
                .foregroundStyle(.white.opacity(0.85))
            Circle().fill(Color(white: 0.85)).frame(width: d * 0.03, height: d * 0.03)
        }
        .frame(width: d, height: d)
    }
}

/// Text laid out around a circle (for record labels).
struct CircularText: View {
    let text: String
    let radius: CGFloat
    let size: CGFloat

    var body: some View {
        let chars = Array(text)
        let step = 360.0 / Double(max(chars.count, 1))
        ZStack {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i])).font(.system(size: size, weight: .semibold, design: .rounded))
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) * step))
            }
        }
    }
}

/// One floating glass bar with every control: transport, the song, the playhead, lyrics, volume and output.
struct MusicControlBar: View {
    @ObservedObject var bridge: MediaRemoteBridge
    @ObservedObject var model: MusicPlayerModel
    @ObservedObject var prefs: Prefs

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 2) {
                TransportButton(symbol: "backward.fill", size: 15, help: "Previous") { bridge.send(.previous) }
                TransportButton(symbol: bridge.info?.playing == true ? "pause.fill" : "play.fill", size: 20, help: "Play/Pause") { bridge.send(.toggle) }
                TransportButton(symbol: "forward.fill", size: 15, help: "Next") { bridge.send(.next) }
            }
            ArtworkView(image: bridge.info?.artwork, size: 40, radius: 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bridge.info?.title ?? "Nothing playing").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(bridge.info?.artist ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                if let t = bridge.info, t.duration > 0 { ScrubBar(track: t, bridge: bridge) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ChromeIcon(symbol: prefs.musicPlayerLyrics ? "quote.bubble.fill" : "quote.bubble", active: prefs.musicPlayerLyrics, help: "Lyrics (L)") {
                prefs.musicPlayerLyrics.toggle()
            }
            VolumeRow(model: model).frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cortexGlass(in: Capsule(), darken: 0.25)
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }
}
