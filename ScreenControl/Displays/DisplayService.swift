import AppKit
import CoreGraphics
import Foundation

/// Thin wrappers over the public CoreGraphics display APIs.
enum DisplayService {

    // MARK: Enumeration

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func onlineDisplays() -> [DisplayInfo] {
        onlineDisplayIDs().map(info(for:)).sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func info(for id: CGDirectDisplayID) -> DisplayInfo {
        let bounds = CGDisplayBounds(id)
        return DisplayInfo(
            id: id,
            persistentID: persistentIdentifier(for: id),
            name: name(for: id),
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            rotation: RotationService.currentRotation(of: id),
            pointWidth: Int(bounds.width),
            pointHeight: Int(bounds.height),
            pixelWidth: Int(CGDisplayPixelsWide(id)),
            pixelHeight: Int(CGDisplayPixelsHigh(id)),
            mirrorSource: CGDisplayMirrorsDisplay(id)
        )
    }

    // MARK: Identity and naming

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == id
        }
    }

    static func name(for id: CGDirectDisplayID) -> String {
        if let screen = screen(for: id) {
            return screen.localizedName
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    /// Identifier that survives reconnects and reboots for the same physical display.
    static func persistentIdentifier(for id: CGDirectDisplayID) -> String {
        if let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuid = unmanaged.takeRetainedValue()
            if let string = CFUUIDCreateString(nil, uuid) {
                return string as String
            }
        }
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    static func displayIDUnderMouse() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else {
            return nil
        }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value
    }

    // MARK: Display modes

    private static var modeListOptions: CFDictionary {
        [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    }

    private static func rawModes(for id: CGDirectDisplayID) -> [CGDisplayMode] {
        (CGDisplayCopyAllDisplayModes(id, modeListOptions) as? [CGDisplayMode]) ?? []
    }

    /// Modes usable for the desktop, de-duplicated by size / scale / refresh rate and sorted largest first.
    static func availableModes(for id: CGDirectDisplayID) -> [DisplayModeInfo] {
        var seen = Set<String>()
        var result: [DisplayModeInfo] = []
        for mode in rawModes(for: id) where mode.isUsableForDesktopGUI() {
            let info = DisplayModeInfo(
                id: mode.ioDisplayModeID,
                width: mode.width,
                height: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                refreshRate: mode.refreshRate
            )
            let key = "\(info.resolutionKey)@\(Int((info.refreshRate * 100).rounded()))"
            if seen.insert(key).inserted {
                result.append(info)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return lhs.refreshRate > rhs.refreshRate
        }
    }

    static func currentModeID(for id: CGDirectDisplayID) -> Int32? {
        CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
    }

    @discardableResult
    static func setMode(_ modeID: Int32, for id: CGDirectDisplayID) -> Bool {
        guard let mode = rawModes(for: id).first(where: { $0.ioDisplayModeID == modeID }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: Mirroring

    /// Makes `id` mirror `source`; pass `nil` to stop mirroring.
    @discardableResult
    static func setMirroring(of id: CGDirectDisplayID, to source: CGDirectDisplayID?) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(config, id, source ?? 0) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: Software dimming

    /// Dims the display by scaling its gamma table. `level` is 0.0...1.0 where 1.0 is untouched
    /// and 0.0 is black.
    static func setSoftwareBrightness(_ level: Double, for id: CGDirectDisplayID) {
        let clamped = CGGammaValue(max(0.0, min(1.0, level)))
        CGSetDisplayTransferByFormula(id, 0, clamped, 1, 0, clamped, 1, 0, clamped, 1)
    }

    /// Reverts every display's gamma to its ColorSync profile.
    static func restoreGamma() {
        CGDisplayRestoreColorSyncSettings()
    }
}
