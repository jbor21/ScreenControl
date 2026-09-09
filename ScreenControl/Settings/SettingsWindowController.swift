import AppKit
import SwiftUI

/// Hosts the SwiftUI settings view in a regular window. A hand-rolled window rather than the
/// `Settings` scene because that scene is awkward to open reliably from a menu bar–only app.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "ScreenControl Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 540, height: 460))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support NSCoding")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
