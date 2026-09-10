import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Registers global shortcuts through Carbon's `RegisterEventHotKey`, which fires no matter which
/// app is frontmost and needs no Accessibility permission, unlike a CGEvent tap.
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Invoked on the main thread when a registered shortcut is pressed.
    var onTrigger: ((HotkeyIdentifier) -> Void)?

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "hotkeys")
    private static let signature = OSType(0x5343_7472) // "SCtr"

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, identifier: HotkeyIdentifier)] = [:]
    private var nextID: UInt32 = 1
    private var bindings: [HotkeyIdentifier: KeyboardShortcut] = [:]
    /// While a shortcut recorder is open every hotkey is unregistered, so the recorder can capture
    /// combinations that are currently bound. A counter rather than a flag because two recorder
    /// rows can briefly overlap during a takeover.
    private var suspensions = 0

    private init() {}

    func apply(_ bindings: [HotkeyIdentifier: KeyboardShortcut]) {
        self.bindings = bindings
        synchronize()
    }

    func beginSuspension() {
        suspensions += 1
        synchronize()
    }

    func endSuspension() {
        suspensions = max(0, suspensions - 1)
        synchronize()
    }

    private func synchronize() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations = [:]
        guard suspensions == 0 else { return }
        for (identifier, shortcut) in bindings {
            register(shortcut, for: identifier)
        }
        Self.log.info("registered \(self.registrations.count) hotkey(s)")
    }

    private func register(_ shortcut: KeyboardShortcut, for identifier: HotkeyIdentifier) {
        installHandlerIfNeeded()
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            registrations[id] = (ref, identifier)
        } else {
            Self.log.error("RegisterEventHotKey failed (\(status)) for \(shortcut.display, privacy: .public)")
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async {
                HotkeyManager.shared.fire(id: id)
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        if status != noErr {
            Self.log.error("InstallEventHandler failed (\(status))")
        }
    }

    private func fire(id: UInt32) {
        guard let registration = registrations[id] else { return }
        Self.log.info("hotkey pressed: \(registration.identifier.logName, privacy: .public)")
        onTrigger?(registration.identifier)
    }
}
