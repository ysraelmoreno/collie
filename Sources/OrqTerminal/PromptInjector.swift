import Foundation

public enum PromptInjector {
    private static let pasteStart = "\u{1B}[200~"
    private static let pasteEnd = "\u{1B}[201~"

    public static func sanitize(_ prompt: String) -> String {
        var s = prompt.replacingOccurrences(of: pasteStart, with: "")
            .replacingOccurrences(of: pasteEnd, with: "")
        s.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\n" && $0 != "\t" || $0.value == 0x7F }
        return s
    }

    /// `bracketed`: wrap in bracketed-paste markers; only when the target enabled `ESC[?2004h`.
    public static func payload(_ prompt: String, raw: Bool, bracketed: Bool = true) -> Data {
        if !raw {
            let s = sanitize(prompt)
            return Data(((bracketed ? pasteStart + s + pasteEnd : s) + "\r").utf8)
        }
        var out = Data()
        let b = Array(prompt.utf8)
        var i = 0
        while i < b.count {
            guard b[i] == UInt8(ascii: "\\"), i + 1 < b.count else { out.append(b[i]); i += 1; continue }
            switch b[i + 1] {
            case UInt8(ascii: "n"): out.append(0x0A); i += 2
            case UInt8(ascii: "t"): out.append(0x09); i += 2
            case UInt8(ascii: "e"): out.append(0x1B); i += 2
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); i += 2
            case UInt8(ascii: "x"):
                if i + 3 < b.count, let v = UInt8(String(decoding: b[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) {
                    out.append(v); i += 4
                } else { out.append(b[i]); i += 1 }
            default: out.append(b[i]); i += 1
            }
        }
        return out
    }
}
