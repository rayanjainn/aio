import SwiftUI
import AppKit
import EventKit

/// First-run walkthrough: what Cortex does, the keys to know, and the optional permissions.
struct OnboardingView: View {
    @ObservedObject var prefs: Prefs
    let finish: () -> Void
    @State private var step = 0
    @State private var accessibility = WindowManager.isTrusted
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    private let tick = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: keys
                case 2: permissions
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .id(step)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(Color.white.opacity(i == step ? 0.9 : 0.25)).frame(width: i == step ? 20 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { withAnimation(.easeInOut(duration: 0.25)) { step -= 1 } }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Button(step == 3 ? "Start using Cortex" : "Continue") {
                    if step == 3 { prefs.onboardingDone = true; finish() }
                    else { withAnimation(.easeInOut(duration: 0.25)) { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 32).padding(.bottom, 26)
        }
        .frame(width: 640, height: 500)
        .background(LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.09), Color(red: 0.10, green: 0.10, blue: 0.16)], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
        .onReceive(tick) { _ in
            accessibility = WindowManager.isTrusted
            screen = CGPreflightScreenCaptureAccess()
            calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkle").font(.system(size: 54, weight: .light))
                .padding(26).cortexGlass(in: Circle())
            Text("Cortex").font(.system(size: 40, weight: .semibold, design: .rounded))
            Text("One place for launching, windows, your Dock, the notch and desktop widgets — all native, all glass.")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    private var keys: some View {
        VStack(spacing: 16) {
            Text("Three things to know").font(.system(size: 24, weight: .semibold, design: .rounded))
            VStack(spacing: 10) {
                keyRow("⌘ K", "Open the palette", "Apps, files, calculator, units, emoji, clipboard, AI and more")
                keyRow("⌥ ⇥", "Switch windows", "Every window of every app, with previews")
                keyRow("⌃ ⌥ ←→", "Snap windows", "Halves, thirds, corners — change them in Settings")
                keyRow("Notch", "Hover the top of the screen", "Music, calendar, timer, files — swipe to change page")
            }
            .frame(maxWidth: 470)
        }
    }

    private func keyRow(_ key: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Text(key).font(.system(size: 13, weight: .semibold, design: .rounded)).frame(width: 84).padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var permissions: some View {
        VStack(spacing: 14) {
            Text("Optional permissions").font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Cortex works without them; each one unlocks a feature.").font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                PermissionRow(title: "Accessibility", detail: "Window snapping, volume keys in the notch, pasting from the clipboard, menu search.",
                              granted: accessibility, button: "Grant…") { WindowManager.requestAccess() }
                PermissionRow(title: "Screen Recording", detail: "Live window previews in the Dock and the window switcher.",
                              granted: screen, button: "Grant…") { _ = CGRequestScreenCaptureAccess() }
                PermissionRow(title: "Calendar", detail: "Your next meeting in the notch, with a Join button.",
                              granted: calendar, button: "Allow…") { CalendarService.shared.requestAccess() }
            }
            .padding(16)
            .frame(maxWidth: 500)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var ready: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 52, weight: .light))
            Text("You're set").font(.system(size: 30, weight: .semibold, design: .rounded))
            Toggle("Hide the macOS Dock while Cortex runs", isOn: Binding(get: { SystemDock.hiddenByUs }, set: { SystemDock.setHidden($0) }))
                .toggleStyle(.switch).frame(maxWidth: 340)
            Text("Press ⌘K any time. Everything is in Settings (⌘, from the ✦ menu).")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class OnboardingController {
    private var window: NSWindow?

    func show() {
        let host = NSHostingView(rootView: OnboardingView(prefs: .shared, finish: { [weak self] in self?.close() }))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() { window?.close(); window = nil }
}
