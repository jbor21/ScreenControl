import AppKit
import Combine
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case shortcuts
    case presets
    case about
}

/// Lets the menu open the settings window on a particular tab (and preset).
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
    /// Preset whose name field should get focus when the Presets tab appears.
    @Published var presetToEdit: UUID?
    private init() {}
}

/// Hosts the SwiftUI settings view in a regular window. A hand-rolled window rather than the
/// `Settings` scene because that scene is awkward to open reliably from a menu bar–only app.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "ScreenControl Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 560))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support NSCoding")
    }

    func show(tab: SettingsTab? = nil, editingPreset: UUID? = nil) {
        if let tab {
            SettingsNavigation.shared.tab = tab
        }
        SettingsNavigation.shared.presetToEdit = editingPreset
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
