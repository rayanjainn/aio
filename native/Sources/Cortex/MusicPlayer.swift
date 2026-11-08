import AppKit
import SwiftUI

extension Notification.Name {
    static let openMusicPlayer = Notification.Name("cortex.music.open")
}

/// A full-screen music player: blurred artwork fills the screen, the record spins in the middle.
@MainActor
final class MusicPlayerController {
    private var panel: LauncherPanel?
    weak var bridge: MediaRemoteBridge?

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
            p.contentView = NSHostingView(rootView: MusicPlayerView(bridge: bridge, onClose: { [weak self] in self?.hide() }))
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.hide() }
            }
            panel = p
            return p
        }()
        p.setFrame(screen.frame, display: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.22; p.animator().alphaValue = 1 }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.16; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }
}

struct MusicPlayerView: View {
    @ObservedObject var bridge: MediaRemoteBridge
    @ObservedObject private var prefs = Prefs.shared
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let art = bridge.info?.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 80).opacity(0.75).scaleEffect(1.2)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .id(bridge.info?.title)
            }
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 34) {
                Spacer(minLength: 0)
                centerpiece
                info
                Spacer(minLength: 0)
                styles
            }
            .padding(.vertical, 50)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                            .cortexGlass(in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(30)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onExitCommand { onClose() }
        .animation(.easeInOut(duration: 0.5), value: bridge.info?.title)
    }

    @ViewBuilder private var centerpiece: some View {
        let playing = bridge.info?.playing ?? false
        switch prefs.musicPlayerStyle {
        case "cover":
            ArtworkView(image: bridge.info?.artwork, size: 380, radius: 28)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                .scaleEffect(playing ? 1 : 0.9)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: playing)
        case "waves":
            ZStack {
                WavesView(active: playing).frame(width: 520, height: 380)
                ArtworkView(image: bridge.info?.artwork, size: 220, radius: 110)
                    .shadow(color: .black.opacity(0.5), radius: 30)
            }
        default:
            VinylView(artwork: bridge.info?.artwork, playing: playing).frame(width: 400, height: 400)
        }
    }

    private var info: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(bridge.info?.title ?? "Nothing playing").font(.system(size: 30, weight: .bold)).lineLimit(1)
                Text(bridge.info?.artist ?? "Play something in Music, Spotify or a browser")
                    .font(.system(size: 17)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            if let t = bridge.info {
                ProgressRow(track: t, bridge: bridge).frame(width: 460)
            }
            HStack(spacing: 46) {
                Button { bridge.send(.previous) } label: { Image(systemName: "backward.fill").font(.system(size: 26)) }
                Button { bridge.send(.toggle) } label: {
                    Image(systemName: bridge.info?.playing == true ? "pause.fill" : "play.fill").font(.system(size: 40))
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { bridge.send(.next) } label: { Image(systemName: "forward.fill").font(.system(size: 26)) }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 600)
    }

    private var styles: some View {
        HStack(spacing: 6) {
            ForEach([("vinyl", "record.circle"), ("cover", "square.fill"), ("waves", "waveform")], id: \.0) { id, symbol in
                Button { withAnimation(.spring(response: 0.4)) { prefs.musicPlayerStyle = id } } label: {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 40, height: 28)
                        .background(Capsule().fill(Color.white.opacity(prefs.musicPlayerStyle == id ? 0.22 : 0.0)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .cortexGlass(in: Capsule(), darken: 0.2)
    }
}

/// A spinning record with the album art as its label.
struct VinylView: View {
    let artwork: NSImage?
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
            let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                ZStack {
                    Circle().fill(Color(white: 0.06))
                    ForEach(0..<14, id: \.self) { i in
                        Circle().stroke(Color.white.opacity(i % 3 == 0 ? 0.07 : 0.035), lineWidth: 0.8)
                            .frame(width: d * (0.42 + CGFloat(i) * 0.04), height: d * (0.42 + CGFloat(i) * 0.04))
                    }
                    // light sheen
                    Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.06), .clear], center: .center))
                    ArtworkView(image: artwork, size: d * 0.36, radius: d * 0.18)
                    Circle().fill(Color.black).frame(width: d * 0.035, height: d * 0.035)
                }
                .frame(width: d, height: d)
                .rotationEffect(.degrees(playing ? angle : 0))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
            }
        }
    }
}

/// Soft animated waves around the artwork, moving only while music plays.
struct WavesView: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            Canvas { context, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                for layer in 0..<5 {
                    var path = Path()
                    let amp = 18.0 + Double(layer) * 7
                    let freq = 1.4 + Double(layer) * 0.35
                    let phase = t * (0.8 + Double(layer) * 0.25)
                    let mid = size.height / 2
                    path.move(to: CGPoint(x: 0, y: mid))
                    for x in stride(from: 0.0, through: Double(size.width), by: 4) {
                        let y = mid + CGFloat(sin(x / Double(size.width) * .pi * 2 * freq + phase) * amp)
                        path.addLine(to: CGPoint(x: x, y: Double(y)))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.10 + Double(layer) * 0.05)), lineWidth: 1.5)
                }
            }
        }
    }
}
