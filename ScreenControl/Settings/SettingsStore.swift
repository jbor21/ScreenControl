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
        static let presets = "presets.v1"
    }

    @Published var shortcuts: [HotkeyAction: KeyboardShortcut] {
        didSet {
            store(shortcuts, forKey: Keys.shortcuts)
            registerHotkeys()
        }
    }

    /// Saved display setups, in the order shown in the menu.
    @Published var presets: [DisplayPreset] {
        didSet {
            store(presets, forKey: Keys.presets)
            // Renaming a preset changes the array on every keystroke; only re-register when a
            // shortcut actually changed.
            let before = oldValue.map { ($0.id, $0.shortcut) }
            let after = presets.map { ($0.id, $0.shortcut) }
            if before.count != after.count || zip(before, after).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 }) {
                registerHotkeys()
            }
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
        presets = Self.load([DisplayPreset].self, forKey: Keys.presets, from: defaults) ?? []
    }

    // MARK: Hotkeys

    /// Every shortcut in one map, fixed actions and presets alike.
    var hotkeyBindings: [HotkeyIdentifier: KeyboardShortcut] {
        var result: [HotkeyIdentifier: KeyboardShortcut] = [:]
        for (action, shortcut) in shortcuts {
            result[.action(action)] = shortcut
        }
        for preset in presets {
            if let shortcut = preset.shortcut {
                result[.preset(preset.id)] = shortcut
            }
        }
        return result
    }

    func registerHotkeys() {
        HotkeyManager.shared.apply(hotkeyBindings)
    }

    func restoreDefaultShortcuts() {
        shortcuts = HotkeyAction.defaultShortcuts
    }

    /// Assigns `shortcut` to `action`, clearing it from anything else that used the same keys.
    func setShortcut(_ shortcut: KeyboardShortcut?, for action: HotkeyAction) {
        if let shortcut {
            releaseShortcut(shortcut, except: .action(action))
        }
        shortcuts[action] = shortcut
    }

    /// Assigns `shortcut` to a preset, clearing it from anything else that used the same keys.
    func setShortcut(_ shortcut: KeyboardShortcut?, forPreset presetID: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        if let shortcut {
            releaseShortcut(shortcut, except: .preset(presetID))
        }
        presets[index].shortcut = shortcut
    }

    private func releaseShortcut(_ shortcut: KeyboardShortcut, except keep: HotkeyIdentifier) {
        for (action, existing) in shortcuts where existing.sameKeys(as: shortcut) && .action(action) != keep {
            shortcuts[action] = nil
        }
        for index in presets.indices where presets[index].shortcut?.sameKeys(as: shortcut) == true && .preset(presets[index].id) != keep {
            presets[index].shortcut = nil
        }
    }

    // MARK: Presets

    @discardableResult
    func addPreset(_ preset: DisplayPreset) -> DisplayPreset {
        presets.append(preset)
        return preset
    }

    func updatePreset(_ preset: DisplayPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    func removePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
    }

    /// "Preset 1", "Preset 2", … skipping names already taken.
    func nextPresetName() -> String {
        var number = presets.count + 1
        while presets.contains(where: { $0.name == "Preset \(number)" }) { number += 1 }
        return "Preset \(number)"
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
