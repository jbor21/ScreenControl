import CoreGraphics
import Foundation
import os

/// Reads and switches a monitor's active input over DDC/CI (VCP 0x60). Main-thread API.
final class InputService: ObservableObject {
    static let shared = InputService()

    static let inputVCP: UInt8 = 0x60

    private static let log = Logger(subsystem: "com.boboborenstein.ScreenControl", category: "input")

    /// Last known input code per display. Absent = not read yet or the monitor did not answer.
    @Published private(set) var currentInputs: [CGDirectDisplayID: UInt16] = [:]
    /// Displays whose input query failed; hides the menu section for them.
    @Published private(set) var unsupported: Set<CGDirectDisplayID> = []

    private var probing: Set<CGDirectDisplayID> = []

    private init() {}

    func reset() {
        currentInputs.removeAll()
        unsupported.removeAll()
        probing.removeAll()
    }

    func currentInput(for id: CGDirectDisplayID) -> DisplayInput? {
        currentInputs[id].map(DisplayInput.named)
    }

    /// Reads the active input of each external display once.
    func probe(_ displays: [DisplayInfo]) {
        for display in displays where !display.isBuiltin {
            let id = display.id
            guard currentInputs[id] == nil, !unsupported.contains(id), !probing.contains(id) else { continue }
            probing.insert(id)
            DDCService.shared.queue.async {
                let result = DDCService.shared.read(vcp: Self.inputVCP, for: id)
                DispatchQueue.main.async {
                    self.probing.remove(id)
                    if let result {
                        // Some monitors put the code in the high byte; the low byte is what matters.
                        self.currentInputs[id] = result.current & 0xFF
                    } else {
                        self.unsupported.insert(id)
                    }
                }
            }
        }
    }

    /// Tells the monitor to switch to `input`. If that input is another computer the monitor
    /// leaves the Mac's desktop; there is no way back from here, only from the monitor's buttons.
    func select(_ input: DisplayInput, for id: CGDirectDisplayID, completion: ((Bool) -> Void)? = nil) {
        DDCService.shared.queue.async {
            let success = DDCService.shared.write(vcp: Self.inputVCP, value: input.code, for: id)
            DispatchQueue.main.async {
                if success {
                    self.currentInputs[id] = input.code
                    Self.log.notice("display \(Int(id)) switched to \(input.name, privacy: .public)")
                } else {
                    Self.log.error("display \(Int(id)) refused input \(input.name, privacy: .public)")
                }
                completion?(success)
            }
        }
    }
}
