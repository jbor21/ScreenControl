import AppKit
import SwiftUI

/// Content of the menu bar menu. Rendered by `MenuBarExtra` as a native `NSMenu`, so only
/// menu-compatible views (buttons, toggles, inline pickers, sections, dividers, text) are used.
struct MenuContentView: View {
    @ObservedObject var model = AppModel.shared
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        if model.visibleDisplays.isEmpty {
            Text("No displays found")
        } else {
            ForEach(model.visibleDisplays) { display in
                DisplayMenu(display: display)
            }
        }

        Divider()

        if let shortcut = settings.shortcuts[.rotateClockwise] {
            Text("Hotkeys act on: \(targetDescription)   (\(shortcut.display) rotates)")
        } else {
            Text("Hotkeys act on: \(targetDescription)")
        }

        Button("Refresh Displays") {
            model.refresh()
        }

        Button("Settings…") {
            SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit ScreenControl") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var targetDescription: String {
        switch settings.hotkeyTarget {
        case .displayUnderMouse:
            return "display under mouse"
        case .mainDisplay:
            return "main display"
        case .allExternalDisplays:
            return "all external displays"
        case .specificDisplay(let id):
            return model.displays.first { $0.persistentID == id }?.name ?? "a disconnected display"
        }
    }
}

/// Submenu for one display.
struct DisplayMenu: View {
    let display: DisplayInfo
    @ObservedObject var model = AppModel.shared

    private static let dimmingLevels: [Int] = [100, 90, 80, 70, 60, 50, 40, 30]
    private static let brightnessLevels: [Int] = [100, 90, 80, 70, 60, 50, 40, 30, 20, 10, 0]

    var body: some View {
        Menu {
            Text(infoLine)

            Section("Rotation") {
                Picker("Rotation", selection: rotationBinding) {
                    Text("0° — Standard").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .pickerStyle(.inline)
                .disabled(!model.canRotate(display))

                Button("Rotate +90° (clockwise)") {
                    model.rotate(display, by: 90)
                }
                .disabled(!model.canRotate(display))

                Button("Rotate −90° (counterclockwise)") {
                    model.rotate(display, by: -90)
                }
                .disabled(!model.canRotate(display))

                if display.isBuiltin && !model.settings.allowBuiltinRotation {
                    Text("Built-in display rotation is disabled in Settings")
                }
            }

            let resolutions = model.resolutionOptions(for: display)
            if !resolutions.isEmpty {
                Section("Resolution") {
                    Picker("Resolution", selection: resolutionBinding) {
                        ForEach(resolutions) { mode in
                            Text(mode.resolutionDescription).tag(mode.resolutionKey)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }

            let rates = model.refreshRateOptions(for: display)
            if rates.count > 1 {
                Section("Refresh Rate") {
                    Picker("Refresh Rate", selection: refreshRateBinding) {
                        ForEach(rates) { mode in
                            Text(mode.refreshRateDescription).tag(mode.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }

            if !display.isBuiltin, model.brightnessControl(for: display) != .system {
                Section("Brightness") {
                    Picker("Brightness", selection: brightnessBinding) {
                        ForEach(Self.brightnessLevels, id: \.self) { level in
                            Text("\(level)%").tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(model.brightnessControl(for: display).label)
                }
            }

            Section("Software Dimming") {
                Picker("Software Dimming", selection: dimmingBinding) {
                    ForEach(Self.dimmingLevels, id: \.self) { level in
                        Text(level == 100 ? "100% (off)" : "\(level)%").tag(level)
                    }
                }
                .pickerStyle(.inline)
            }

            if !display.isMain {
                Section {
                    Button(display.isMirroring ? "Stop Mirroring" : "Mirror Main Display") {
                        model.toggleMirroring(of: display)
                    }
                }
            }
        } label: {
            Text(display.menuTitle)
        }
    }

    private var infoLine: String {
        var parts = [display.resolutionDescription]
        if let mode = model.currentMode(for: display) {
            if mode.isHiDPI { parts.append("HiDPI") }
            if mode.refreshRate > 0 { parts.append(mode.refreshRateDescription) }
        }
        if display.isMain { parts.append("Main") }
        if display.isBuiltin { parts.append("Built-in") }
        if display.isMirroring { parts.append("Mirroring") }
        if model.busyDisplays.contains(display.id) { parts.append("Rotating…") }
        return parts.joined(separator: "  ·  ")
    }

    private var rotationBinding: Binding<Int> {
        Binding(
            get: { display.rotation },
            set: { model.setRotation($0, for: display) }
        )
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: { model.currentMode(for: display)?.resolutionKey ?? "" },
            set: { model.selectResolution($0, for: display) }
        )
    }

    private var refreshRateBinding: Binding<Int32> {
        Binding(
            get: { model.currentModeIDs[display.id] ?? 0 },
            set: { model.applyMode($0, for: display) }
        )
    }

    private var brightnessBinding: Binding<Int> {
        Binding(
            get: { Int((model.brightnessLevel(for: display) * 10).rounded()) * 10 },
            set: { model.setBrightness(Double($0) / 100, for: display) }
        )
    }

    private var dimmingBinding: Binding<Int> {
        Binding(
            get: { Int((model.softwareBrightness(for: display) * 100).rounded()) },
            set: { model.setSoftwareBrightness(Double($0) / 100, for: display) }
        )
    }
}
