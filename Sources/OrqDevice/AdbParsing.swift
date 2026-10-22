import Foundation
import OrqProtocol

public struct AdbDevice: Equatable, Sendable, Codable { public var serial: String; public var state: String; public var model: String?; public var product: String? }

public enum AdbParsing {
    /// `emulator -list-avds` output: one name per line; skips blanks and emulator log lines (`INFO    | ...`); no duplicates.
    public static func avds(_ out: String) -> [String] {
        var seen = Set<String>()
        return out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" | ") && seen.insert($0).inserted }
    }

    /// `adb devices -l` output; skips the header and "* daemon ..." lines.
    public static func devices(_ out: String) -> [AdbDevice] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 2, !line.hasPrefix("*"), t[0] != "List" else { return nil }
            func attr(_ k: String) -> String? { t.dropFirst(2).first { $0.hasPrefix(k + ":") }.map { String($0.dropFirst(k.count + 1)) } }
            return AdbDevice(serial: t[0], state: t[1], model: attr("model"), product: attr("product"))
        }
    }

    /// Width/height from the PNG IHDR chunk.
    public static func pngSize(_ d: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](d.prefix(24))
        guard b.count == 24, b[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], b[12..<16] == [0x49, 0x48, 0x44, 0x52] else { return nil }
        func u32(_ i: Int) -> Int { b[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) } }
        return (u32(16), u32(20))
    }

    /// Argument for `adb shell input text`: single-quoted, space → `%s`. ASCII only; a literal `%s` cannot be typed (no escape exists).
    public static func inputTextArg(_ s: String) throws(ProtocolError) -> String {
        guard s.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            throw ProtocolError(code: .invalidArgs, message: "device.text supports ASCII only; use device.key or the panel for other characters")
        }
        guard !s.contains("%s") else {
            throw ProtocolError(code: .invalidArgs, message: "device.text cannot type a literal %s; use the panel")
        }
        let e = s.replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "'", with: "'\\''")
        return "'\(e)'"
    }
}
