import Foundation

/// Android KEYCODE_* lookup by friendly/web/KEYCODE_ name and from macOS virtual key codes.
public enum AndroidKeys {
    // Keys are lowercased, with "keycode_" and "_" removed.
    private static let names: [String: Int32] = [
        "enter": 66, "back": 4, "home": 3, "tab": 61, "escape": 111, "backspace": 67, "del": 67,
        "delete": 112, "forwarddel": 112, "arrowup": 19, "dpadup": 19, "arrowdown": 20, "dpaddown": 20,
        "arrowleft": 21, "dpadleft": 21, "arrowright": 22, "dpadright": 22, "appswitch": 187, "power": 26,
        "volumeup": 24, "volumedown": 25, "menu": 82,
    ]

    public static func keycode(named: String) -> Int32? {
        if let n = Int32(named) { return n }
        var k = named.lowercased()
        if k.hasPrefix("keycode_") { k.removeFirst(8) }
        return names[k.replacingOccurrences(of: "_", with: "")]
    }

    private static let mac: [UInt16: Int32] = [
        36: 66, 48: 61, 51: 67, 117: 112, 53: 111, 126: 19, 125: 20, 123: 21, 124: 22,
        115: 122, 119: 123, 116: 92, 121: 93,
    ]

    public static func keycode(macKeyCode: UInt16) -> Int32? { mac[macKeyCode] }
}
