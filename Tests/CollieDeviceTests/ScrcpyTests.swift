import Testing
import Foundation
@testable import CollieDevice

private func bytes(_ a: [UInt8]) -> Data { Data(a) }

@Test func packetReaderSplitsAcrossChunks() throws {
    func pkt(flags: UInt64, len: Int, fill: UInt8) -> Data {
        var d = Data()
        withUnsafeBytes(of: flags.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(len).bigEndian) { d.append(contentsOf: $0) }
        d.append(Data(repeating: fill, count: len))
        return d
    }
    // session 1080×2400 as the server writes it, then config (bit 62), then key (bit 61) with pts 7
    let session = bytes([0x80, 0, 0, 0, 0, 0, 4, 0x38, 0, 0, 9, 0x60])
    let all = session + pkt(flags: 1 << 62, len: 20, fill: 1) + pkt(flags: (1 << 61) | 7, len: 50, fill: 2)
    var r = Scrcpy.PacketReader()
    var out: [Scrcpy.Event] = []
    var i = 0
    while i < all.count {
        out += try r.feed(all.subdata(in: i..<min(i + 7, all.count)))
        i += 7
    }
    #expect(out.count == 3)
    #expect(out[0] == .session(width: 1080, height: 2400))
    guard case .packet(let c) = out[1], case .packet(let k) = out[2] else { Issue.record("\(out)"); return }
    #expect(c.config && !c.key && c.data.count == 20)
    #expect(!k.config && k.key && k.pts == 7 && k.data.count == 50)
}

@Test func packetTooLargeThrows() {
    var h = Data(repeating: 0, count: 8)
    withUnsafeBytes(of: UInt32(16 * 1024 * 1024 + 1).bigEndian) { h.append(contentsOf: $0) }
    var r = Scrcpy.PacketReader()
    #expect(throws: ScrcpyError.packetTooLarge(16 * 1024 * 1024 + 1)) { try r.feed(h) }
}

@Test func codecIdParses() {
    #expect(Scrcpy.codecId(bytes([0x68, 0x32, 0x36, 0x34])) == 0x68323634)
    #expect(Scrcpy.codecId(Data(count: 3)) == nil)
}

@Test func touchLayout() {
    let d = Scrcpy.touch(.down, x: 540, y: 1210, width: 1080, height: 2400)
    #expect(d == bytes([2, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                        0, 0, 2, 0x1C, 0, 0, 4, 0xBA, 4, 0x38, 9, 0x60,
                        0xFF, 0xFF, 0, 0, 0, 1, 0, 0, 0, 1]))
    let u = Scrcpy.touch(.up, x: 1, y: 2, width: 3, height: 4, pointerId: 5)
    #expect(u.count == 32 && u[1] == 1 && u[9] == 5 && u[22] == 0 && u[23] == 0 && u[27] == 1 && u[31] == 0)
}

@Test func scrollLayout() {
    let d = Scrcpy.scroll(x: 10, y: 20, width: 1080, height: 2400, h: 0, v: -1)
    // v = -1/16 of range -> -(0x7FFF/16) = -2048 -> 0xF800
    #expect(d == bytes([3, 0, 0, 0, 10, 0, 0, 0, 20, 4, 0x38, 9, 0x60, 0, 0, 0xF8, 0x00, 0, 0, 0, 0]))
    let c = Scrcpy.scroll(x: 0, y: 0, width: 1, height: 1, h: 99, v: -99)
    #expect(c[13] == 0x7F && c[14] == 0xFF && c[15] == 0x80 && c[16] == 0x00)
}

@Test func keyLayout() {
    #expect(Scrcpy.key(.down, keycode: 66) == bytes([0, 0, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0]))
    #expect(Scrcpy.key(.up, keycode: 4, repeat: 1, meta: 2).count == 14)
}

@Test func textLayout() {
    #expect(Scrcpy.text("hi") == bytes([1, 0, 0, 0, 2, 0x68, 0x69]))
}

@Test func textTruncatesOnCharacterBoundary() {
    let d = Scrcpy.text(String(repeating: "a", count: 299) + "é")
    #expect(d.count == 5 + 299)
    #expect(Scrcpy.text(String(repeating: "a", count: 400)).count == 5 + 300)
}

@Test func resetVideoAndBackLayout() {
    #expect(Scrcpy.resetVideo() == bytes([17]))
    #expect(Scrcpy.backOrScreenOn(.down) == bytes([4, 0]))
}

@Test func serverArgsShape() {
    let a = Scrcpy.serverArgs(scid: "0000abcd")
    #expect(a[0] == "CLASSPATH=/data/local/tmp/collie-scrcpy-server.jar")
    #expect(a[4] == "5.0.1" && a[5] == "scid=0000abcd")
    #expect(a.contains("tunnel_forward=true") && a.contains("send_dummy_byte=true") && a.contains("send_stream_meta=true"))
}

@Test func keyNames() {
    #expect(AndroidKeys.keycode(named: "Enter") == 66)
    #expect(AndroidKeys.keycode(named: "back") == 4)
    #expect(AndroidKeys.keycode(named: "ArrowLeft") == 21)
    #expect(AndroidKeys.keycode(named: "AppSwitch") == 187)
    #expect(AndroidKeys.keycode(named: "keycode_enter") == 66)
    #expect(AndroidKeys.keycode(named: "KEYCODE_VOLUME_UP") == 24)
    #expect(AndroidKeys.keycode(named: "66") == 66)
    #expect(AndroidKeys.keycode(named: "Nope") == nil)
    #expect(AndroidKeys.keycode(macKeyCode: 36) == 66)
    #expect(AndroidKeys.keycode(macKeyCode: 0) == nil)
}
