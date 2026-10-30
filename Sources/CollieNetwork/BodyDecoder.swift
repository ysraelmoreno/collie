import Compression
import Foundation

public enum BodyDecoder {
    /// The body with its Content-Encoding undone (gzip, deflate, br, identity; chained ones in reverse order).
    /// nil for an unsupported encoding, a truncated body or corrupt data.
    public static func decode(_ body: Body) -> Data? {
        guard !body.truncated else { return nil }
        let codings = (body.contentEncoding ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && $0 != "identity" }
        var data = body.data
        for c in codings.reversed() {
            switch c {
            case "gzip", "x-gzip": guard let raw = gunzipPayload(data) else { return nil }; data = raw
            case "deflate": data = zlibPayload(data)
            case "br": break
            default: return nil
            }
            guard let out = inflate(data, c == "br" ? COMPRESSION_BROTLI : COMPRESSION_ZLIB) else { return nil }
            data = out
        }
        return data
    }

    public static func prettyJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    /// Apple's COMPRESSION_ZLIB is raw deflate: strip the gzip header (RFC 1952); the 8-byte trailer is ignored.
    private static func gunzipPayload(_ d: Data) -> Data? {
        let b = Array(d)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }   // FEXTRA
        for bit: UInt8 in [8, 16] where flags & bit != 0 {   // FNAME, FCOMMENT: zero-terminated
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 2 != 0 { i += 2 }   // FHCRC
        return i < b.count ? Data(b[i...]) : nil
    }

    /// HTTP "deflate" is usually zlib-wrapped (RFC 1950) but some servers send raw deflate.
    private static func zlibPayload(_ d: Data) -> Data {
        guard d.count >= 2, d[d.startIndex] & 0x0F == 8, (UInt16(d[d.startIndex]) << 8 | UInt16(d[d.startIndex + 1])) % 31 == 0 else { return d }
        return d.dropFirst(2)
    }

    private static func inflate(_ input: Data, _ algorithm: compression_algorithm) -> Data? {
        let s = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { s.deallocate() }
        guard compression_stream_init(s, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(s) }
        let chunk = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var out = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            s.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buf)
            s.pointee.src_size = src.count
            while true {
                s.pointee.dst_ptr = buf; s.pointee.dst_size = chunk
                let status = compression_stream_process(s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(buf, count: chunk - s.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK where s.pointee.dst_size == 0 || s.pointee.src_size > 0: continue
                default: return nil   // error, or input ran out before the end of the stream
                }
            }
        }
    }
}
