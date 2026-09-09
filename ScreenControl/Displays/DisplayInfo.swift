import CoreGraphics
import Foundation

/// Snapshot of one online display as reported by CoreGraphics.
struct DisplayInfo: Identifiable, Hashable {
    /// CoreGraphics display ID. Stable while the display stays connected, but may change across
    /// reconnects; use `persistentID` for anything that must survive that.
    let id: CGDirectDisplayID
    /// UUID-derived identifier that stays the same for the same physical display across reconnects.
    let persistentID: String
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    /// Current rotation in degrees: 0, 90, 180 or 270.
    let rotation: Int
    /// Logical size in the global (rotated) coordinate space, in points.
    let pointWidth: Int
    let pointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    /// Display this one is mirroring, or 0 when it is not mirroring anything.
    let mirrorSource: CGDirectDisplayID

    var isMirroring: Bool { mirrorSource != 0 }
    var isPortrait: Bool { rotation == 90 || rotation == 270 }

    var resolutionDescription: String {
        "\(pointWidth) × \(pointHeight)"
    }

    var menuTitle: String {
        "\(name)  ·  \(rotation)°"
    }
}

/// One entry of `CGDisplayCopyAllDisplayModes`, reduced to plain values so it can live in SwiftUI state.
struct DisplayModeInfo: Identifiable, Hashable {
    /// `CGDisplayMode.ioDisplayModeID`; pass it back to `DisplayService.setMode` to apply.
    let id: Int32
    /// Logical (point) size.
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var isHiDPI: Bool { pixelWidth > width }

    /// Key that groups modes differing only by refresh rate.
    var resolutionKey: String {
        "\(width)x\(height)\(isHiDPI ? "@2x" : "")"
    }

    var resolutionDescription: String {
        isHiDPI ? "\(width) × \(height) (HiDPI)" : "\(width) × \(height)"
    }

    var refreshRateDescription: String {
        if refreshRate <= 0 { return "Default" }
        if refreshRate.rounded() == refreshRate { return "\(Int(refreshRate)) Hz" }
        return String(format: "%.2f Hz", refreshRate)
    }
}
