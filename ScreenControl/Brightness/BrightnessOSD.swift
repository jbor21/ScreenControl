import AppKit
import CoreGraphics
import Foundation

/// The brightness bezel macOS draws is provided by the `com.apple.OSDUIHelper` XPC service.
/// Calling it directly gives external displays the exact same overlay the built-in panel gets.
/// (Private interface; if Apple changes it the call silently does nothing.)
@objc enum OSDImage: CLong {
    case brightness = 1
    case volume = 3
    case mute = 4
}

@objc protocol OSDUIHelperProtocol {
    func showImage(
        _ image: OSDImage,
        onDisplayID displayID: CGDirectDisplayID,
        priority: CUnsignedInt,
        msecUntilFade: CUnsignedInt,
        filledChiclets: CUnsignedInt,
        totalChiclets: CUnsignedInt,
        locked: Bool
    )
}

enum BrightnessOSD {
    private static let totalChiclets: CUnsignedInt = 16

    static func show(level: Double, on displayID: CGDirectDisplayID) {
        let connection = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
        connection.resume()

        guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? OSDUIHelperProtocol else {
            connection.invalidate()
            return
        }
        helper.showImage(
            .brightness,
            onDisplayID: displayID,
            priority: 0x1f4,
            msecUntilFade: 1500,
            filledChiclets: CUnsignedInt((level * Double(totalChiclets)).rounded()),
            totalChiclets: totalChiclets,
            locked: false
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            connection.invalidate()
        }
    }
}
