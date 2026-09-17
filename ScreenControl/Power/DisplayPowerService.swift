import CoreGraphics
import Darwin
import Foundation
import os

/// A display ScreenControl has turned off, remembered so it can be turned back on even though a
/// disconnected display no longer appears in the online list.
struct TurnedOffDisplay: Identifiable, Codable, Hashable {
    enum Method: String, Codable {
        /// Removed from the desktop with SkyLight's `SLSConfigureDisplayEnabled`. Windows move to
        /// the remaining displays and the monitor sleeps because its signal stops.
        case disconnect
        /// Put into standby over DDC/CI. The desktop still extends onto it.
        case standby
    }

    /// `DisplayInfo.persistentID`.
    let persistentID: String
    let name: String
    /// CoreGraphics ID at the time it was turned off; a fallback for finding it again.
    let lastDisplayID: CGDirectDisplayID
    let method: Method

    var id: String { persistentID }
}

enum DisplayPowerError: LocalizedError {
    case notSupported
    case wouldLeaveNoDisplay
    case configurationFailed(Int32)
    case notConfirmed
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "This Mac can't disconnect displays and the monitor did not accept a DDC/CI power command."
        case .wouldLeaveNoDisplay:
            return "Refusing to turn off the only active display."
        case .configurationFailed(let code):
            return "macOS rejected the display configuration change (error \(code))."
        case .notConfirmed:
            return "macOS accepted the change but the display did not follow. Try again in a moment."
        case .displayNotFound:
            return "The display is no longer known to macOS. Unplug and reconnect it."
        }
    }
}

/// Turns displays off and on again. On Apple Silicon this is a real disconnect through SkyLight
/// (what BetterDisplay's "Disconnect" does): the display leaves the desktop and the monitor goes
/// to sleep for lack of signal. Elsewhere, or when that fails, the monitor is put into standby
/// over DDC/CI instead. Main-thread API; the configuration transaction runs off the main thread.
final class DisplayPowerService: ObservableObject {
    static let shared = DisplayPowerService()

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "power")
    private static let storageKey = "turnedOffDisplays.v1"

    @Published private(set) var turnedOff: [TurnedOffDisplay] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(turnedOff) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([TurnedOffDisplay].self, from: data) {
            turnedOff = saved
        }
    }

    // MARK: SkyLight

    private typealias ConfigureDisplayEnabledFn = @convention(c) (OpaquePointer?, UInt32, Bool) -> Int32
    private typealias GetDisplayListFn = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static let configureDisplayEnabled: ConfigureDisplayEnabledFn? = {
        guard let handle = skyLight, let symbol = dlsym(handle, "SLSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureDisplayEnabledFn.self)
    }()

    private static let getDisplayList: GetDisplayListFn? = {
        guard let handle = skyLight, let symbol = dlsym(handle, "SLSGetDisplayList") else { return nil }
        return unsafeBitCast(symbol, to: GetDisplayListFn.self)
    }()

    /// True disconnects only work on Apple Silicon; on Intel the call returns success but does
    /// nothing visible, so the DDC standby path is used there.
    static var disconnectSupported: Bool {
        #if arch(arm64)
        return configureDisplayEnabled != nil && getDisplayList != nil
        #else
        return false
        #endif
    }

    // MARK: State

    func isTurnedOff(_ persistentID: String) -> Bool {
        turnedOff.contains { $0.persistentID == persistentID }
    }

    func record(for persistentID: String) -> TurnedOffDisplay? {
        turnedOff.first { $0.persistentID == persistentID }
    }

    /// Drops records for disconnected displays that have come back on their own (replugged, or
    /// re-enabled by macOS after sleep). Standby records stay: the desktop never lost them.
    func reconcile(online displays: [DisplayInfo]) {
        let onlineIDs = Set(displays.map(\.persistentID))
        turnedOff.removeAll { $0.method == .disconnect && onlineIDs.contains($0.persistentID) }
    }

    // MARK: Turning off

    /// Main-actor because it publishes `turnedOff`; the slow parts hop off the main thread.
    @MainActor
    func turnOff(_ display: DisplayInfo) async throws {
        guard !isTurnedOff(display.persistentID) else { return }

        if Self.disconnectSupported {
            let activeCount = DisplayService.onlineDisplayIDs().filter { CGDisplayIsActive($0) != 0 }.count
            guard activeCount > 1 else { throw DisplayPowerError.wouldLeaveNoDisplay }

            try await Self.setEnabled(false, id: display.id)
            guard await Self.wait(timeout: 4, until: { !DisplayService.onlineDisplayIDs().contains(display.id) }) else {
                throw DisplayPowerError.notConfirmed
            }
            turnedOff.append(TurnedOffDisplay(persistentID: display.persistentID, name: display.name, lastDisplayID: display.id, method: .disconnect))
            Self.log.notice("disconnected \(display.name, privacy: .public)")
            return
        }

        guard !display.isBuiltin,
              await DDCService.shared.writeAsync(vcp: DDCService.powerVCP, value: DDCService.powerStandby, for: display.id) else {
            throw DisplayPowerError.notSupported
        }
        turnedOff.append(TurnedOffDisplay(persistentID: display.persistentID, name: display.name, lastDisplayID: display.id, method: .standby))
        Self.log.notice("put \(display.name, privacy: .public) into standby via DDC")
    }

    // MARK: Turning on

    @MainActor
    func turnOn(_ record: TurnedOffDisplay) async throws {
        switch record.method {
        case .disconnect:
            guard let id = Self.disabledDisplayID(matching: record) else {
                turnedOff.removeAll { $0.persistentID == record.persistentID }
                throw DisplayPowerError.displayNotFound
            }
            try await Self.setEnabled(true, id: id)
            guard await Self.wait(timeout: 6, until: {
                DisplayService.onlineDisplayIDs().contains { DisplayService.persistentIdentifier(for: $0) == record.persistentID }
            }) else {
                throw DisplayPowerError.notConfirmed
            }
        case .standby:
            guard let id = DisplayService.onlineDisplayIDs().first(where: { DisplayService.persistentIdentifier(for: $0) == record.persistentID }) else {
                turnedOff.removeAll { $0.persistentID == record.persistentID }
                throw DisplayPowerError.displayNotFound
            }
            guard await DDCService.shared.writeAsync(vcp: DDCService.powerVCP, value: DDCService.powerOn, for: id) else {
                throw DisplayPowerError.notSupported
            }
        }
        turnedOff.removeAll { $0.persistentID == record.persistentID }
        Self.log.notice("turned \(record.name, privacy: .public) back on")
    }

    @MainActor
    func turnOnAll() async -> [Error] {
        var errors: [Error] = []
        for record in turnedOff {
            do {
                try await turnOn(record)
            } catch {
                errors.append(error)
            }
        }
        return errors
    }

    /// Called at quit so no display is left disconnected with nothing around to bring it back.
    /// Blocks the main thread for the duration of the transactions (normally well under a second).
    func restoreAllSynchronously() {
        for record in turnedOff where record.method == .disconnect {
            if let id = Self.disabledDisplayID(matching: record) {
                _ = Self.setEnabledSync(true, id: id)
            }
        }
        turnedOff.removeAll { $0.method == .disconnect }
    }

    // MARK: Helpers

    /// IDs of every display WindowServer knows about, including disabled ones that
    /// `CGGetOnlineDisplayList` omits.
    private static func allDisplayIDs() -> [CGDirectDisplayID] {
        guard let getList = getDisplayList else { return [] }
        var count: UInt32 = 0
        guard getList(0, nil, &count) == 0, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getList(count, &ids, &count) == 0 else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func disabledDisplayID(matching record: TurnedOffDisplay) -> CGDirectDisplayID? {
        let online = Set(DisplayService.onlineDisplayIDs())
        let disabled = allDisplayIDs().filter { !online.contains($0) }
        if let match = disabled.first(where: { DisplayService.persistentIdentifier(for: $0) == record.persistentID }) {
            return match
        }
        if disabled.contains(record.lastDisplayID) { return record.lastDisplayID }
        return disabled.count == 1 ? disabled.first : nil
    }

    /// Runs the SkyLight call inside a CoreGraphics configuration transaction. The commit can
    /// block for a while, so it runs on a background thread.
    private static func setEnabled(_ enabled: Bool, id: CGDirectDisplayID) async throws {
        let status = await Task.detached(priority: .userInitiated) {
            setEnabledSync(enabled, id: id)
        }.value
        guard status == 0 else { throw DisplayPowerError.configurationFailed(status) }
    }

    private static func setEnabledSync(_ enabled: Bool, id: CGDirectDisplayID) -> Int32 {
        guard let configure = configureDisplayEnabled else { return -1 }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return Int32(begin.rawValue) }
        let status = configure(config, id, enabled)
        guard status == 0 else {
            CGCancelDisplayConfiguration(config)
            return status
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        return Int32(complete.rawValue)
    }

    private static func wait(timeout: TimeInterval, until condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return condition()
    }
}
