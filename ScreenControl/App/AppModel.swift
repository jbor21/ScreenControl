import AppKit
import Combine
import CoreGraphics
import Foundation
import os

/// Observable state behind the menu and the settings window, plus the actions they trigger.
/// Everything here is meant to run on the main thread.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var modes: [CGDirectDisplayID: [DisplayModeInfo]] = [:]
    @Published private(set) var currentModeIDs: [CGDirectDisplayID: Int32] = [:]
    @Published private(set) var busyDisplays: Set<CGDirectDisplayID> = []
    @Published private(set) var lastError: String?

    let settings = SettingsStore.shared
    let brightness = BrightnessService.shared
    let brightnessKeys = BrightnessKeyService.shared
    let inputs = InputService.shared
    let power = DisplayPowerService.shared

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "app")
    private var cancellables: Set<AnyCancellable> = []
    private var hasAppliedDimming = false

    private init() {}

    // MARK: Lifecycle

    func start() {
        brightness.setExtendedDimming(settings.extendedDimming)
        brightness.applyGammaFactor = { [weak self] id, _ in
            guard let self, let display = self.displays.first(where: { $0.id == id }) else { return }
            self.applyGamma(for: display)
        }

        refresh()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.brightness.reset()
                self?.inputs.reset()
                self?.refresh()
            }
            .store(in: &cancellables)

        HotkeyManager.shared.onTrigger = { [weak self] identifier in
            switch identifier {
            case .action(let action): self?.perform(action)
            case .preset(let id): self?.applyPreset(id: id)
            }
        }
        settings.registerHotkeys()

        settings.$brightnessKeysEnabled
            .sink { [weak self] enabled in self?.applyBrightnessKeys(enabled: enabled) }
            .store(in: &cancellables)
        settings.$extendedDimming
            .dropFirst()
            .sink { [weak self] enabled in self?.brightness.setExtendedDimming(enabled) }
            .store(in: &cancellables)

        // Re-publish changes from the nested observable objects so menu and settings views update.
        brightness.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        brightnessKeys.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        inputs.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        power.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func shutdown() {
        brightnessKeys.stop()
        power.restoreAllSynchronously()
        if hasAppliedDimming {
            DisplayService.restoreGamma()
        }
    }

    private func applyBrightnessKeys(enabled: Bool) {
        guard enabled else {
            brightnessKeys.stop()
            return
        }
        brightnessKeys.start()
        if !brightnessKeys.isTrusted && !settings.hasRequestedAccessibility {
            settings.hasRequestedAccessibility = true
            brightnessKeys.requestPermission()
        }
    }

    // MARK: Displays

    func refresh() {
        let current = DisplayService.onlineDisplays()
        displays = current

        var newModes: [CGDirectDisplayID: [DisplayModeInfo]] = [:]
        var newCurrent: [CGDirectDisplayID: Int32] = [:]
        for display in current {
            newModes[display.id] = DisplayService.availableModes(for: display.id)
            newCurrent[display.id] = DisplayService.currentModeID(for: display.id)
        }
        modes = newModes
        currentModeIDs = newCurrent

        reapplySoftwareBrightness()
        brightness.probe(current)
        inputs.probe(current)
        power.reconcile(online: current)
    }

    var visibleDisplays: [DisplayInfo] {
        displays.filter { settings.showBuiltinDisplay || !$0.isBuiltin }
    }

    func canRotate(_ display: DisplayInfo) -> Bool {
        (!display.isBuiltin || settings.allowBuiltinRotation) && !busyDisplays.contains(display.id)
    }

    func displays(for target: HotkeyTarget) -> [DisplayInfo] {
        switch target {
        case .displayUnderMouse:
            if let id = DisplayService.displayIDUnderMouse(),
               let display = displays.first(where: { $0.id == id }) {
                return [display]
            }
            return displays.filter(\.isMain)
        case .mainDisplay:
            return displays.filter(\.isMain)
        case .allExternalDisplays:
            return displays.filter { !$0.isBuiltin }
        case .specificDisplay(let persistentID):
            return displays.filter { $0.persistentID == persistentID }
        }
    }

    // MARK: Hotkey actions

    func perform(_ action: HotkeyAction) {
        switch action.category {
        case .rotation:
            let targets = displays(for: settings.hotkeyTarget)
            guard !targets.isEmpty else {
                NSSound.beep()
                return
            }
            for display in targets {
                guard canRotate(display), let degrees = action.targetRotation(from: display.rotation) else {
                    NSSound.beep()
                    continue
                }
                setRotation(degrees, for: display)
            }
        case .power:
            toggleDisplayPower()
        case .input:
            guard let input = action.input else { return }
            let targets = displays(for: settings.hotkeyTarget).filter { !$0.isBuiltin }
            guard !targets.isEmpty else {
                NSSound.beep()
                return
            }
            for display in targets {
                selectInput(input, for: display)
            }
        }
    }

    // MARK: Rotation

    func rotate(_ display: DisplayInfo, by delta: Int) {
        setRotation(((display.rotation + delta) % 360 + 360) % 360, for: display)
    }

    func setRotation(_ degrees: Int, for display: DisplayInfo) {
        guard degrees != display.rotation, canRotate(display) else { return }
        busyDisplays.insert(display.id)
        Task { @MainActor in
            do {
                let backend = try await RotationService.setRotation(degrees, of: display.id)
                Self.log.notice("rotated \(display.name, privacy: .public) to \(degrees)° via \(backend.rawValue, privacy: .public)")
                self.lastError = nil
            } catch {
                Self.log.error("rotation failed: \(error.localizedDescription, privacy: .public)")
                self.lastError = error.localizedDescription
                self.presentError(title: "Couldn't rotate \(display.name)", message: error.localizedDescription)
            }
            self.busyDisplays.remove(display.id)
            self.refresh()
        }
    }

    // MARK: Resolution and refresh rate

    func currentMode(for display: DisplayInfo) -> DisplayModeInfo? {
        guard let id = currentModeIDs[display.id] else { return nil }
        return modes[display.id]?.first { $0.id == id }
    }

    /// Distinct resolutions, one entry per size / scale.
    func resolutionOptions(for display: DisplayInfo) -> [DisplayModeInfo] {
        var seen = Set<String>()
        return (modes[display.id] ?? []).filter { seen.insert($0.resolutionKey).inserted }
    }

    /// Refresh rates offered for the display's current resolution.
    func refreshRateOptions(for display: DisplayInfo) -> [DisplayModeInfo] {
        guard let current = currentMode(for: display) else { return [] }
        return (modes[display.id] ?? []).filter { $0.resolutionKey == current.resolutionKey }
    }

    /// Switches to `resolutionKey`, keeping the current refresh rate when that size offers it.
    func selectResolution(_ resolutionKey: String, for display: DisplayInfo) {
        let candidates = (modes[display.id] ?? []).filter { $0.resolutionKey == resolutionKey }
        guard !candidates.isEmpty else { return }
        let currentRate = currentMode(for: display)?.refreshRate ?? 0
        let chosen = candidates.first { abs($0.refreshRate - currentRate) < 0.5 }
            ?? candidates.max { $0.refreshRate < $1.refreshRate }
        if let chosen {
            applyMode(chosen.id, for: display)
        }
    }

    func applyMode(_ modeID: Int32, for display: DisplayInfo) {
        guard modeID != currentModeIDs[display.id] else { return }
        if !DisplayService.setMode(modeID, for: display.id) {
            presentError(title: "Couldn't change the display mode", message: "macOS rejected the requested mode for \(display.name).")
        }
        scheduleRefresh()
    }

    // MARK: Mirroring

    func toggleMirroring(of display: DisplayInfo) {
        if display.isMirroring {
            DisplayService.setMirroring(of: display.id, to: nil)
        } else if let main = displays.first(where: { $0.isMain && $0.id != display.id }) {
            DisplayService.setMirroring(of: display.id, to: main.id)
        }
        scheduleRefresh()
    }

    // MARK: Display power

    var turnedOffDisplays: [TurnedOffDisplay] { power.turnedOff }

    func isTurnedOff(_ display: DisplayInfo) -> Bool {
        power.isTurnedOff(display.persistentID)
    }

    func canTurnOff(_ display: DisplayInfo) -> Bool {
        guard !isTurnedOff(display), !busyDisplays.contains(display.id) else { return false }
        if DisplayPowerService.disconnectSupported {
            return displays.count > 1
        }
        return !display.isBuiltin && brightnessControl(for: display) == .hardware
    }

    func turnOff(_ display: DisplayInfo) {
        guard canTurnOff(display) else {
            NSSound.beep()
            return
        }
        busyDisplays.insert(display.id)
        Task { @MainActor in
            do {
                try await self.power.turnOff(display)
            } catch {
                self.presentError(title: "Couldn't turn off \(display.name)", message: error.localizedDescription)
            }
            self.busyDisplays.remove(display.id)
            self.refresh()
        }
    }

    func turnOn(_ record: TurnedOffDisplay) {
        Task { @MainActor in
            do {
                try await self.power.turnOn(record)
            } catch {
                self.presentError(title: "Couldn't turn on \(record.name)", message: error.localizedDescription)
            }
            self.refresh()
        }
    }

    func turnOnAllDisplays() {
        Task { @MainActor in
            let errors = await self.power.turnOnAll()
            if let first = errors.first {
                self.presentError(title: "Couldn't turn every display back on", message: first.localizedDescription)
            }
            self.refresh()
        }
    }

    /// Hotkey behaviour: if anything is off, bring it all back; otherwise turn off the target.
    func toggleDisplayPower() {
        if !power.turnedOff.isEmpty {
            turnOnAllDisplays()
            return
        }
        let targets = displays(for: settings.hotkeyTarget)
        guard let display = targets.first(where: canTurnOff) else {
            NSSound.beep()
            return
        }
        turnOff(display)
    }

    // MARK: Monitor input

    func supportsInputSwitching(_ display: DisplayInfo) -> Bool {
        !display.isBuiltin && !inputs.unsupported.contains(display.id) && brightnessControl(for: display) != .software
    }

    func currentInput(for display: DisplayInfo) -> DisplayInput? {
        inputs.currentInput(for: display.id)
    }

    func selectInput(_ input: DisplayInput, for display: DisplayInfo) {
        guard supportsInputSwitching(display) else {
            NSSound.beep()
            return
        }
        inputs.select(input, for: display.id) { [weak self] success in
            if !success {
                self?.presentError(title: "Couldn't switch \(display.name) to \(input.name)",
                                   message: "The monitor did not accept the DDC/CI input command. Not every monitor supports switching inputs this way, and the input code for some ports varies by brand.")
            }
        }
    }

    // MARK: Presets

    /// Snapshot of every online display as a preset with a fresh name.
    func captureCurrentSetup(named name: String? = nil) -> DisplayPreset {
        let states = displays.map { display in
            let mode = currentMode(for: display)
            return PresetDisplayState(
                persistentID: display.persistentID,
                displayName: display.name,
                rotation: display.rotation,
                width: mode?.width,
                height: mode?.height,
                isHiDPI: mode?.isHiDPI,
                refreshRate: mode?.refreshRate,
                brightness: display.isBuiltin ? nil : brightnessLevel(for: display),
                softwareDimming: softwareBrightness(for: display)
            )
        }
        return DisplayPreset(name: name ?? settings.nextPresetName(), shortcut: nil, displays: states)
    }

    func saveCurrentSetupAsPreset() -> DisplayPreset {
        settings.addPreset(captureCurrentSetup())
    }

    func applyPreset(id: UUID) {
        guard let preset = settings.presets.first(where: { $0.id == id }) else { return }
        applyPreset(preset)
    }

    /// Restores a preset on every connected display it covers: rotation first (it is the slow,
    /// asynchronous part), then mode, brightness and dimming.
    func applyPreset(_ preset: DisplayPreset) {
        let pairs: [(DisplayInfo, PresetDisplayState)] = preset.displays.compactMap { state in
            guard let display = displays.first(where: { $0.persistentID == state.persistentID }) else { return nil }
            return (display, state)
        }
        guard !pairs.isEmpty else {
            NSSound.beep()
            presentError(title: "Preset \"\(preset.name)\" has nothing to apply",
                         message: "None of the displays saved in this preset are connected right now.")
            return
        }
        Self.log.notice("applying preset \(preset.name, privacy: .public) to \(pairs.count) display(s)")
        for (display, _) in pairs {
            busyDisplays.insert(display.id)
        }
        Task { @MainActor in
            var failures: [String] = []
            for (display, state) in pairs {
                if state.rotation != display.rotation, !display.isBuiltin || self.settings.allowBuiltinRotation {
                    do {
                        _ = try await RotationService.setRotation(state.rotation, of: display.id)
                    } catch {
                        failures.append("\(display.name): \(error.localizedDescription)")
                    }
                }
                let modes = DisplayService.availableModes(for: display.id)
                if let mode = state.bestMode(in: modes), mode.id != DisplayService.currentModeID(for: display.id) {
                    if !DisplayService.setMode(mode.id, for: display.id) {
                        failures.append("\(display.name): macOS rejected \(mode.resolutionDescription)")
                    }
                }
                if let level = state.brightness, !display.isBuiltin {
                    self.brightness.setLevel(level, for: display.id)
                }
                self.setSoftwareBrightness(state.softwareDimming, for: display)
            }
            for (display, _) in pairs {
                self.busyDisplays.remove(display.id)
            }
            self.refresh()
            if !failures.isEmpty {
                self.presentError(title: "Preset \"\(preset.name)\" was only partly applied", message: failures.joined(separator: "\n"))
            }
        }
    }

    // MARK: Brightness

    /// Brightness (0…1) for an external display, hardware when the monitor supports DDC/CI.
    func brightnessLevel(for display: DisplayInfo) -> Double {
        brightness.level(for: display.id)
    }

    func brightnessControl(for display: DisplayInfo) -> BrightnessControl {
        brightness.control(for: display.id)
    }

    func setBrightness(_ level: Double, for display: DisplayInfo) {
        brightness.setLevel(level, for: display.id)
    }

    func adjustBrightness(by delta: Double, for display: DisplayInfo) {
        brightness.adjust(by: delta, for: display.id)
    }

    // MARK: Software dimming

    func softwareBrightness(for display: DisplayInfo) -> Double {
        settings.softwareBrightness[display.persistentID] ?? 1.0
    }

    func setSoftwareBrightness(_ level: Double, for display: DisplayInfo) {
        settings.softwareBrightness[display.persistentID] = level >= 0.999 ? nil : level
        applyGamma(for: display)
    }

    /// Writes the display's gamma table from the persistent Software Dimming setting combined
    /// with the transient extra dimming the brightness keys asked for.
    private func applyGamma(for display: DisplayInfo) {
        let gamma = softwareBrightness(for: display) * brightness.gammaFactor(for: display.id)
        if gamma >= 0.999 {
            if hasAppliedDimming {
                // Only a full ColorSync restore truly undoes our table; then re-dim the others.
                DisplayService.restoreGamma()
                for other in displays where other.id != display.id {
                    applyGammaIfDimmed(other)
                }
            }
        } else {
            DisplayService.setSoftwareBrightness(gamma, for: display.id)
            hasAppliedDimming = true
        }
    }

    private func applyGammaIfDimmed(_ display: DisplayInfo) {
        let gamma = softwareBrightness(for: display) * brightness.gammaFactor(for: display.id)
        if gamma < 0.999 {
            DisplayService.setSoftwareBrightness(gamma, for: display.id)
            hasAppliedDimming = true
        }
    }

    private func reapplySoftwareBrightness() {
        for display in displays {
            applyGammaIfDimmed(display)
        }
    }

    // MARK: Helpers

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refresh()
        }
    }

    private func presentError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
