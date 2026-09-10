import AppKit
import CoreGraphics
import Foundation
import os

/// How a display's brightness is being controlled.
enum BrightnessControl: Equatable {
    /// Not probed yet.
    case unknown
    /// The monitor answers DDC/CI, so its real backlight is being driven.
    case hardware
    /// The monitor ignores DDC/CI; the gamma table is scaled instead (same as Software Dimming).
    case software
    /// Built-in panel: macOS owns its brightness, so keys are passed through untouched.
    case system

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .hardware: return "Hardware (DDC/CI)"
        case .software: return "Software dimming (monitor ignores DDC/CI)"
        case .system: return "Controlled by macOS"
        }
    }
}

/// Owns per-display brightness state and applies changes through `DDCService`, falling back to
/// gamma dimming for monitors that do not answer. Main-thread API; I2C runs on `DDCService.queue`.
///
/// The level exposed to keys and the menu is a single 0…1 "combined" range. A monitor's own
/// brightness setting never turns the picture off (0 is just the backlight's minimum), so when
/// extended dimming is on the bottom quarter of the range keeps going below the hardware
/// minimum by scaling the gamma table, all the way to black, like BetterDisplay's combined
/// brightness. Above that the range drives the hardware only.
final class BrightnessService: ObservableObject {
    static let shared = BrightnessService()

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "brightness")

    /// One brightness-key press moves 1/16 of the range, like macOS does for the built-in panel.
    static let keyStep: Double = 1.0 / 16.0
    /// With ⌥⇧ held macOS uses quarter steps.
    static let fineKeyStep: Double = 1.0 / 64.0
    /// Share of the combined range that is software dimming below the hardware minimum
    /// (4 of the 16 key steps).
    static let softwareShare: Double = 0.25

    /// Combined level (0…1) per display.
    @Published private(set) var levels: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var controls: [CGDirectDisplayID: BrightnessControl] = [:]

    /// Whether the range extends below the hardware minimum into gamma dimming. Set by `AppModel`
    /// from the user's settings.
    private(set) var extendedDimmingEnabled = true

    /// Changes the range mapping, keeping every monitor's hardware brightness where it is and
    /// clearing any extra dimming so the picture is never left dark by a settings change.
    func setExtendedDimming(_ enabled: Bool) {
        guard enabled != extendedDimmingEnabled else { return }
        extendedDimmingEnabled = enabled
        for id in Array(levels.keys) {
            setGamma(1, for: id)
            if control(for: id) == .hardware, let fraction = hardwareFractions[id] {
                levels[id] = combinedLevel(hardware: fraction, gamma: 1)
            } else {
                levels[id] = 1
            }
        }
    }

    /// Applies a gamma multiplier (0 = black … 1 = untouched) to a display. Installed by
    /// `AppModel`, which combines it with the menu's persistent Software Dimming setting.
    var applyGammaFactor: ((CGDirectDisplayID, Double) -> Void)?

    private var maxValues: [CGDirectDisplayID: UInt16] = [:]
    /// Hardware fraction (0…1) last handed to the DDC writer, to skip redundant writes.
    private var hardwareFractions: [CGDirectDisplayID: Double] = [:]
    /// Gamma multiplier currently applied per display (absent = 1).
    private var gammaFactors: [CGDirectDisplayID: Double] = [:]
    private var probing: Set<CGDirectDisplayID> = []
    /// Latest requested hardware fraction per display, so a burst of key repeats collapses into
    /// the newest write. Shared between the main thread and the DDC queue, hence the lock.
    private var pendingWrites: [CGDirectDisplayID: Double] = [:]
    private let pendingLock = NSLock()

    private init() {}

    // MARK: State

    func level(for id: CGDirectDisplayID) -> Double {
        levels[id] ?? 1.0
    }

    func control(for id: CGDirectDisplayID) -> BrightnessControl {
        controls[id] ?? .unknown
    }

    /// Gamma multiplier the display should currently have (1 when undimmed).
    func gammaFactor(for id: CGDirectDisplayID) -> Double {
        gammaFactors[id] ?? 1.0
    }

    /// Drops all cached state; call when the display configuration changes.
    func reset() {
        levels.removeAll()
        controls.removeAll()
        maxValues.removeAll()
        hardwareFractions.removeAll()
        gammaFactors.removeAll()
        probing.removeAll()
        pendingLock.withLock { pendingWrites.removeAll() }
        DDCService.shared.invalidateChannelMappings()
    }

    /// Reads the current hardware brightness of every external display in the background so the
    /// menu and the first key press start from the real value.
    func probe(_ displays: [DisplayInfo]) {
        for display in displays {
            if display.isBuiltin {
                controls[display.id] = .system
                continue
            }
            guard controls[display.id] == nil || controls[display.id] == .unknown, !probing.contains(display.id) else { continue }
            probing.insert(display.id)
            controls[display.id] = .unknown
            let id = display.id
            DDCService.shared.queue.async {
                let result = DDCService.shared.readBrightness(for: id)
                DispatchQueue.main.async {
                    self.probing.remove(id)
                    self.finishProbe(id, result: result)
                }
            }
        }
    }

    private func finishProbe(_ id: CGDirectDisplayID, result: (current: UInt16, max: UInt16)?) {
        if let result {
            maxValues[id] = result.max
            let fraction = Double(result.current) / Double(result.max)
            hardwareFractions[id] = fraction
            controls[id] = .hardware
            if levels[id] == nil {
                levels[id] = combinedLevel(hardware: fraction, gamma: gammaFactor(for: id))
            }
            Self.log.notice("display \(Int(id)) brightness \(result.current)/\(result.max) via DDC")
        } else {
            controls[id] = .software
            if levels[id] == nil {
                levels[id] = gammaFactor(for: id)
            }
            Self.log.notice("display \(Int(id)) does not answer DDC; using software dimming")
        }
    }

    // MARK: Range mapping

    private var softwareShare: Double {
        extendedDimmingEnabled ? Self.softwareShare : 0
    }

    /// Splits a combined level into the hardware fraction and the gamma multiplier.
    private func split(_ level: Double) -> (hardware: Double, gamma: Double) {
        let share = softwareShare
        if level >= share {
            return (share < 1 ? (level - share) / (1 - share) : 1, 1)
        }
        return (0, share > 0 ? level / share : 0)
    }

    private func combinedLevel(hardware: Double, gamma: Double) -> Double {
        let share = softwareShare
        if gamma < 1, share > 0 {
            return gamma * share
        }
        return share + hardware * (1 - share)
    }

    // MARK: Changing brightness

    /// Nudges the display by `delta` (fraction of the full range) and shows the system OSD.
    func adjust(by delta: Double, for id: CGDirectDisplayID) {
        let target = min(1.0, max(0.0, level(for: id) + delta))
        setLevel(target, for: id, showOSD: true)
    }

    func setLevel(_ target: Double, for id: CGDirectDisplayID, showOSD: Bool = false) {
        let level = min(1.0, max(0.0, target))
        switch control(for: id) {
        case .system:
            return
        case .software:
            levels[id] = level
            setGamma(level, for: id)
        case .hardware:
            levels[id] = level
            let parts = split(level)
            setGamma(parts.gamma, for: id)
            setHardware(parts.hardware, for: id)
        case .unknown:
            // Not probed yet: try the monitor once, then apply through whichever path works.
            levels[id] = level
            DDCService.shared.queue.async {
                let result = DDCService.shared.readBrightness(for: id)
                DispatchQueue.main.async {
                    self.finishProbe(id, result: result)
                    self.setLevel(level, for: id, showOSD: false)
                }
            }
        }
        if showOSD {
            BrightnessOSD.show(level: level, on: id)
        }
    }

    private func setGamma(_ factor: Double, for id: CGDirectDisplayID) {
        let clamped = min(1.0, max(0.0, factor))
        guard gammaFactor(for: id) != clamped else { return }
        gammaFactors[id] = clamped == 1 ? nil : clamped
        applyGammaFactor?(id, clamped)
    }

    private func setHardware(_ fraction: Double, for id: CGDirectDisplayID) {
        guard hardwareFractions[id] != fraction else { return }
        hardwareFractions[id] = fraction
        let maxValue = maxValues[id] ?? 100
        let wasIdle = pendingLock.withLock { () -> Bool in
            let idle = pendingWrites[id] == nil
            pendingWrites[id] = fraction
            return idle
        }
        guard wasIdle else { return }

        DDCService.shared.queue.async {
            self.flushPendingWrites(for: id, maxValue: maxValue)
        }
    }

    /// Runs on the DDC queue: keeps writing the newest requested fraction until no newer one arrives.
    private func flushPendingWrites(for id: CGDirectDisplayID, maxValue: UInt16) {
        while true {
            guard let fraction = pendingLock.withLock({ pendingWrites[id] }) else { return }

            let value = UInt16((fraction * Double(maxValue)).rounded())
            guard DDCService.shared.writeBrightness(value, for: id) else {
                pendingLock.withLock { pendingWrites[id] = nil }
                DispatchQueue.main.async {
                    Self.log.error("DDC write failed for display \(Int(id)); switching to software dimming")
                    self.controls[id] = .software
                    self.hardwareFractions[id] = nil
                    self.setGamma(self.level(for: id), for: id)
                }
                return
            }

            let done = pendingLock.withLock { () -> Bool in
                guard pendingWrites[id] == fraction else { return false }
                pendingWrites[id] = nil
                return true
            }
            if done { return }
        }
    }
}
