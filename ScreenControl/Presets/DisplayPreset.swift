import Foundation

/// A saved arrangement of settings for one or more displays, restorable from the menu or a
/// global shortcut. Displays are matched by `persistentID`, so a preset survives reconnects and
/// simply skips monitors that are not plugged in.
struct DisplayPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var shortcut: KeyboardShortcut?
    var displays: [PresetDisplayState]

    /// Menu subtitle, e.g. "DELL U2720Q 90° 2560 × 1440 · Built-in 0°".
    var summary: String {
        displays.map(\.summary).joined(separator: "  ·  ")
    }
}

struct PresetDisplayState: Codable, Hashable {
    var persistentID: String
    var displayName: String
    var rotation: Int
    /// Logical size and scale of the mode to restore; nil when the display had no mode info.
    var width: Int?
    var height: Int?
    var isHiDPI: Bool?
    var refreshRate: Double?
    /// Combined brightness (0…1) for external displays; nil for the built-in panel.
    var brightness: Double?
    /// Software Dimming level (0.3…1.0).
    var softwareDimming: Double

    var summary: String {
        var parts = [displayName, "\(rotation)°"]
        if let width, let height {
            parts.append("\(width) × \(height)\(isHiDPI == true ? " HiDPI" : "")")
        }
        if let refreshRate, refreshRate > 0 {
            parts.append("\(Int(refreshRate.rounded())) Hz")
        }
        return parts.joined(separator: " ")
    }

    /// The mode in `modes` closest to what was saved: same logical size (in either orientation,
    /// since rotated displays report swapped dimensions) and scale, nearest refresh rate.
    func bestMode(in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        guard let width, let height else { return nil }
        let sameSize = modes.filter { mode in
            let matchesSize = (mode.width == width && mode.height == height) || (mode.width == height && mode.height == width)
            let matchesScale = isHiDPI == nil || mode.isHiDPI == isHiDPI
            return matchesSize && matchesScale
        }
        guard let wanted = refreshRate, wanted > 0 else { return sameSize.first }
        return sameSize.min { abs($0.refreshRate - wanted) < abs($1.refreshRate - wanted) }
    }
}
