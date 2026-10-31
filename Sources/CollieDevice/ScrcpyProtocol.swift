import Foundation

public enum ScrcpyError: Error, Equatable, Sendable { case packetTooLarge(Int) }  // > 16 MiB

/// scrcpy v5.0.1 wire protocol (client side): video packets in, control messages out. All integers big-endian.
public enum Scrcpy {
    public static let version = "5.0.1"
    public static let remoteJar = "/data/local/tmp/collie-scrcpy-server.jar"
    static let maxPacket = 16 * 1024 * 1024

    /// What the video socket carries after its u32 codec id.
    public enum Event: Equatable, Sendable {
        /// A capture session starts (at startup and after a rotation): the video size until the next one.
        case session(width: UInt32, height: UInt32)
        case packet(Packet)
    }
    public struct Packet: Equatable, Sendable { public var pts: UInt64; public var config: Bool; public var key: Bool; public var data: Data }

    /// Incremental: feed bytes, get whole events. Every header is 12 bytes. Bit 63 set: session packet (u32 flags, u32 width,
    /// u32 height, no body). Clear: media packet (u64: bit 62 config, bit 61 key, 61-bit pts; u32 len, then the body).
    public struct PacketReader: Sendable {
        private var buf = [UInt8]()
        public init() {}
        public mutating func feed(_ d: Data) throws(ScrcpyError) -> [Event] {
            buf.append(contentsOf: d)
            var out: [Event] = []
            var pos = 0
            while buf.count - pos >= 12 {
                let flags = be(buf, pos, 8)
                if flags >> 63 == 1 {
                    out.append(.session(width: UInt32(be(buf, pos + 4, 4)), height: UInt32(be(buf, pos + 8, 4))))
                    pos += 12
                    continue
                }
                let len = Int(be(buf, pos + 8, 4))
                if len > Scrcpy.maxPacket { throw .packetTooLarge(len) }
                guard buf.count - pos - 12 >= len else { break }
                out.append(.packet(Packet(pts: flags & ~(7 << 61),
                                          config: flags >> 62 & 1 == 1, key: flags >> 61 & 1 == 1,
                                          data: Data(buf[(pos + 12)..<(pos + 12 + len)]))))
                pos += 12 + len
            }
            buf.removeFirst(pos)
            return out
        }
    }

    /// The u32 codec id that opens the video socket (0 or 1: the device disabled the stream).
    public static func codecId(_ d: Data) -> UInt32? {
        guard d.count == 4 else { return nil }
        return UInt32(be([UInt8](d), 0, 4))
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
         "max_size=1280", "max_fps=60", "video_bit_rate=4000000", "send_device_meta=false", "send_dummy_byte=true",
         "send_stream_meta=true", "send_frame_meta=true", "clipboard_autosync=false"]
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
