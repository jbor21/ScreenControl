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
final class BrightnessService: ObservableObject {
    static let shared = BrightnessService()

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "brightness")

    /// One brightness-key press moves 1/16 of the range, like macOS does for the built-in panel.
    static let keyStep: Double = 1.0 / 16.0
    /// With ⌥⇧ held macOS uses quarter steps.
    static let fineKeyStep: Double = 1.0 / 64.0

    /// Current level (0…1) per display, as last read from or written to the monitor.
    @Published private(set) var levels: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var controls: [CGDirectDisplayID: BrightnessControl] = [:]

    /// Applies gamma dimming for displays without DDC. Installed by `AppModel` so the fallback is
    /// persisted alongside the menu's Software Dimming setting.
    var softwareFallback: ((CGDirectDisplayID, Double) -> Void)?
    /// Reports the current software dimming level for a display (0.1…1.0).
    var softwareLevelProvider: ((CGDirectDisplayID) -> Double)?

    private var maxValues: [CGDirectDisplayID: UInt16] = [:]
    private var probing: Set<CGDirectDisplayID> = []
    /// Latest requested level per display, so a burst of key repeats collapses into the newest
    /// write. Shared between the main thread and the DDC queue, hence the lock.
    private var pendingWrites: [CGDirectDisplayID: Double] = [:]
    private let pendingLock = NSLock()

    private init() {}

    // MARK: State

    func level(for id: CGDirectDisplayID) -> Double {
        if let level = levels[id] { return level }
        if controls[id] == .software, let gamma = softwareLevelProvider?(id) {
            return min(1.0, max(0.0, (gamma - 0.2) / 0.8))
        }
        return 1.0
    }

    func control(for id: CGDirectDisplayID) -> BrightnessControl {
        controls[id] ?? .unknown
    }

    /// Drops all cached state; call when the display configuration changes.
    func reset() {
        levels.removeAll()
        controls.removeAll()
        maxValues.removeAll()
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
            levels[id] = Double(result.current) / Double(result.max)
            controls[id] = .hardware
            Self.log.notice("display \(Int(id)) brightness \(result.current)/\(result.max) via DDC")
        } else {
            controls[id] = .software
            Self.log.notice("display \(Int(id)) does not answer DDC; using software dimming")
        }
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
            applySoftware(level, for: id)
        case .hardware:
            applyHardware(level, for: id)
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

    private func applySoftware(_ level: Double, for id: CGDirectDisplayID) {
        levels[id] = level
        // Gamma dimming below ~20% makes the screen unreadable, so map the key range onto 0.2…1.0.
        softwareFallback?(id, 0.2 + 0.8 * level)
    }

    private func applyHardware(_ level: Double, for id: CGDirectDisplayID) {
        levels[id] = level
        let maxValue = maxValues[id] ?? 100
        let wasIdle = pendingLock.withLock { () -> Bool in
            let idle = pendingWrites[id] == nil
            pendingWrites[id] = level
            return idle
        }
        guard wasIdle else { return }

        DDCService.shared.queue.async {
            self.flushPendingWrites(for: id, maxValue: maxValue)
        }
    }

    /// Runs on the DDC queue: keeps writing the newest requested level until no newer one arrives.
    private func flushPendingWrites(for id: CGDirectDisplayID, maxValue: UInt16) {
        while true {
            guard let level = pendingLock.withLock({ pendingWrites[id] }) else { return }

            let value = UInt16((level * Double(maxValue)).rounded())
            guard DDCService.shared.writeBrightness(value, for: id) else {
                pendingLock.withLock { pendingWrites[id] = nil }
                DispatchQueue.main.async {
                    Self.log.error("DDC write failed for display \(Int(id)); switching to software dimming")
                    self.controls[id] = .software
                    self.applySoftware(level, for: id)
                }
                return
            }

            let done = pendingLock.withLock { () -> Bool in
                guard pendingWrites[id] == level else { return false }
                pendingWrites[id] = nil
                return true
            }
            if done { return }
        }
    }
}
