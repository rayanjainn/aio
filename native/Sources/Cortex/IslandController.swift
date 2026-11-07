import AppKit
import SwiftUI
import Combine

/// Never becomes key or main, so showing or clicking it never steals focus.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Borderless windows are otherwise pushed below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI island, reports the pointer entering / leaving it and horizontal swipes.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    var onSwipe: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var scrollAccumulator: CGFloat = 0

    // A click on a non-key window must act, not just "activate".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        scrollAccumulator += event.scrollingDeltaX
        if abs(scrollAccumulator) > 60 {
            onSwipe?(scrollAccumulator < 0 ? 1 : -1)
            scrollAccumulator = 0
        }
        if event.phase == .ended || event.phase == .cancelled { scrollAccumulator = 0 }
    }
}

@MainActor
final class IslandController {
    let model = IslandModel()
    private let bridge: MediaRemoteBridge
    private let power: PowerMonitor
    private var panel: IslandPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    private var hudWork: DispatchWorkItem?
    private var meetingTimer: Timer?

    init(bridge: MediaRemoteBridge, power: PowerMonitor) {
        self.bridge = bridge
        self.power = power
    }

    func show() {
        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let host = IslandHostingView(rootView: IslandRootView(model: model, bridge: bridge))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        host.onSwipe = { [weak self] dir in self?.swipe(dir) }
        panel.contentView = host
        self.panel = panel

        wireState()
        wireServices()

        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
        FullScreen.observe { [weak self] in self?.updateFullScreen() }
        Prefs.shared.$islandHideFullscreen.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFullScreen() }.store(in: &cancellables)
        Prefs.shared.$islandDisplay.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.model.geometry = NotchGeometry.detect()
            self.layout(force: true)
        }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.geometry = NotchGeometry.detect()
                Log.info("screens changed: \(self.describeGeometry())")
                self.layout(force: true)
            }
        }
        Log.info("island created: \(describeGeometry())")
        layout(force: true)
    }

    // MARK: state from services

    private func wireState() {
        bridge.$info.combineLatest(Prefs.shared.$islandMusic)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info, show in self?.model.track = show ? info : nil }
            .store(in: &cancellables)
        Prefs.shared.$islandEnabled.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout(force: true) }
            .store(in: &cancellables)
        power.$percent.receive(on: DispatchQueue.main).sink { [weak self] in self?.model.battery = $0 }.store(in: &cancellables)
        power.$charging.receive(on: DispatchQueue.main).sink { [weak self] in self?.model.charging = $0 }.store(in: &cancellables)
        power.onPlugIn = { [weak self] percent in
            DispatchQueue.main.async { if Prefs.shared.islandCharging { self?.flash(.charging(percent)) } }
        }

        NotificationCenter.default.addObserver(forName: Toast.name, object: nil, queue: .main) { [weak self] note in
            let symbol = note.userInfo?["symbol"] as? String ?? "checkmark.circle"
            let text = note.userInfo?["text"] as? String ?? ""
            DispatchQueue.main.async { self?.flash(.message(symbol, text), seconds: 3) }
        }

        // Focus timer
        FocusTimer.shared.$endsAt.receive(on: DispatchQueue.main)
            .sink { [weak self] end in self?.model.timerRunning = end != nil }.store(in: &cancellables)
        FocusTimer.shared.onFinish = { [weak self] in self?.flash(.message("checkmark.circle", "\(FocusTimer.shared.label) done"), seconds: 5) }

        // Downloads, privacy dots
        DownloadWatcher.shared.$active.receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.model.downloads = Prefs.shared.islandDownloads ? list : [] }.store(in: &cancellables)
        PrivacyIndicators.shared.$micInUse.receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.model.micInUse = v && Prefs.shared.islandPrivacy }.store(in: &cancellables)
        PrivacyIndicators.shared.$cameraInUse.receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.model.cameraInUse = v && Prefs.shared.islandPrivacy }.store(in: &cancellables)

        // Lyrics: look up for the playing track, follow the playhead.
        model.$track.combineLatest(Prefs.shared.$islandLyrics)
            .receive(on: DispatchQueue.main)
            .sink { track, on in LyricsService.shared.load(for: on ? track : nil) }
            .store(in: &cancellables)
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, self.model.expanded, self.model.page == .player, let t = self.model.track else { return }
                let line = LyricsService.shared.current(at: t.position())
                if line != self.model.lyric { self.model.lyric = line }
            }
            .store(in: &cancellables)

        // Dropping files on the notch opens the shelf.
        model.$dragTargeted.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                guard let self, on else { return }
                self.model.page = .shelf
                self.model.expanded = true
            }
            .store(in: &cancellables)
    }

    /// Starts and stops the heavier services as the user toggles them.
    private func wireServices() {
        let p = Prefs.shared
        ClipboardHistory.shared.start()
        p.$islandHUD.receive(on: DispatchQueue.main).sink { on in
            if on {
                HUDService.shared.onEvent = { [weak self] e in self?.showHUD(e) }
                HUDService.shared.startListening()
                if WindowManager.isTrusted { HUDService.shared.captureKeys() }
            } else {
                HUDService.shared.onEvent = nil
                HUDService.shared.stopListening()
                HUDService.shared.releaseKeys()
            }
        }.store(in: &cancellables)
        p.$islandDownloads.receive(on: DispatchQueue.main).sink { on in
            if on { DownloadWatcher.shared.start() } else { DownloadWatcher.shared.stop() }
        }.store(in: &cancellables)
        p.$islandPrivacy.receive(on: DispatchQueue.main).sink { on in
            if on { PrivacyIndicators.shared.start() } else { PrivacyIndicators.shared.stop() }
        }.store(in: &cancellables)
        p.$islandBluetooth.receive(on: DispatchQueue.main).sink { [weak self] on in
            if on {
                BluetoothService.shared.onConnect = { d in
                    DispatchQueue.main.async { self?.flash(.bluetooth(d.name, d.battery), seconds: 4) }
                }
                BluetoothService.shared.start()
            } else { BluetoothService.shared.stop() }
        }.store(in: &cancellables)
        p.$islandCalendar.receive(on: DispatchQueue.main).sink { [weak self] on in
            if on { CalendarService.shared.start(); self?.startMeetingWatch() }
            else { self?.meetingTimer?.invalidate(); self?.model.meeting = nil }
        }.store(in: &cancellables)
    }

    private func startMeetingWatch() {
        meetingTimer?.invalidate()
        updateMeeting()
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeeting() }
        }
    }

    private func updateMeeting() {
        let soon = CalendarService.shared.next.flatMap { e -> MeetingEvent? in
            let until = e.start.timeIntervalSinceNow
            return (until < 10 * 60 && e.end > Date()) ? e : nil
        }
        if soon != model.meeting { model.meeting = soon }
    }

    // MARK: behaviour

    private func hoverChanged(_ inside: Bool) {
        if inside && !Prefs.shared.islandHoverExpand { return }   // hotkey-only mode
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.model.expanded != inside {
                self.model.expanded = inside
                if inside { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.12 : 0.3), execute: work)
    }

    private func swipe(_ dir: Int) {
        guard model.expanded else { return }
        let all = IslandPage.allCases
        guard let i = all.firstIndex(of: model.page) else { return }
        let next = max(0, min(all.count - 1, i + dir))
        if next != i {
            withAnimation(.easeInOut(duration: 0.2)) { model.page = all[next] }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    private func flash(_ f: IslandModel.Flash, seconds: Double = 4) {
        model.flash = f
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func showHUD(_ e: HUDEvent) {
        model.hud = e
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.hud = nil }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func toggleExpanded() {
        hoverWork?.cancel()
        model.expanded.toggle()
    }

    func openPage(_ page: IslandPage) {
        model.page = page
        model.expanded = true
    }

    // MARK: window layout

    /// The window always hugs the pill (so it never blocks menu-bar clicks around the
    /// notch). It grows instantly and shrinks only once the pill's animation is done.
    private var fullScreenHidden = false

    private func updateFullScreen() {
        let now = Prefs.shared.islandHideFullscreen && FullScreen.isCovering(NSScreen.screens.first(where: { $0.frame == model.geometry.screenFrame }))
        guard now != fullScreenHidden else { return }
        fullScreenHidden = now
        if now { panel?.orderOut(nil) } else { layout(force: true) }
    }

    private func layout(force: Bool = false) {
        guard let panel else { return }
        if fullScreenHidden { return }
        guard Prefs.shared.islandEnabled else { panel.orderOut(nil); return }
        let target = model.pillSize()
        if target == .zero { panel.orderOut(nil); return }
        let current = panel.isVisible ? panel.frame.size : .zero
        let grown = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        if grown != current || force { place(grown) }
        shrinkWork?.cancel()
        if grown != target {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let t = self.model.pillSize()
                if t == .zero { self.panel?.orderOut(nil) } else { self.place(t) }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
    }

    private func place(_ size: CGSize) {
        guard let panel, size != .zero, !fullScreenHidden else { return }
        let f = model.geometry.screenFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: diagnostics

    func describeGeometry() -> String {
        let g = model.geometry
        return "notch=\(g.hasNotch) notchWidth=\(Int(g.notchWidth)) menuBar=\(Int(g.menuBarHeight)) screen=\(NSStringFromRect(g.screenFrame))"
    }

    func describePanel() -> String {
        guard let panel else { return "not created" }
        return "visible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame)) level=\(panel.level.rawValue) expanded=\(model.expanded) page=\(model.page.rawValue) pill=\(NSStringFromSize(model.pillSize())) mediaKeysCaptured=\(HUDService.shared.keysCaptured)"
    }
}
