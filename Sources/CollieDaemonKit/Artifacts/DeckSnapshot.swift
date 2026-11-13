import Foundation

/// One slide of a deck snapshot (the app's `deck.snapshot`): slide-relative nodes, root at 0,0.
struct DeckSlide: Decodable, Sendable {
    var index: Int
    var w: Double
    var h: Double
    var background: String?
    var notes: String?
    var pseudo: Int?
    var root: DOMNode
}

struct DeckSnapshot: Decodable, Sendable {
    var title: String
    var slides: [DeckSlide]
    var blocked: [String]
    var truncated: Bool
}

enum CSSColor {
    /// Computed-style `rgb()`/`rgba()` → `RRGGBB` + DrawingML alpha (0…100000); nil when unparsable or fully transparent.
    static func parse(_ css: String) -> (hex: String, alpha: Int)? {
        guard let c = HTMLImport.color(css), c.alpha > 0 else { return nil }
        return (String(c.hex.dropFirst()), Int((c.alpha * 100_000).rounded()))
    }
}

/// CSS px → EMU at `scale` EMU/px, clamped to ±(2^31−1); non-finite → 0.
func emu(_ px: Double, scale: Double) -> Int {
    let v = (px * scale).rounded()
    guard v.isFinite else { return 0 }
    let limit = Double(Int32.max)
    return Int(min(max(v, -limit), limit))
}

/// Escapes for XML text and attribute values, dropping characters XML 1.0 forbids.
func xmlEscape(_ s: String) -> String {
    var out = ""
    out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
    for u in s.unicodeScalars {
        switch u {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        case "\t", "\n", "\r": out.unicodeScalars.append(u)
        default:
            let v = u.value
            if (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || v >= 0x10000 { out.unicodeScalars.append(u) }
        }
    }
    return out
}
