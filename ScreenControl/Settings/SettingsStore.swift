import Combine
import Foundation
import ServiceManagement

/// User preferences, persisted to `UserDefaults` as JSON.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let shortcuts = "shortcuts.v1"
        static let hotkeyTarget = "hotkeyTarget.v1"
        static let allowBuiltinRotation = "allowBuiltinRotation"
        static let showBuiltinDisplay = "showBuiltinDisplay"
        static let softwareBrightness = "softwareBrightness.v1"
        static let brightnessKeysEnabled = "brightnessKeysEnabled"
        static let hasRequestedAccessibility = "hasRequestedAccessibility"
        static let extendedDimming = "extendedDimming"
    }

    @Published var shortcuts: [HotkeyAction: KeyboardShortcut] {
        didSet {
            store(shortcuts, forKey: Keys.shortcuts)
            HotkeyManager.shared.apply(shortcuts)
        }
    }

    @Published var hotkeyTarget: HotkeyTarget {
        didSet { store(hotkeyTarget, forKey: Keys.hotkeyTarget) }
    }

    /// Rotating the built-in panel is rarely wanted and, on some machines, disorienting enough
    /// that it is opt-in.
    @Published var allowBuiltinRotation: Bool {
        didSet { defaults.set(allowBuiltinRotation, forKey: Keys.allowBuiltinRotation) }
    }

    @Published var showBuiltinDisplay: Bool {
        didSet { defaults.set(showBuiltinDisplay, forKey: Keys.showBuiltinDisplay) }
    }

    /// Software dimming level (0.1...1.0) keyed by `DisplayInfo.persistentID`.
    @Published var softwareBrightness: [String: Double] {
        didSet { store(softwareBrightness, forKey: Keys.softwareBrightness) }
    }

    /// Whether the keyboard's brightness keys are redirected to the external display under the
    /// mouse pointer (needs the Accessibility permission).
    @Published var brightnessKeysEnabled: Bool {
        didSet { defaults.set(brightnessKeysEnabled, forKey: Keys.brightnessKeysEnabled) }
    }

    /// Whether brightness keeps dimming (in software) below the monitor's hardware minimum, down
    /// to black.
    @Published var extendedDimming: Bool {
        didSet { defaults.set(extendedDimming, forKey: Keys.extendedDimming) }
    }

    /// The system Accessibility prompt is shown automatically once; after that the user opts in
    /// from Settings so the app never nags.
    var hasRequestedAccessibility: Bool {
        get { defaults.bool(forKey: Keys.hasRequestedAccessibility) }
        set { defaults.set(newValue, forKey: Keys.hasRequestedAccessibility) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = Self.load([HotkeyAction: KeyboardShortcut].self, forKey: Keys.shortcuts, from: defaults)
            ?? HotkeyAction.defaultShortcuts
        hotkeyTarget = Self.load(HotkeyTarget.self, forKey: Keys.hotkeyTarget, from: defaults) ?? .displayUnderMouse
        allowBuiltinRotation = defaults.bool(forKey: Keys.allowBuiltinRotation)
        showBuiltinDisplay = defaults.object(forKey: Keys.showBuiltinDisplay) as? Bool ?? true
        softwareBrightness = Self.load([String: Double].self, forKey: Keys.softwareBrightness, from: defaults) ?? [:]
        brightnessKeysEnabled = defaults.object(forKey: Keys.brightnessKeysEnabled) as? Bool ?? true
        extendedDimming = defaults.object(forKey: Keys.extendedDimming) as? Bool ?? true
    }

    func restoreDefaultShortcuts() {
        shortcuts = HotkeyAction.defaultShortcuts
    }

    /// Assigns `shortcut` to `action`, clearing it from any other action that used the same keys.
    func setShortcut(_ shortcut: KeyboardShortcut?, for action: HotkeyAction) {
        var updated = shortcuts
        if let shortcut {
            for (other, existing) in updated where other != action && existing.sameKeys(as: shortcut) {
                updated[other] = nil
            }
            updated[action] = shortcut
        } else {
            updated[action] = nil
        }
        shortcuts = updated
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }

    // MARK: Persistence

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
