import Foundation

/// USB HID usage ids (what `axe key` takes) by friendly name and from macOS virtual key codes.
public enum IOSKeys {
    private static let names: [String: UInt8] = [
        "enter": 40, "return": 40, "escape": 41, "backspace": 42, "tab": 43, "space": 44,
        "arrowright": 79, "arrowleft": 80, "arrowdown": 81, "arrowup": 82,
    ]

    public static func usage(named: String) -> UInt8? {
        UInt8(named) ?? names[named.lowercased()]
    }

    public static func button(named: String) -> String? {
        switch named.lowercased() {
        case "home": "home"
        case "lock", "power": "lock"
        default: nil
        }
    }

    private static let mac: [UInt16: UInt8] = [36: 40, 48: 43, 51: 42, 53: 41, 117: 76, 123: 80, 124: 79, 125: 81, 126: 82]

    public static func usage(macKeyCode: UInt16) -> UInt8? { mac[macKeyCode] }
}
