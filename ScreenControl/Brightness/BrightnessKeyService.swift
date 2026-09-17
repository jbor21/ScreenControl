import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Intercepts the keyboard's brightness keys (F1/F2 or the sun keys) and routes them to the
/// display under the mouse pointer.
///
/// - Pointer on an external display: the press is consumed and that monitor's brightness changes
///   via `BrightnessService` (DDC/CI, or software dimming if the monitor does not answer).
/// - Pointer on the built-in display: the event passes through untouched so macOS adjusts the
///   built-in panel exactly as before.
///
/// Media keys arrive as `NX_SYSDEFINED` events, which only a CGEvent tap can see, and an event tap
/// that can swallow events requires the Accessibility permission.
final class BrightnessKeyService: ObservableObject {
    static let shared = BrightnessKeyService()

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "brightness-keys")

    /// `NX_SYSDEFINED`: the CGEventType used for media / aux control keys. Not a case of Swift's
    /// `CGEventType`, so it is handled by raw value.
    private static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    private static let auxControlSubtype: Int16 = 8
    private static let brightnessUpKey = 2
    private static let brightnessDownKey = 3
    /// Apple's EDID vendor ID: Apple displays (Studio Display, Pro Display XDR, Sidecar) are
    /// brightness-controlled by macOS itself, so their keys are passed through too.
    private static let appleVendorID: UInt32 = 0x610

    /// True while the event tap is installed and running.
    @Published private(set) var isActive = false
    /// Mirrors `AXIsProcessTrusted()`; refreshed on every start attempt and poll.
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<BrightnessKeyService>?
    private var retryTimer: Timer?

    private init() {}

    // MARK: Lifecycle

    /// Installs the tap if permission has been granted; otherwise keeps checking every few
    /// seconds so it comes alive as soon as the user flips the switch in System Settings.
    func start() {
        isTrusted = AXIsProcessTrusted()
        guard eventTap == nil else { return }
        guard isTrusted else {
            scheduleRetry()
            return
        }

        let retained = Unmanaged.passRetained(self)
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedEventType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessKeyTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            Self.log.error("event tap creation failed although the process is trusted; retrying")
            scheduleRetry()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        retainedSelf = retained
        eventTap = tap
        runLoopSource = source
        isActive = true
        retryTimer?.invalidate()
        retryTimer = nil
        Self.log.notice("brightness key tap installed")
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        retainedSelf?.release()
        retainedSelf = nil
        isActive = false
    }

    /// Asks macOS to show the "ScreenControl would like to control this computer using
    /// accessibility features" prompt and adds the app to the Accessibility list.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        if !isTrusted {
            scheduleRetry()
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.isTrusted = AXIsProcessTrusted()
            if self.isTrusted {
                timer.invalidate()
                self.retryTimer = nil
                self.start()
            }
        }
    }

    // MARK: Event handling (main run loop)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // macOS disables a tap that is slow to respond; turn it back on. Raw values are compared
        // throughout because `NX_SYSDEFINED` is not one of `CGEventType`'s Swift cases.
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue
            || type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return passThrough
        }

        guard type.rawValue == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlSubtype else {
            return passThrough
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 >> 16) & 0xFF
        let isKeyDown = (data1 & 0x0100) == 0
        // Only key-down matters; key-up events are always passed through.
        guard isKeyDown, keyCode == Self.brightnessUpKey || keyCode == Self.brightnessDownKey else {
            return passThrough
        }

        guard let displayID = DisplayService.displayIDUnderMouse(),
              CGDisplayIsBuiltin(displayID) == 0,
              CGDisplayVendorNumber(displayID) != Self.appleVendorID else {
            return passThrough
        }

        let fine = nsEvent.modifierFlags.contains([.option, .shift])
        let step = fine ? BrightnessService.fineKeyStep : BrightnessService.keyStep
        let delta = keyCode == Self.brightnessUpKey ? step : -step
        BrightnessService.shared.adjust(by: delta, for: displayID)
        return nil
    }
}

/// C entry point for the tap. `userInfo` is the retained `BrightnessKeyService`.
private func brightnessKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<BrightnessKeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handle(type: type, event: event)
}
