import SwiftUI

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

// MARK: root

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    let bridge: MediaRemoteBridge

    var body: some View {
        let size = model.pillSize()
        let radius: CGFloat = model.expanded ? 26 : 11
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: radius).fill(Color.black)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.hasActivity)
    }
}

// MARK: compact (the two "wings" either side of the camera)

struct CompactView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let g = model.geometry
        HStack(spacing: 0) {
            leftWing.frame(width: IslandModel.wing)
            Color.clear.frame(width: g.hasNotch ? g.notchWidth : IslandModel.virtualNotchWidth)
            rightWing.frame(width: IslandModel.wing)
        }
        .frame(height: g.menuBarHeight)
    }

    @ViewBuilder private var leftWing: some View {
        if case .charging = model.flash {
            Image(systemName: "bolt.fill").foregroundStyle(.white)
        } else if let t = model.track {
            ArtworkView(image: t.artwork, size: 22, radius: 5)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var rightWing: some View {
        if case .charging(let percent) = model.flash {
            Text("\(percent)%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        } else if let t = model.track {
            EqualizerBars(active: t.playing)
        } else {
            Color.clear
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
                if let t = model.track {
                    NowPlayingCard(track: t, bridge: bridge)
                } else {
                    EmptyCard(model: model)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
        }
    }
}

struct EmptyCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing playing").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Music, Spotify, browsers — anything that plays audio shows up here.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let b = model.battery {
                Label("\(b)%", systemImage: model.charging ? "battery.100.bolt" : "battery.75")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

struct NowPlayingCard: View {
    let track: NowPlayingInfo
    let bridge: MediaRemoteBridge

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(image: track.artwork, size: 88, radius: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(track.artist.isEmpty ? track.appName : track.artist)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
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
