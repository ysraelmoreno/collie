import Foundation

/// Splits `axe stream-video --format mjpeg` stdout (an HTTP/1.1 preamble, then multipart parts
/// with `Content-Length` headers around back-to-back JPEGs) into whole JPEG frames.
/// Walks JPEG markers so an EXIF thumbnail's own FFD8…FFD9 doesn't end a frame early.
public struct MJPEGReader: Sendable {
    public static let maxFrame = 8 << 20
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ d: Data) -> [Data] {
        buf.append(contentsOf: d)
        var out: [Data] = []
        while true {
            guard let soi = Self.findSOI(buf) else { buf = buf.last == 0xFF ? [0xFF] : []; break }
            if soi > 0 { buf.removeFirst(soi) }
            switch Self.frameEnd(buf) {
            case .complete(let n): out.append(Data(buf[0..<n])); buf.removeFirst(n)
            case .incomplete:
                if buf.count <= Self.maxFrame { return out }
                buf.removeFirst(2)   // oversized: drop it, resync on the next SOI
            case .bad: buf.removeFirst(2)
            }
        }
        return out
    }

    private static func findSOI(_ b: [UInt8]) -> Int? {
        var i = 0
        while i + 1 < b.count { if b[i] == 0xFF && b[i + 1] == 0xD8 { return i }; i += 1 }
        return nil
    }

    private enum End { case complete(Int), incomplete, bad }

    /// `b` starts at SOI. ponytail: re-walks from the start on each feed; fine for ~100 KB frames.
    private static func frameEnd(_ b: [UInt8]) -> End {
        var i = 2
        var scan = false
        while i < b.count {
            if b[i] != 0xFF { if scan { i += 1; continue } else { return .bad } }
            guard i + 1 < b.count else { return .incomplete }
            let m = b[i + 1]
            switch m {
            case 0xD9: return .complete(i + 2)
            case 0xFF: i += 1                                  // fill byte
            case 0x00, 0xD0...0xD7: i += 2                     // stuffed / restart (inside entropy data)
            case 0x01, 0xD8: if scan { i += 2 } else { return .bad }
            default:
                guard i + 3 < b.count else { return .incomplete }
                let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
                if len < 2 { return .bad }
                if m == 0xDA { scan = true }
                i += 2 + len
            }
        }
        return .incomplete
    }
}
