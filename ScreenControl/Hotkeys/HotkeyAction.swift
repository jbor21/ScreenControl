import Foundation

/// Everything a fixed global shortcut can do. Raw values are persisted, so keep them stable.
/// (Presets have their own, dynamic shortcuts; see `HotkeyIdentifier`.)
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case rotateClockwise
    case rotateCounterclockwise
    case togglePortrait
    case rotateTo0
    case rotateTo90
    case rotateTo180
    case rotateTo270
    case toggleDisplayPower
    case switchInputHDMI1
    case switchInputHDMI2
    case switchInputDisplayPort
    case switchInputUSBC

    enum Category: String, CaseIterable {
        case rotation = "Rotation"
        case power = "Display power"
        case input = "Monitor input"
    }

    var id: String { rawValue }

    var category: Category {
        switch self {
        case .rotateClockwise, .rotateCounterclockwise, .togglePortrait,
             .rotateTo0, .rotateTo90, .rotateTo180, .rotateTo270:
            return .rotation
        case .toggleDisplayPower:
            return .power
        case .switchInputHDMI1, .switchInputHDMI2, .switchInputDisplayPort, .switchInputUSBC:
            return .input
        }
    }

    static func actions(in category: Category) -> [HotkeyAction] {
        allCases.filter { $0.category == category }
    }

    var title: String {
        switch self {
        case .rotateClockwise: return "Rotate +90° (clockwise)"
        case .rotateCounterclockwise: return "Rotate −90° (counterclockwise)"
        case .togglePortrait: return "Toggle portrait / landscape"
        case .rotateTo0: return "Set to 0° (standard)"
        case .rotateTo90: return "Set to 90°"
        case .rotateTo180: return "Set to 180°"
        case .rotateTo270: return "Set to 270°"
        case .toggleDisplayPower: return "Turn display off / back on"
        case .switchInputHDMI1: return "Switch monitor input to HDMI 1"
        case .switchInputHDMI2: return "Switch monitor input to HDMI 2"
        case .switchInputDisplayPort: return "Switch monitor input to DisplayPort"
        case .switchInputUSBC: return "Switch monitor input to USB-C"
        }
    }

    /// New angle for a display currently at `rotation`; nil for non-rotation actions.
    func targetRotation(from rotation: Int) -> Int? {
        switch self {
        case .rotateClockwise: return (rotation + 90) % 360
        case .rotateCounterclockwise: return (rotation + 270) % 360
        case .togglePortrait: return (rotation == 90 || rotation == 270) ? 0 : 90
        case .rotateTo0: return 0
        case .rotateTo90: return 90
        case .rotateTo180: return 180
        case .rotateTo270: return 270
        case .toggleDisplayPower, .switchInputHDMI1, .switchInputHDMI2, .switchInputDisplayPort, .switchInputUSBC:
            return nil
        }
    }

    /// Monitor input the action selects; nil for other actions.
    var input: DisplayInput? {
        switch self {
        case .switchInputHDMI1: return .hdmi1
        case .switchInputHDMI2: return .hdmi2
        case .switchInputDisplayPort: return .displayPort1
        case .switchInputUSBC: return .usbC
        default: return nil
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
        default:
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

/// What a registered global shortcut triggers: a fixed action or a saved preset.
enum HotkeyIdentifier: Hashable {
    case action(HotkeyAction)
    case preset(UUID)

    var logName: String {
        switch self {
        case .action(let action): return action.rawValue
        case .preset(let id): return "preset \(id.uuidString.prefix(8))"
        }
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
