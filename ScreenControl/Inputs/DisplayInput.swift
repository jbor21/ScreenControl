import Foundation

/// A monitor input as addressed by DDC/CI VCP 0x60 (Input Select). The codes are from the MCCS
/// standard; a few common vendor-specific ones for USB-C are included as separate entries.
struct DisplayInput: Hashable, Identifiable {
    let code: UInt16
    let name: String

    var id: UInt16 { code }

    static let vga1 = DisplayInput(code: 0x01, name: "VGA")
    static let dvi1 = DisplayInput(code: 0x03, name: "DVI 1")
    static let dvi2 = DisplayInput(code: 0x04, name: "DVI 2")
    static let displayPort1 = DisplayInput(code: 0x0F, name: "DisplayPort 1")
    static let displayPort2 = DisplayInput(code: 0x10, name: "DisplayPort 2")
    static let hdmi1 = DisplayInput(code: 0x11, name: "HDMI 1")
    static let hdmi2 = DisplayInput(code: 0x12, name: "HDMI 2")
    /// Most brands (Dell, Samsung, BenQ, ASUS…) expose USB-C / Thunderbolt as 0x1B.
    static let usbC = DisplayInput(code: 0x1B, name: "USB-C")
    /// LG monitors report USB-C as 0x19.
    static let usbCLG = DisplayInput(code: 0x19, name: "USB-C (LG)")

    /// Inputs offered in the menu. Monitors only honour the ones they physically have.
    static let common: [DisplayInput] = [.hdmi1, .hdmi2, .displayPort1, .displayPort2, .usbC, .usbCLG, .dvi1, .dvi2, .vga1]

    static func named(_ code: UInt16) -> DisplayInput {
        common.first { $0.code == code } ?? DisplayInput(code: code, name: String(format: "Input 0x%02X", code))
    }
}
