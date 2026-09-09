import AppKit
import Carbon.HIToolbox
import Foundation

/// A global shortcut: a virtual key code plus Carbon modifier flags, with the key's label captured
/// at record time because it depends on the active keyboard layout.
struct KeyboardShortcut: Equatable, Hashable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    static let carbonCommand = UInt32(cmdKey)
    static let carbonShift = UInt32(shiftKey)
    static let carbonOption = UInt32(optionKey)
    static let carbonControl = UInt32(controlKey)

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// Builds a shortcut from a key event. Returns `nil` when none of ⌘, ⌥, ⌃ is held: a bare key
    /// (or ⇧ + key) is typing, and registering it globally would swallow normal input everywhere.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= Self.carbonCommand }
        if flags.contains(.shift) { carbon |= Self.carbonShift }
        if flags.contains(.option) { carbon |= Self.carbonOption }
        if flags.contains(.control) { carbon |= Self.carbonControl }
        guard carbon & (Self.carbonCommand | Self.carbonOption | Self.carbonControl) != 0 else { return nil }
        self.init(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbon,
            keyLabel: Self.keyLabel(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        )
    }

    /// "⌃⌥⌘→": modifier glyphs in the canonical macOS order, then the key.
    var display: String {
        var glyphs = ""
        if carbonModifiers & Self.carbonControl != 0 { glyphs += "⌃" }
        if carbonModifiers & Self.carbonOption != 0 { glyphs += "⌥" }
        if carbonModifiers & Self.carbonShift != 0 { glyphs += "⇧" }
        if carbonModifiers & Self.carbonCommand != 0 { glyphs += "⌘" }
        return glyphs + keyLabel
    }

    /// Same physical combination regardless of the captured label.
    func sameKeys(as other: KeyboardShortcut) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }

    static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyLabels[keyCode] { return special }
        guard let characters, !characters.isEmpty else { return "Key \(keyCode)" }
        return characters.uppercased()
    }

    /// Virtual key codes (Carbon `kVK_*`) for keys without a printable character.
    private static let specialKeyLabels: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20"
    ]
}
