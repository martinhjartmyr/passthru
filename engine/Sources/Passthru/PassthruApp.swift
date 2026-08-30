// Passthru menu-bar UI: output picker, per-engine gain and mute, routing
// toggle, and the per-app playing list with sliders.

import SwiftUI
import AppKit
import ServiceManagement

@main
struct PassthruApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var engine = Engine.shared
    @State private var loginItemError: String?

    var body: some Scene {
        MenuBarExtra("Passthru", systemImage: engine.muted ? "waveform.slash" : "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                if let error = engine.errorText {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Quit") {
                            NSApp.terminate(nil)
                        }
                    }
                } else {
                    controls
                }
            }
            .padding(14)
            .frame(width: 300)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    engine.tick()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var controls: some View {
        header

        Divider()

        playingNow

        Divider()

        VStack(alignment: .leading, spacing: 4) {
            Text("Plays to")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("Plays to", selection: Binding(
                get: { engine.selectedOutputID },
                set: { engine.selectOutput($0) }
            )) {
                ForEach(engine.availableOutputs) { option in
                    Text(verbatim: option.name).tag(option.id)
                }
            }
            .labelsHidden()
        }

        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(
                value: Binding(
                    get: { engine.gainPercent },
                    set: { engine.setGain(percent: $0) }
                ),
                in: 0...100
            ) {
                Text("Gain")
            }
            Text("\(Int(engine.gainPercent))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }

        Toggle("Mute", isOn: Binding(
            get: { engine.muted },
            set: { engine.setMuted($0) }
        ))

        Divider()

        VStack(alignment: .leading, spacing: 3) {
            Toggle("System audio through Passthru", isOn: Binding(
                get: { engine.routedToVirtual },
                set: { engine.setRouted($0) }
            ))
            Toggle("Start at login", isOn: launchAtLogin)
            Text("Previous output is restored on quit.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        if let loginItemError {
            Text(loginItemError)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }

        if let drops = engine.dropStats {
            Text(drops)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }

        Divider()

        HStack {
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
    }

    /// Real app icon when the process resolved to an .app bundle; generic
    /// symbol for unnamed helpers.
    @ViewBuilder
    private func appIcon(_ app: PlayingApp) -> some View {
        if let path = app.iconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .accessibilityLabel("App icon")
        } else {
            Image(systemName: "circle.grid.2x2")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var playingNow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playing now")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if engine.playingApps.isEmpty {
                Text("Nothing is playing through Passthru")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(engine.playingApps) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            appIcon(app)
                                .frame(width: 15, height: 15)
                            Text(app.name)
                                .font(.system(size: 11, weight: app.isHelper ? .regular : .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(Int(app.gain * 100))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(app.gain == 1.0 ? .secondary : .primary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(app.gain) * 100 },
                                set: { engine.setAppGain(app, percent: $0) }
                            ),
                            in: 0...100
                        ) {
                            // Accessibility label only; hidden so the name
                            // renders once above and the track spans full width.
                            Text("Volume for \(app.name)")
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Passthru")
                    .font(.system(size: 13, weight: .semibold))
                Text(engine.formatSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.forward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(engine.outputName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var volumeIcon: String {
        if engine.muted || engine.gainPercent == 0 { return "speaker.slash.fill" }
        if engine.gainPercent < 40 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { want in
                loginItemError = nil
                do {
                    if want {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    loginItemError = "Autostart unavailable: \(error.localizedDescription)"
                }
            }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Engine.shared.start()
        // Debug flag: route system audio through Passthru at launch (the
        // menu's "System audio through Passthru" toggle normally does
        // this; the flag exists for headless sessions and CI smoke tests).
        if CommandLine.arguments.contains("--route-through-passthru") {
            Engine.shared.setRouted(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.shutdown()
    }
}
