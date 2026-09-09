import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics
import ObjectiveC
import os

/// The mechanism that ended up rotating a display. Reading rotation is public
/// (`CGDisplayRotation`), but macOS has no public API to set it, so this service resolves
/// private entry points at runtime and tries them in order of reliability.
enum RotationBackend: String, CaseIterable {
    /// `SLSSetDisplayRotation` in SkyLight.framework: what System Settings → Displays → Rotation
    /// drives, and the only route that works for DCP-driven (Apple Silicon) displays.
    case skyLight = "SkyLight"
    /// `-[MPDisplay setOrientation:]` in MonitorPanel.framework, the route displayplacer takes.
    case monitorPanel = "MonitorPanel"
    /// `IOServiceRequestProbe` with `kIOFBSetTransform` on the IOFramebuffer. Intel-only; does
    /// nothing on Apple Silicon.
    case ioKit = "IOKit framebuffer"

    var isAvailable: Bool {
        switch self {
        case .skyLight: return RotationService.skyLightSetRotation != nil
        case .monitorPanel: return RotationService.monitorPanelDisplayClass != nil
        case .ioKit: return RotationService.hasIODisplayConnect
        }
    }
}

enum RotationError: LocalizedError {
    case unsupportedAngle(Int)
    case noBackendAvailable
    case notConfirmed(expected: Int, actual: Int, attempted: [RotationBackend])

    var errorDescription: String? {
        switch self {
        case .unsupportedAngle(let angle):
            return "\(angle)° is not a supported rotation. Use 0, 90, 180 or 270."
        case .noBackendAvailable:
            return "No rotation mechanism is available on this Mac. SkyLight, MonitorPanel and IOKit were all unavailable."
        case .notConfirmed(let expected, let actual, let attempted):
            let names = attempted.map(\.rawValue).joined(separator: ", ")
            return "Asked for \(expected)° but the display reports \(actual)°. Tried: \(names)."
        }
    }
}

enum RotationService {
    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "rotation")

    static let validAngles = [0, 90, 180, 270]

    /// Confirmation wait after each backend call. Rotation is asynchronous in WindowServer and
    /// usually settles in well under a second; larger panels can take a couple.
    private static let confirmationTimeout: TimeInterval = 4

    // MARK: Reading

    static func currentRotation(of id: CGDirectDisplayID) -> Int {
        let raw = Int(CGDisplayRotation(id).rounded())
        let normalized = ((raw % 360) + 360) % 360
        return validAngles.min { abs($0 - normalized) < abs($1 - normalized) } ?? 0
    }

    static var availableBackends: [RotationBackend] {
        RotationBackend.allCases.filter(\.isAvailable)
    }

    // MARK: Writing

    /// Rotates `id` to `degrees`, returning the backend that succeeded.
    static func setRotation(_ degrees: Int, of id: CGDirectDisplayID) async throws -> RotationBackend {
        guard validAngles.contains(degrees) else { throw RotationError.unsupportedAngle(degrees) }
        if currentRotation(of: id) == degrees { return availableBackends.first ?? .skyLight }

        let backends = availableBackends
        guard !backends.isEmpty else { throw RotationError.noBackendAvailable }

        var attempted: [RotationBackend] = []
        for backend in backends {
            attempted.append(backend)
            let status: Int32?
            switch backend {
            case .skyLight: status = rotateViaSkyLight(degrees, of: id)
            case .monitorPanel: status = rotateViaMonitorPanel(degrees, of: id)
            case .ioKit: status = rotateViaIOKit(degrees, of: id)
            }
            log.info("\(backend.rawValue, privacy: .public) → \(degrees)° on display \(Int(id)): status \(Int(status ?? -1))")
            guard let status else { continue }
            if await waitForRotation(degrees, of: id, timeout: status == 0 ? confirmationTimeout : 1) {
                return backend
            }
        }
        throw RotationError.notConfirmed(expected: degrees, actual: currentRotation(of: id), attempted: attempted)
    }

    private static func waitForRotation(_ degrees: Int, of id: CGDirectDisplayID, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentRotation(of: id) == degrees { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return currentRotation(of: id) == degrees
    }

    // MARK: SkyLight

    fileprivate typealias SLSSetDisplayRotationFn = @convention(c) (UInt32, Int32) -> Int32

    fileprivate static let skyLightSetRotation: SLSSetDisplayRotationFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let symbol = dlsym(handle, "SLSSetDisplayRotation") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SLSSetDisplayRotationFn.self)
    }()

    private static func rotateViaSkyLight(_ degrees: Int, of id: CGDirectDisplayID) -> Int32? {
        guard let function = skyLightSetRotation else { return nil }
        return function(id, Int32(degrees))
    }

    // MARK: MonitorPanel

    private typealias MsgSendObject = @convention(c) (UnsafeMutableRawPointer?, Selector) -> UnsafeMutableRawPointer?
    private typealias MsgSendIntObject = @convention(c) (UnsafeMutableRawPointer?, Selector, Int32) -> UnsafeMutableRawPointer?
    private typealias MsgSendIntVoid = @convention(c) (UnsafeMutableRawPointer?, Selector, Int32) -> Void
    private typealias MsgSendBool = @convention(c) (UnsafeMutableRawPointer?, Selector) -> Bool

    fileprivate static let monitorPanelDisplayClass: AnyClass? = {
        guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_NOW) != nil else {
            return nil
        }
        return NSClassFromString("MPDisplay")
    }()

    /// Looks up a method implementation and casts it to a concrete C signature so it can be called
    /// with primitive arguments, which `perform(_:)` cannot do.
    private static func implementation<T>(
        of selectorName: String,
        on cls: AnyClass,
        classMethod: Bool = false,
        as type: T.Type
    ) -> (function: T, selector: Selector)? {
        let selector = NSSelectorFromString(selectorName)
        let target: AnyClass? = classMethod ? object_getClass(cls) : cls
        guard let target,
              class_respondsToSelector(target, selector),
              let imp = class_getMethodImplementation(target, selector) else {
            return nil
        }
        return (unsafeBitCast(imp, to: type), selector)
    }

    private static func rotateViaMonitorPanel(_ degrees: Int, of id: CGDirectDisplayID) -> Int32? {
        guard let displayClass = monitorPanelDisplayClass,
              let alloc = implementation(of: "alloc", on: displayClass, classMethod: true, as: MsgSendObject.self),
              let initialize = implementation(of: "initWithCGSDisplayID:", on: displayClass, as: MsgSendIntObject.self),
              let setOrientation = implementation(of: "setOrientation:", on: displayClass, as: MsgSendIntVoid.self) else {
            return nil
        }

        let classPointer = Unmanaged.passUnretained(displayClass as AnyObject).toOpaque()
        guard let allocated = alloc.function(classPointer, alloc.selector),
              let display = initialize.function(allocated, initialize.selector, Int32(bitPattern: id)) else {
            return nil
        }
        // alloc/init handed us a +1 reference that ARC knows nothing about.
        defer { Unmanaged<AnyObject>.fromOpaque(display).release() }

        if let canChange = implementation(of: "canChangeOrientation", on: displayClass, as: MsgSendBool.self),
           canChange.function(display, canChange.selector) == false {
            log.notice("MonitorPanel reports display \(Int(id)) cannot change orientation")
            return -1
        }

        setOrientation.function(display, setOrientation.selector, Int32(degrees))
        return 0
    }

    // MARK: IOKit (Intel framebuffers)

    fileprivate static var hasIODisplayConnect: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    private static func rotateViaIOKit(_ degrees: Int, of id: CGDirectDisplayID) -> Int32? {
        guard let framebuffer = framebufferService(for: id) else { return nil }
        defer { IOObjectRelease(framebuffer) }

        // kIOScaleRotate0/90/180/270 from IOGraphicsTypes.h, shifted into the probe options
        // alongside kIOFBSetTransform (0x400).
        let scaleRotate: UInt32
        switch degrees {
        case 90: scaleRotate = 0x0000_0020
        case 180: scaleRotate = 0x0000_0040
        case 270: scaleRotate = 0x0000_0060
        default: scaleRotate = 0
        }
        let options: IOOptionBits = 0x0000_0400 | (scaleRotate << 16)
        return IOServiceRequestProbe(framebuffer, options)
    }

    /// Finds the IOFramebuffer behind a display by matching EDID vendor / product / serial on the
    /// IODisplayConnect children, the same way displayplacer's Intel path does.
    private static func framebufferService(for id: CGDirectDisplayID) -> io_service_t? {
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let unmanaged = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)),
                  let info = unmanaged.takeRetainedValue() as? [String: Any] else {
                continue
            }
            let infoVendor = (info["DisplayVendorID"] as? NSNumber)?.uint32Value ?? 0
            let infoModel = (info["DisplayProductID"] as? NSNumber)?.uint32Value ?? 0
            let infoSerial = (info["DisplaySerialNumber"] as? NSNumber)?.uint32Value ?? 0
            guard infoVendor == vendor, infoModel == model, serial == 0 || infoSerial == 0 || infoSerial == serial else {
                continue
            }

            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                return parent
            }
        }
        return nil
    }
}
