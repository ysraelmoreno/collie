import Foundation

/// H.264 Annex-B helpers for feeding VideoToolbox.
public enum AnnexB {
    /// NAL units without start codes (00 00 01 / 00 00 00 01); trailing zero bytes trimmed.
    public static func nalUnits(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [Int] = []  // index of first byte after each 00 00 01
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        return starts.enumerated().map { n, s in
            var e = n + 1 < starts.count ? starts[n + 1] - 3 : b.count
            while e > s, b[e - 1] == 0 { e -= 1 }
            return Data(b[s..<e])
        }.filter { !$0.isEmpty }
    }

    /// First SPS (NAL type 7) and PPS (type 8).
    public static func parameterSets(_ d: Data) -> (sps: Data, pps: Data)? {
        let n = nalUnits(d)
        guard let s = n.first(where: { $0.first.map { $0 & 0x1F } == 7 }), let p = n.first(where: { $0.first.map { $0 & 0x1F } == 8 }) else { return nil }
        return (s, p)
    }

    /// Each NAL prefixed with its u32 big-endian length (AVCC / VideoToolbox sample format).
    public static func avcc(_ d: Data) -> Data {
        nalUnits(d).reduce(into: Data()) { out, n in
            withUnsafeBytes(of: UInt32(n.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(n)
        }
    }
}
