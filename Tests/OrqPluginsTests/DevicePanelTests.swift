import AppKit
import CoreMedia
import Foundation
import Testing
import VideoToolbox
import OrqCore
import OrqDevice
import OrqProtocol
@testable import OrqPlugins

/// One 64×64 baseline IDR (SPS, PPS, SEI, IDR), made once with:
/// ffmpeg -f lavfi -i testsrc=size=64x64:rate=1 -frames:v 1 -pix_fmt yuv420p -c:v libx264 -profile:v baseline \
///   -bsf:v h264_mp4toannexb -f h264 Tests/Fixtures/h264/idr-64.h264
private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/h264/idr-64.h264")

@Test func formatFromFixture() throws {
    let ps = try #require(AnnexB.parameterSets(try Data(contentsOf: fixture)))
    let f = try #require(VideoFormat.description(sps: ps.sps, pps: ps.pps))
    let d = CMVideoFormatDescriptionGetDimensions(f)
    #expect(d.width == 64 && d.height == 64)
}

@Test func decodesFixtureFrame() throws {
    let data = try Data(contentsOf: fixture)
    let ps = try #require(AnnexB.parameterSets(data))
    let format = try #require(VideoFormat.description(sps: ps.sps, pps: ps.pps))
    let idr = try #require(AnnexB.nalUnits(data).first { $0.first.map { $0 & 0x1F } == 5 })
    let sample = try #require(VideoFormat.sampleBuffer(avcc: AnnexB.avcc(Data([0, 0, 0, 1]) + idr), format: format, pts: 0))

    var session: VTDecompressionSession?
    #expect(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                         imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr)
    let s = try #require(session)
    defer { VTDecompressionSessionInvalidate(s) }
    nonisolated(unsafe) var size: (Int, Int)?
    let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        if status == noErr, let image { size = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)) }
    }
    #expect(st == noErr)
    VTDecompressionSessionWaitForAsynchronousFrames(s)
    #expect(size.map { $0 == (64, 64) } == true)
}

@Test func letterboxMapping() {
    let view = CGSize(width: 400, height: 400), video = CGSize(width: 1080, height: 2400)
    let r = videoRect(view: view, video: video)
    #expect(abs(r.minX - 110) < 0.5 && abs(r.width - 180) < 0.5 && abs(r.height - 400) < 0.5)
    let c = devicePoint(CGPoint(x: 200, y: 200), view: view, video: video)
    #expect(c?.x == 540 && c?.y == 1200)
    #expect(devicePoint(CGPoint(x: 10, y: 200), view: view, video: video) == nil)
}

@MainActor @Test func panelRegistersAndRefusesCommands() async throws {
    PluginViews.register("device", DevicePanel.self)
    let panel = Panel(id: UUID(), name: "pixel", pluginId: "device", placement: .canvas)
    let host = PanelHostContext(panel: panel, root: URL(fileURLWithPath: NSTemporaryDirectory()), workspaceId: nil,
                                call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in },
                                openStream: { _, _ throws(ProtocolError) in throw ProtocolError(code: .unavailable, message: "fake") })
    let v = try #require(PluginViews.make(panel, host: host))
    defer { v.close() }
    await #expect(throws: ProtocolError.self) { _ = try await v.handle("device.tap", [:]) }
    do { _ = try await v.handle("device.tap", [:]) } catch { #expect(error.code == .unavailable) }
}

// MARK: iOS Simulator

@Test func clickIsTap() {
    #expect(SimGesture.classify(down: CGPoint(x: 100, y: 200), up: CGPoint(x: 103, y: 202), seconds: 0.1) == .tap(x: 103, y: 202))
}

@Test func dragIsSwipe() {
    #expect(SimGesture.classify(down: CGPoint(x: 100, y: 600), up: CGPoint(x: 100, y: 200), seconds: 5)
            == .swipe(x1: 100, y1: 600, x2: 100, y2: 200, seconds: 2))
    #expect(SimGesture.classify(down: CGPoint(x: 100, y: 600), up: CGPoint(x: 100, y: 200), seconds: 0.01)
            == .swipe(x1: 100, y1: 600, x2: 100, y2: 200, seconds: 0.1))
    #expect(SimGesture.classify(down: CGPoint(x: 100, y: 200), up: CGPoint(x: 104, y: 202), seconds: 0.6)   // held: a slow swipe
            == .swipe(x1: 100, y1: 200, x2: 104, y2: 202, seconds: 0.6))
}

@Test func longPressStillTap() {
    #expect(SimGesture.classify(down: CGPoint(x: 100, y: 200), up: CGPoint(x: 105, y: 204), seconds: 0.4) == .tap(x: 105, y: 204))
}

@Test func scrollAccumulatesToSwipe() {
    let screen = CGSize(width: 390, height: 844), c = CGPoint(x: 195, y: 422)
    var a = ScrollAccumulator()
    #expect(a.flush(at: c, screen: screen) == nil)
    a.add(dx: 0, dy: -60); a.add(dx: 0, dy: -60)   // trackpad, content moving up
    #expect(a.flush(at: c, screen: screen) == .swipe(x1: 195, y1: 422, x2: 195, y2: 302, seconds: 0.3))
    #expect(a.flush(at: c, screen: screen) == nil)  // flushed: starts over
    a.add(dx: 0, dy: -1000)
    #expect(a.flush(at: c, screen: screen) == .swipe(x1: 195, y1: 422, x2: 195, y2: 422 - 844 * 0.4, seconds: 0.3))
}

/// A one-connection `ui.device` stand-in: accepts, says ok, sends `frames`, then hands back the first `in` frame.
private final class FakeDeviceSocket: @unchecked Sendable {
    let path = NSTemporaryDirectory() + "dp-\(UUID().uuidString.prefix(8)).sock"
    private let lock = NSLock()
    private var got: Data?
    var input: Data? { lock.withLock { got } }

    init(frames: [StreamFrame]) {
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(lfd, 1)
        // Typed: release builds inferred `@MainActor` for the untyped closure (as in `DevicePanel.read`) and trapped here.
        let serve: @Sendable () -> Void = { [self] in
            let c = accept(lfd, nil, nil); Darwin.close(lfd)
            defer { Darwin.close(c) }
            var buf = Data(), chunk = [UInt8](repeating: 0, count: 65536), lines = 0
            var out = try! JSONEncoder().encode(Response(id: "t", ok: true)); out.append(10)
            for f in frames { out += f.line }
            while true {
                let n = read(c, &chunk, chunk.count); guard n > 0 else { return }
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 10) {
                    let l = Data(buf[buf.startIndex..<nl]); buf = Data(buf[(nl + 1)...]); lines += 1
                    if lines == 1 { _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }; continue }   // the request
                    if case .in(let d)? = try? JSONDecoder().decode(StreamFrame.self, from: l) { lock.withLock { got = d }; return }
                }
            }
        }
        Thread(block: serve).start()
    }
}

private func jpeg(width: Int = 4, height: Int = 4) throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

@MainActor @Test func iosPanelSendsSimInput() async throws {
    try await tapThroughIOSPanel(frame: try jpeg(width: 4, height: 8), expect: .tap(x: 195, y: 422))
}

@MainActor @Test func iosPanelFollowsRotation() async throws {   // meta stays portrait; a landscape frame swaps it
    try await tapThroughIOSPanel(frame: try jpeg(width: 844, height: 390), expect: .tap(x: 422, y: 195))
}

/// iOS panel on a fake `ui.device` (meta 390×844 + `frame`); a click at the center of a 400×800 video area.
@MainActor private func tapThroughIOSPanel(frame: Data, expect: SimInput) async throws {
    let fake = FakeDeviceSocket(frames: [.deviceStatus(state: "streaming", message: nil), .videoMeta(width: 390, height: 844), .jpeg(frame)])
    let path = URL(fileURLWithPath: fake.path)
    defer { unlink(fake.path) }
    let panel = Panel(id: UUID(), name: "iphone", pluginId: "device", placement: .canvas, state: ["platform": .string("ios")])
    let host = PanelHostContext(panel: panel, root: URL(fileURLWithPath: NSTemporaryDirectory()), workspaceId: nil,
                                call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in },
                                openStream: { c, a throws(ProtocolError) in
                                    try await StreamClient.open(Request(id: "t", token: "x", command: c, args: a), path: path) })
    let v = DevicePanel(panel: panel, host: host)
    defer { v.close() }
    v.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800 + DevicePanel.footerHeight)   // video area 400×800 above the footer
    v.connect()
    func shown() -> Bool { v.view.layer?.sublayers?.contains { $0.contents != nil } == true }
    for _ in 0..<2000 where !shown() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(shown())   // the JPEG decoded and landed on a layer
    v.mouse(.down, at: CGPoint(x: 200, y: 400)); v.mouse(.up, at: CGPoint(x: 200, y: 400))
    for _ in 0..<2000 where fake.input == nil { try await Task.sleep(for: .milliseconds(10)) }
    let d = try #require(fake.input)
    let got = try JSONDecoder().decode(SimInput.self, from: d); #expect(got == expect, "\(got)")
}
