import Foundation

public enum ScrcpyError: Error, Equatable, Sendable { case packetTooLarge(Int) }  // > 16 MiB

/// scrcpy v3.3.1 wire protocol (client side): video packets in, control messages out. All integers big-endian.
public enum Scrcpy {
    public static let version = "3.3.1"
    public static let remoteJar = "/data/local/tmp/collie-scrcpy-server.jar"
    static let maxPacket = 16 * 1024 * 1024

    public struct CodecMeta: Equatable, Sendable { public var codec: UInt32; public var width: UInt32; public var height: UInt32 }
    public struct Packet: Equatable, Sendable { public var pts: UInt64; public var config: Bool; public var key: Bool; public var data: Data }

    /// Incremental: feed bytes, get whole packets (12-byte header: u64 pts_and_flags — bit63 config, bit62 key — then u32 len).
    public struct PacketReader: Sendable {
        private var buf = [UInt8]()
        public init() {}
        public mutating func feed(_ d: Data) throws(ScrcpyError) -> [Packet] {
            buf.append(contentsOf: d)
            var out: [Packet] = []
            var pos = 0
            while buf.count - pos >= 12 {
                let flags = be(buf, pos, 8)
                let len = Int(be(buf, pos + 8, 4))
                if len > Scrcpy.maxPacket { throw .packetTooLarge(len) }
                guard buf.count - pos - 12 >= len else { break }
                out.append(Packet(pts: flags & ~(3 << 62),
                                  config: flags >> 63 & 1 == 1, key: flags >> 62 & 1 == 1,
                                  data: Data(buf[(pos + 12)..<(pos + 12 + len)])))
                pos += 12 + len
            }
            buf.removeFirst(pos)
            return out
        }
    }

    public static func codecMeta(_ d: Data) -> CodecMeta? {
        guard d.count == 12 else { return nil }
        let b = [UInt8](d)
        return CodecMeta(codec: UInt32(be(b, 0, 4)), width: UInt32(be(b, 4, 4)), height: UInt32(be(b, 8, 4)))
    }

    public enum Action: UInt8, Sendable { case down = 0, up = 1, move = 2 }

    /// Touch (type 2, 32 bytes). Mirrors the official client: down/move carry primary button + full pressure, up releases.
    public static func touch(_ a: Action, x: Int32, y: Int32, width: UInt16, height: UInt16, pointerId: UInt64 = .max) -> Data {
        var d = Data([2, a.rawValue])
        d.put(pointerId); d.put(x); d.put(y); d.put(width); d.put(height)
        d.put(a == .up ? UInt16(0) : 0xFFFF)
        d.put(UInt32(a == .move ? 0 : 1))   // action_button: PRIMARY on down/up
        d.put(UInt32(a == .up ? 0 : 1))     // buttons held
        return d
    }

    /// Scroll (type 3, 21 bytes). h/v clamped to ±16, encoded as i16 fixed point of v/16.
    public static func scroll(x: Int32, y: Int32, width: UInt16, height: UInt16, h: Float, v: Float) -> Data {
        func fp(_ f: Float) -> Int16 {
            let n = max(-1, min(1, f / 16))
            return n >= 1 ? 0x7FFF : Int16(n * 32768)
        }
        var d = Data([3])
        d.put(x); d.put(y); d.put(width); d.put(height); d.put(fp(h)); d.put(fp(v)); d.put(UInt32(0))
        return d
    }

    /// Key (type 0, 14 bytes).
    public static func key(_ a: Action, keycode: Int32, repeat: Int32 = 0, meta: Int32 = 0) -> Data {
        var d = Data([0, a.rawValue])
        d.put(keycode); d.put(`repeat`); d.put(meta)
        return d
    }

    /// Text (type 1): u32 length + UTF-8, cut at 300 bytes on a scalar boundary.
    public static func text(_ s: String) -> Data {
        var bytes = Data()
        for u in s.unicodeScalars {
            let enc = Data(String(u).utf8)
            if bytes.count + enc.count > 300 { break }
            bytes.append(enc)
        }
        var d = Data([1])
        d.put(UInt32(bytes.count))
        return d + bytes
    }

    public static func backOrScreenOn(_ a: Action) -> Data { Data([4, a.rawValue]) }
    public static func resetVideo() -> Data { Data([17]) }

    /// `app_process` argv (after `adb shell`) to start the server in forward-tunnel, raw-ish h264 mode.
    public static func serverArgs(scid: String) -> [String] {
        ["CLASSPATH=\(remoteJar)", "app_process", "/", "com.genymobile.scrcpy.Server", version, "scid=\(scid)",
         "log_level=info", "tunnel_forward=true", "audio=false", "control=true", "cleanup=true", "video_codec=h264",
         "max_size=1280", "max_fps=30", "video_bit_rate=4000000", "send_device_meta=false", "send_dummy_byte=true",
         "send_codec_meta=true", "send_frame_meta=true", "clipboard_autosync=false"]
    }
}

private func be(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
    b[at..<(at + n)].reduce(0) { $0 << 8 | UInt64($1) }
}

private extension Data {
    mutating func put<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }
}
