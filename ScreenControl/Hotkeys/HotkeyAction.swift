import Foundation

/// Everything a global shortcut can do. Raw values are persisted, so keep them stable.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case rotateClockwise
    case rotateCounterclockwise
    case togglePortrait
    case rotateTo0
    case rotateTo90
    case rotateTo180
    case rotateTo270

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rotateClockwise: return "Rotate +90° (clockwise)"
        case .rotateCounterclockwise: return "Rotate −90° (counterclockwise)"
        case .togglePortrait: return "Toggle portrait / landscape"
        case .rotateTo0: return "Set to 0° (standard)"
        case .rotateTo90: return "Set to 90°"
        case .rotateTo180: return "Set to 180°"
        case .rotateTo270: return "Set to 270°"
        }
    }

    /// New angle for a display currently at `rotation`.
    func targetRotation(from rotation: Int) -> Int {
        switch self {
        case .rotateClockwise: return (rotation + 90) % 360
        case .rotateCounterclockwise: return (rotation + 270) % 360
        case .togglePortrait: return (rotation == 90 || rotation == 270) ? 0 : 90
        case .rotateTo0: return 0
        case .rotateTo90: return 90
        case .rotateTo180: return 180
        case .rotateTo270: return 270
        }
    }

    /// Shortcuts installed on first launch. ⌃⌥⌘ + arrows is free of system bindings by default.
    var defaultShortcut: KeyboardShortcut? {
        let modifiers = KeyboardShortcut.carbonControl | KeyboardShortcut.carbonOption | KeyboardShortcut.carbonCommand
        switch self {
        case .rotateClockwise:
            return KeyboardShortcut(keyCode: 124, carbonModifiers: modifiers, keyLabel: "→")
        case .rotateCounterclockwise:
            return KeyboardShortcut(keyCode: 123, carbonModifiers: modifiers, keyLabel: "←")
        case .togglePortrait:
            return KeyboardShortcut(keyCode: 126, carbonModifiers: modifiers, keyLabel: "↑")
        case .rotateTo0:
            return KeyboardShortcut(keyCode: 125, carbonModifiers: modifiers, keyLabel: "↓")
        case .rotateTo90, .rotateTo180, .rotateTo270:
            return nil
        }
    }

    static var defaultShortcuts: [HotkeyAction: KeyboardShortcut] {
        var result: [HotkeyAction: KeyboardShortcut] = [:]
        for action in allCases {
            if let shortcut = action.defaultShortcut { result[action] = shortcut }
        }
        return result
    }
}

/// Which display(s) a shortcut acts on.
enum HotkeyTarget: Hashable, Codable {
    /// The display the mouse pointer is currently on. Falls back to the main display.
    case displayUnderMouse
    case mainDisplay
    /// Every display that is not the built-in panel.
    case allExternalDisplays
    /// A specific display, identified by `DisplayInfo.persistentID`.
    case specificDisplay(String)

    var specificDisplayID: String? {
        if case .specificDisplay(let id) = self { return id }
        return nil
    }
}
