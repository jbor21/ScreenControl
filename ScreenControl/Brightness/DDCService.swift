import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c
import os

/// DDC/CI over I2C: the protocol external monitors use to expose their hardware brightness
/// (and contrast, volume, input…) to the computer. macOS has no public API for it, so:
///
/// - On Apple Silicon the display controller (DCP) exposes an `IOAVService` per external
///   connector; the private `IOAVServiceCreateWithService` / `IOAVServiceWriteI2C` /
///   `IOAVServiceReadI2C` functions in IOKit drive it. They are resolved with `dlsym` so nothing
///   private is linked.
/// - On Intel the IOFramebuffer's I2C bus is reachable through the public `IOI2CInterface` API.
///
/// All I2C traffic is serialized on one background queue: the DCP's I2C engine is shared, and a
/// monitor that is asleep can hold a transaction for seconds.
final class DDCService {
    static let shared = DDCService()

    /// VCP code for backlight brightness.
    static let brightnessVCP: UInt8 = 0x10

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "ddc")

    /// Every I2C transaction and registry walk happens here.
    let queue = DispatchQueue(label: "com.boboborenstein.ScreenControl.ddc", qos: .userInitiated)

    private init() {}

    /// Whether this Mac has any DDC transport at all.
    static var isSupported: Bool {
        #if arch(arm64)
        return avServiceCreate != nil && avServiceWrite != nil && avServiceRead != nil
        #else
        return true
        #endif
    }

    // MARK: Public API (call on `queue`)

    /// Reads the current and maximum brightness of `id`, or nil if the monitor does not answer.
    func readBrightness(for id: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        read(vcp: Self.brightnessVCP, for: id)
    }

    @discardableResult
    func writeBrightness(_ value: UInt16, for id: CGDirectDisplayID) -> Bool {
        write(vcp: Self.brightnessVCP, value: value, for: id)
    }

    /// Reads a VCP feature, retrying briefly; monitors frequently miss the first request.
    func read(vcp: UInt8, for id: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        for attempt in 0..<3 {
            if let result = readOnce(vcp: vcp, for: id) { return result }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return nil
    }

    @discardableResult
    func write(vcp: UInt8, value: UInt16, for id: CGDirectDisplayID) -> Bool {
        for attempt in 0..<3 {
            if writeOnce(vcp: vcp, value: value, for: id) { return true }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return false
    }

    /// Forgets which I2C channel belongs to which display. Call whenever the display
    /// configuration changes: CoreGraphics IDs get reshuffled on reconnect.
    func invalidateChannelMappings() {
        queue.async {
            #if arch(arm64)
            self.avServices = nil
            #endif
        }
    }

    // MARK: DDC/CI framing

    /// Set VCP Feature: `[0x51 (sub-address), 0x84, 0x03, vcp, high, low, checksum]`. The
    /// sub-address byte is passed separately on Apple Silicon and inline on Intel.
    private static func setRequest(vcp: UInt8, value: UInt16) -> [UInt8] {
        [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// Get VCP Feature request: `[0x82, 0x01, vcp]`.
    private static func getRequest(vcp: UInt8) -> [UInt8] {
        [0x82, 0x01, vcp]
    }

    private static func checksum(seed: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// Validates a Get VCP Feature reply and extracts `(current, max)`.
    /// Layout: `[0x6E, 0x88, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, checksum]`.
    private static func parseReply(_ reply: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 11,
              reply[0] == 0x6E, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else {
            return nil
        }
        guard checksum(seed: 0x50, Array(reply[0...9])) == reply[10] else { return nil }
        let maxValue = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let current = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        guard maxValue > 0 else { return nil }
        return (current, maxValue)
    }

    // MARK: Transport selection

    private func readOnce(vcp: UInt8, for id: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        #if arch(arm64)
        return avServiceRead(vcp: vcp, for: id)
        #else
        return framebufferRead(vcp: vcp, for: id)
        #endif
    }

    private func writeOnce(vcp: UInt8, value: UInt16, for id: CGDirectDisplayID) -> Bool {
        #if arch(arm64)
        return avServiceWrite(vcp: vcp, value: value, for: id)
        #else
        return framebufferWrite(vcp: vcp, value: value, for: id)
        #endif
    }

    // MARK: - Apple Silicon: IOAVService

    #if arch(arm64)
    private typealias AVServiceCreateFn = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias AVServiceI2CFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private static let ioKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static let avServiceCreate: AVServiceCreateFn? = {
        guard let handle = ioKitHandle, let symbol = dlsym(handle, "IOAVServiceCreateWithService") else { return nil }
        return unsafeBitCast(symbol, to: AVServiceCreateFn.self)
    }()

    private static let avServiceWrite: AVServiceI2CFn? = {
        guard let handle = ioKitHandle, let symbol = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
        return unsafeBitCast(symbol, to: AVServiceI2CFn.self)
    }()

    private static let avServiceRead: AVServiceI2CFn? = {
        guard let handle = ioKitHandle, let symbol = dlsym(handle, "IOAVServiceReadI2C") else { return nil }
        return unsafeBitCast(symbol, to: AVServiceI2CFn.self)
    }()

    /// DDC/CI device address and the sub-address the DCP prepends for us.
    private static let ddcChipAddress: UInt32 = 0x37
    private static let ddcDataAddress: UInt32 = 0x51

    /// Display → IOAVService, built lazily and dropped on reconfiguration. `nil` = not built yet.
    private var avServices: [CGDirectDisplayID: CFTypeRef]?

    private struct DisplayIdentity {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    private func avService(for id: CGDirectDisplayID) -> CFTypeRef? {
        if avServices == nil {
            avServices = buildAVServiceMap()
        }
        return avServices?[id]
    }

    /// Walks the IOService registry depth-first. Under each `dispextN` node the DCP publishes the
    /// display's identity (`DisplayAttributes → ProductAttributes`) shortly before that display's
    /// `DCPAVServiceProxy`, so each channel is paired with the most recently seen identity, then
    /// matched to CoreGraphics displays by vendor/product/serial, with traversal order as the
    /// last resort. Same strategy as MonitorControl and Crisp.
    private func buildAVServiceMap() -> [CGDirectDisplayID: CFTypeRef] {
        guard let create = Self.avServiceCreate else { return [:] }

        let externalIDs = DisplayService.onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
        guard !externalIDs.isEmpty else { return [:] }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var channels: [CFTypeRef] = []
        var identities: [DisplayIdentity?] = []
        var lastIdentity: DisplayIdentity?

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            if let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any],
               let identity = Self.identity(from: product) {
                lastIdentity = identity
            }

            guard Self.className(of: entry) == "DCPAVServiceProxy" else { continue }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == nil || location == "External" else { continue }
            guard let raw = create(kCFAllocatorDefault, entry) else { continue }
            channels.append(Unmanaged<CFTypeRef>.fromOpaque(raw).takeRetainedValue())
            identities.append(lastIdentity)
        }

        var map: [CGDirectDisplayID: CFTypeRef] = [:]
        var usedChannels = Set<Int>()
        var unmatched: [CGDirectDisplayID] = []

        for id in externalIDs {
            let vendor = CGDisplayVendorNumber(id)
            let product = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)

            func firstFree(where predicate: (DisplayIdentity) -> Bool) -> Int? {
                identities.indices.first { index in
                    guard !usedChannels.contains(index), let identity = identities[index] else { return false }
                    return predicate(identity)
                }
            }

            let match = (serial != 0 ? firstFree { $0.vendor == vendor && $0.product == product && $0.serial == serial } : nil)
                ?? firstFree { $0.vendor == vendor && $0.product == product }
            if let match {
                usedChannels.insert(match)
                map[id] = channels[match]
            } else {
                unmatched.append(id)
            }
        }

        // Anything left over (e.g. two identical monitors) is paired in traversal order.
        for id in unmatched {
            guard let index = channels.indices.first(where: { !usedChannels.contains($0) }) else { break }
            usedChannels.insert(index)
            map[id] = channels[index]
        }

        Self.log.notice("DDC channels: \(channels.count) found, \(map.count) of \(externalIDs.count) external displays paired")
        return map
    }

    private static func identity(from productAttributes: [String: Any]) -> DisplayIdentity? {
        func value(_ key: String) -> UInt32? {
            guard let number = productAttributes[key] as? NSNumber else { return nil }
            return UInt32(truncatingIfNeeded: number.int64Value)
        }
        guard let vendor = value("LegacyManufacturerID"), let product = value("ProductID") else { return nil }
        return DisplayIdentity(vendor: vendor, product: product, serial: value("SerialNumber") ?? 0)
    }

    private static func className(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    private func avServiceWrite(vcp: UInt8, value: UInt16, for id: CGDirectDisplayID) -> Bool {
        guard let write = Self.avServiceWrite, let service = avService(for: id) else { return false }
        let payload = Self.setRequest(vcp: vcp, value: value)
        var buffer = payload + [Self.checksum(seed: 0x6E ^ 0x51, payload)]
        let servicePointer = Unmanaged.passUnretained(service).toOpaque()
        let status = buffer.withUnsafeMutableBytes { bytes in
            write(servicePointer, Self.ddcChipAddress, Self.ddcDataAddress, bytes.baseAddress!, UInt32(bytes.count))
        }
        if status != KERN_SUCCESS {
            Self.log.debug("I2C write failed for display \(Int(id)): \(status)")
        }
        return status == KERN_SUCCESS
    }

    private func avServiceRead(vcp: UInt8, for id: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        guard let write = Self.avServiceWrite, let read = Self.avServiceRead, let service = avService(for: id) else { return nil }
        let servicePointer = Unmanaged.passUnretained(service).toOpaque()

        let payload = Self.getRequest(vcp: vcp)
        var request = payload + [Self.checksum(seed: 0x6E ^ 0x51, payload)]
        let writeStatus = request.withUnsafeMutableBytes { bytes in
            write(servicePointer, Self.ddcChipAddress, Self.ddcDataAddress, bytes.baseAddress!, UInt32(bytes.count))
        }
        guard writeStatus == KERN_SUCCESS else { return nil }

        // DDC/CI gives the monitor 40 ms to prepare its reply.
        Thread.sleep(forTimeInterval: 0.04)

        var reply = [UInt8](repeating: 0, count: 12)
        let readStatus = reply.withUnsafeMutableBytes { bytes in
            read(servicePointer, Self.ddcChipAddress, Self.ddcDataAddress, bytes.baseAddress!, UInt32(bytes.count))
        }
        guard readStatus == KERN_SUCCESS else { return nil }
        return Self.parseReply(reply, vcp: vcp)
    }
    #endif

    // MARK: - Intel: IOFramebuffer I2C

    #if !arch(arm64)
    /// Runs `body` against every I2C bus of the display's framebuffer until one returns a value.
    private func withI2CConnections<T>(for id: CGDirectDisplayID, _ body: (IOI2CConnectRef) -> T?) -> T? {
        guard let framebuffer = RotationService.framebufferService(for: id) else { return nil }
        defer { IOObjectRelease(framebuffer) }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else { return nil }

        for bus in 0..<busCount {
            var interface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }

            var connection: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connection) == KERN_SUCCESS, let connection else { continue }
            defer { _ = IOI2CInterfaceClose(connection, 0) }

            if let result = body(connection) { return result }
        }
        return nil
    }

    private func framebufferWrite(vcp: UInt8, value: UInt16, for id: CGDirectDisplayID) -> Bool {
        var packet: [UInt8] = [0x51] + Self.setRequest(vcp: vcp, value: value)
        packet.append(Self.checksum(seed: 0x6E, packet))

        return withI2CConnections(for: id) { connection -> Bool? in
            packet.withUnsafeMutableBytes { bytes -> Bool? in
                var request = IOI2CRequest()
                request.sendAddress = 0x6E
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: bytes.baseAddress)
                request.sendBytes = UInt32(bytes.count)
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                request.minReplyDelay = 10_000_000
                guard IOI2CSendRequest(connection, 0, &request) == KERN_SUCCESS, request.result == KERN_SUCCESS else {
                    return nil
                }
                return true
            }
        } ?? false
    }

    private func framebufferRead(vcp: UInt8, for id: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        var packet: [UInt8] = [0x51] + Self.getRequest(vcp: vcp)
        packet.append(Self.checksum(seed: 0x6E, packet))
        var reply = [UInt8](repeating: 0, count: 12)

        return withI2CConnections(for: id) { connection -> (current: UInt16, max: UInt16)? in
            packet.withUnsafeMutableBytes { sendBytes -> (current: UInt16, max: UInt16)? in
                reply.withUnsafeMutableBytes { replyBytes -> (current: UInt16, max: UInt16)? in
                    var request = IOI2CRequest()
                    request.sendAddress = 0x6E
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = vm_address_t(bitPattern: sendBytes.baseAddress)
                    request.sendBytes = UInt32(sendBytes.count)
                    request.replyAddress = 0x6F
                    request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                    request.replyBuffer = vm_address_t(bitPattern: replyBytes.baseAddress)
                    request.replyBytes = UInt32(replyBytes.count)
                    request.minReplyDelay = 50_000_000
                    guard IOI2CSendRequest(connection, 0, &request) == KERN_SUCCESS, request.result == KERN_SUCCESS else {
                        return nil
                    }
                    return Self.parseReply(Array(replyBytes.bindMemory(to: UInt8.self)), vcp: vcp)
                }
            }
        }
    }
    #endif
}
