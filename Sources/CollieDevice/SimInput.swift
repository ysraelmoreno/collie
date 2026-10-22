import Foundation
import CollieProtocol

/// One input action for a simulator, mapped by the daemon onto an `axe` invocation.
public enum SimInput: Codable, Equatable, Sendable {
    case tap(x: Double, y: Double)
    case swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double)
    case text(String)
    case key(UInt8)
    case button(String)   // home, lock
}

public enum SimText {
    /// `axe type` sends HID keycodes: US-keyboard ASCII (printable + newline) only.
    public static func validate(_ s: String) throws(ProtocolError) {
        guard s.unicodeScalars.allSatisfy({ ($0.value >= 0x20 && $0.value < 0x7F) || $0 == "\n" }) else {
            throw ProtocolError(code: .invalidArgs, message: "device.text on iOS supports US keyboard characters only; use the panel")
        }
    }
}
