import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            PresetsSettingsView()
                .tabItem { Label("Presets", systemImage: "rectangle.stack") }
                .tag(SettingsTab.presets)
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 560, height: 560)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var model = AppModel.shared
    @State private var launchAtLogin = SettingsStore.shared.launchAtLogin
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Keyboard shortcuts rotate") {
                Picker("Target", selection: $settings.hotkeyTarget) {
                    Text("Display under the mouse pointer").tag(HotkeyTarget.displayUnderMouse)
                    Text("Main display").tag(HotkeyTarget.mainDisplay)
                    Text("All external displays").tag(HotkeyTarget.allExternalDisplays)
                    Divider()
                    ForEach(model.displays) { display in
                        Text(display.name).tag(HotkeyTarget.specificDisplay(display.persistentID))
                    }
                    if let disconnected = disconnectedTarget {
                        Text("Disconnected display").tag(disconnected)
                    }
                }
                Text("Choose which display the rotation shortcuts act on. \"Display under the mouse pointer\" is handy when you have several external monitors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Brightness keys") {
                Toggle("Brightness keys control the display under the mouse pointer", isOn: $settings.brightnessKeysEnabled)
                if settings.brightnessKeysEnabled {
                    HStack {
                        Text("Accessibility permission")
                        Spacer()
                        if model.brightnessKeys.isActive {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Needed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if !model.brightnessKeys.isActive {
                        HStack {
                            Button("Request Permission…") {
                                model.brightnessKeys.requestPermission()
                            }
                            Button("Open Accessibility Settings") {
                                BrightnessKeyService.openAccessibilitySettings()
                            }
                        }
                    }
                }
                Text("With the pointer on an external monitor, the keyboard's brightness keys change that monitor's brightness (DDC/CI, or software dimming if the monitor doesn't support it). With the pointer on the built-in display they work as usual. Intercepting the keys requires the Accessibility permission; if it stops working after you rebuild the app, remove ScreenControl from the Accessibility list and add it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep dimming below the monitor's minimum, down to black", isOn: $settings.extendedDimming)
                Text("A monitor's own brightness setting never switches the picture off: 0 is just its dimmest backlight. With this on, the lowest 4 of the 16 brightness steps dim the picture further in software until it is black.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                Toggle("Show the built-in display in the menu", isOn: $settings.showBuiltinDisplay)
                Toggle("Allow rotating the built-in display", isOn: $settings.allowBuiltinRotation)
                Text("Rotating a MacBook's own panel is rarely useful and can be disorienting, so it is off by default. External monitors are always rotatable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch ScreenControl at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Rotation mechanism") {
                let backends = RotationService.availableBackends
                if backends.isEmpty {
                    Text("No rotation mechanism was found on this Mac.")
                        .foregroundStyle(.red)
                } else {
                    Text("Available: " + backends.map(\.rawValue).joined(separator: ", "))
                }
                Text("macOS has no public API for setting rotation, so ScreenControl uses the same private SkyLight call that System Settings does, with MonitorPanel and IOKit as fallbacks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var disconnectedTarget: HotkeyTarget? {
        guard let id = settings.hotkeyTarget.specificDisplayID,
              !model.displays.contains(where: { $0.persistentID == id }) else {
            return nil
        }
        return settings.hotkeyTarget
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    try settings.setLaunchAtLogin(enabled)
                    launchAtLogin = settings.launchAtLogin
                    launchAtLoginError = nil
                } catch {
                    launchAtLogin = settings.launchAtLogin
                    launchAtLoginError = "Couldn't update the login item: \(error.localizedDescription)"
                }
            }
        )
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            ForEach(HotkeyAction.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(HotkeyAction.actions(in: category)) { action in
                        ShortcutRecorderRow(
                            title: action.title,
                            shortcut: Binding(
                                get: { settings.shortcuts[action] },
                                set: { settings.setShortcut($0, for: action) }
                            )
                        )
                    }
                    if category == .power {
                        Text("Turns off the target display; if any display is already off, turns them all back on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if category == .input {
                        Text("Acts on the same target as the rotation shortcuts. Only monitors that answer DDC/CI can switch inputs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("Click a shortcut to record a new one, then press the keys. Shortcuts need at least one of ⌘, ⌥ or ⌃. Press ⎋ to cancel. Recording the same keys for two actions moves the shortcut to the newer one. Presets get their shortcuts in the Presets tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restore Default Shortcuts") {
                    settings.restoreDefaultShortcuts()
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One row: action title on the left, the recorded combination (or a prompt) on the right.
/// Clicking toggles recording; a local key monitor captures the next valid combination.
struct ShortcutRecorderRow: View {
    let title: String
    @Binding var shortcut: KeyboardShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                if isRecording { stopRecording() } else { startRecording() }
            } label: {
                if isRecording {
                    Text("Type shortcut…")
                        .foregroundStyle(Color.accentColor)
                        .frame(minWidth: 120)
                } else if let shortcut {
                    Text(shortcut.display)
                        .frame(minWidth: 120)
                } else {
                    Text("Record Shortcut")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 120)
                }
            }
            .buttonStyle(.bordered)

            Button {
                stopRecording()
                shortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(shortcut == nil)
            .help("Remove shortcut")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        HotkeyManager.shared.beginSuspension()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels
                stopRecording()
                return nil
            }
            if let recorded = KeyboardShortcut(event: event) {
                shortcut = recorded
                stopRecording()
            }
            // Swallow everything while recording so keys don't reach the rest of the window.
            return nil
        }
    }

    private func stopRecording() {
        guard let monitor else {
            isRecording = false
            return
        }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isRecording = false
        HotkeyManager.shared.endSuspension()
    }
}

// MARK: - Presets

struct PresetsSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var model = AppModel.shared
    @ObservedObject var navigation = SettingsNavigation.shared

    var body: some View {
        Form {
            if settings.presets.isEmpty {
                Section {
                    Text("A preset remembers rotation, resolution, refresh rate and brightness for every connected display, so you can jump between setups (say, portrait for reading and landscape for video) with one shortcut.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(settings.presets) { preset in
                PresetRow(preset: preset, autoFocus: navigation.presetToEdit == preset.id)
            }

            Section {
                Button("Save Current Setup as New Preset") {
                    let preset = model.saveCurrentSetupAsPreset()
                    navigation.presetToEdit = preset.id
                }
                Text("Displays are matched by their hardware identity, so a preset skips monitors that are not connected when it is applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Editor for one preset: name, shortcut, what it contains, and actions.
struct PresetRow: View {
    let preset: DisplayPreset
    let autoFocus: Bool

    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var model = AppModel.shared
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section {
            TextField("Name", text: nameBinding)
                .focused($nameFocused)
                .onAppear {
                    if autoFocus { nameFocused = true }
                }
            ShortcutRecorderRow(
                title: "Shortcut",
                shortcut: Binding(
                    get: { preset.shortcut },
                    set: { settings.setShortcut($0, forPreset: preset.id) }
                )
            )
            Text(preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Apply") {
                    model.applyPreset(preset)
                }
                Button("Update from Current Setup") {
                    var updated = model.captureCurrentSetup(named: preset.name)
                    updated.id = preset.id
                    updated.shortcut = preset.shortcut
                    settings.updatePreset(updated)
                }
                Spacer()
                Button("Delete", role: .destructive) {
                    settings.removePreset(preset.id)
                }
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { preset.name },
            set: { newName in
                var updated = preset
                updated.name = newName
                settings.updatePreset(updated)
            }
        )
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rotate.right")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("ScreenControl")
                .font(.title)
            Text(version)
                .foregroundStyle(.secondary)
            Text("Rotate external displays from the menu bar or with a global keyboard shortcut. Sends the keyboard's brightness keys to the monitor under the mouse, switches resolution and refresh rate, dims displays in software, and toggles mirroring.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Link("Source on GitHub", destination: URL(string: "https://github.com/boboborenstein-collab/ScreenControl")!)
            Text("Inspired by BetterDisplay; rotation and hotkey techniques informed by the open-source Crisp, FreeDisplay and displayplacer projects.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }
}
