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
                self?.refresh()
            }
            .store(in: &cancellables)

        HotkeyManager.shared.onAction = { [weak self] action in
            self?.perform(action)
        }
        HotkeyManager.shared.apply(settings.shortcuts)

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
    }

    func shutdown() {
        brightnessKeys.stop()
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

    // MARK: Rotation

    func perform(_ action: HotkeyAction) {
        let targets = displays(for: settings.hotkeyTarget)
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }
        for display in targets {
            guard canRotate(display) else {
                NSSound.beep()
                continue
            }
            setRotation(action.targetRotation(from: display.rotation), for: display)
        }
    }

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
