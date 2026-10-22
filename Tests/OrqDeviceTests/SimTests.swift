import Testing
import Foundation
import CoreGraphics
import OrqProtocol
@testable import OrqDevice

private let booted = "000BA2AE-04FB-42B0-A7CE-1CC4FCC3C163"

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../Fixtures/ios/\(name)").standardized
    return try Data(contentsOf: url)
}

@Suite struct SimTests {
    @Test func simctlParsesDevices() throws {
        let ds = SimCtl.devices(try fixture("devices.json"))
        let d = try #require(ds.first { $0.udid == booted })
        #expect(d.state == "booted" && d.name == "iPhone 16e" && d.runtime.hasPrefix("iOS "))
        #expect(d.runtime == "iOS 26.3")
        let extra = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"A","name":"Old","state":"Shutdown","isAvailable":true},{"udid":"B","name":"Gone","state":"Shutdown","isAvailable":false}]}}"#
        #expect(SimCtl.devices(Data(extra.utf8)).map(\.udid) == ["A"])
        let watch = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"W","name":"Watch","state":"Booted","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"A","name":"Old","state":"Shutdown","isAvailable":true}]}}"#
        #expect(SimCtl.devices(Data(watch.utf8)).map(\.udid) == ["A"])   // only iOS runtimes
        #expect(SimCtl.devices(Data("nope".utf8)).isEmpty)
    }

    @Test func axeTreeCompacts() throws {
        let r = AXeTree.parse(try fixture("describe-ui.json"))
        #expect(r.screen == CGSize(width: 390, height: 844) && !r.truncated)
        #expect(r.nodes.first?.ref == "e1" && r.nodes.map(\.ref) == (1...r.nodes.count).map { "e\($0)" })
        let b = try #require(r.nodes.first { $0.cls == "Button" && $0.text == "Mapas" })
        #expect(b.clickable && b.id == "Mapas" && b.bounds.width > 100)
        #expect(b.center.x == Int(b.bounds.midX))
        #expect(UITree.lines(r.nodes).contains("Button \"Mapas\""))
    }

    @Test func axeTreeCaps() throws {
        let r = AXeTree.parse(try fixture("describe-ui.json"), cap: 3)
        #expect(r.nodes.count == 3 && r.truncated)
        #expect(AXeTree.parse(Data("[]".utf8)).nodes.isEmpty)
    }

    @Test func mjpegSplitsAcrossChunks() throws {
        let d = try fixture("stream.mjpeg")
        var whole = MJPEGReader()
        let all = whole.feed(d)
        #expect(all.count == 3)
        var r = MJPEGReader(); var out: [Data] = []
        var i = 0
        while i < d.count { out += r.feed(d.subdata(in: i..<min(i + 1000, d.count))); i += 1000 }
        #expect(out == all)
        for f in out { #expect(Array(f.prefix(2)) == [0xFF, 0xD8] && Array(f.suffix(2)) == [0xFF, 0xD9]) }
    }

    @Test func mjpegSkipsGarbage() {
        let f = Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 1, 2, 3, 0xFF, 0x00, 4, 0xFF, 0xD9])
        var r = MJPEGReader()
        let junk = Data("HTTP/1.1 200 OK\r\n\r\n--b\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        let out = r.feed(junk + f + Data("\r\n--b\r\n".utf8) + f)
        #expect(out == [f, f])
    }

    @Test func mjpegIgnoresEmbeddedThumbnail() {
        // APP1 payload holds its own FFD8…FFD9 (EXIF thumbnail); SOS data has FF00 stuffing before the real EOI.
        let app1: [UInt8] = [0xFF, 0xD8, 9, 9, 0xFF, 0xD9, 8]
        var f: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x00, UInt8(app1.count + 2)] + app1
        f += [0xFF, 0xDA, 0x00, 0x02, 1, 0xFF, 0x00, 2, 0xFF, 0xD0, 3, 0xFF, 0xD9]
        let frame = Data(f)
        let stream = Data("HTTP/1.1 200 OK\r\n\r\n--b\r\nContent-Length: \(f.count)\r\n\r\n".utf8) + frame + Data("\r\n--b\r\n".utf8)
        var r = MJPEGReader(); var out: [Data] = []
        var i = 0
        while i < stream.count { out += r.feed(stream.subdata(in: i..<min(i + 7, stream.count))); i += 7 }
        #expect(out == [frame])
    }

    @Test func mjpegDropsOversized() {
        let ok = Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 7, 0xFF, 0xD9])
        var big = Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02]); big.append(Data(repeating: 0x41, count: 9 << 20))
        var r = MJPEGReader()
        #expect(r.feed(big).isEmpty)
        #expect(r.feed(ok) == [ok])
    }

    @Test func simInputRoundTrip() throws {
        let cases: [SimInput] = [.tap(x: 1.5, y: 2), .swipe(x1: 1, y1: 2, x2: 3, y2: 4, seconds: 0.3), .text("hi"), .key(40), .button("home")]
        for c in cases {
            let back = try JSONDecoder().decode(SimInput.self, from: JSONEncoder().encode(c))
            #expect(back == c)
        }
    }

    @Test func simTextValidation() throws {
        try SimText.validate("ola mundo; $(rm) 'x'\n")
        for bad in ["ação", "😀"] {
            #expect(throws: ProtocolError(code: .invalidArgs, message: "device.text on iOS supports US keyboard characters only; use the panel")) {
                try SimText.validate(bad)
            }
        }
    }

    @Test func iosKeyNames() {
        let t: [(String, UInt8)] = [("Enter", 40), ("escape", 41), ("Backspace", 42), ("tab", 43), ("Space", 44),
                                    ("ArrowRight", 79), ("ArrowLeft", 80), ("arrowdown", 81), ("ArrowUp", 82), ("255", 255), ("0", 0)]
        for (n, u) in t { #expect(IOSKeys.usage(named: n) == u) }
        #expect(IOSKeys.usage(named: "back") == nil && IOSKeys.usage(named: "256") == nil)
        #expect(IOSKeys.button(named: "home") == "home" && IOSKeys.button(named: "Power") == "lock" && IOSKeys.button(named: "Lock") == "lock")
        #expect(IOSKeys.button(named: "back") == nil)
        #expect(IOSKeys.usage(macKeyCode: 36) == 40 && IOSKeys.usage(macKeyCode: 51) == 42 && IOSKeys.usage(macKeyCode: 117) == 76)
        #expect(IOSKeys.usage(macKeyCode: 126) == 82 && IOSKeys.usage(macKeyCode: 0) == nil)
    }

    @Test func ipsCrashMatchesUdid() throws {
        let ips = try fixture("crash.ips")
        let e = try #require(IPSCrash.parse(ips, udid: booted))
        #expect(e.package == "com.example.foo" && e.text.contains("EXC_BREAKPOINT"))
        #expect(IPSCrash.parse(ips, udid: "OTHER") == nil)
        let other = String(decoding: ips, as: UTF8.self).replacingOccurrences(of: "\"bug_type\":\"309\"", with: "\"bug_type\":\"298\"")
        #expect(IPSCrash.parse(Data(other.utf8), udid: booted) == nil)
    }
}
