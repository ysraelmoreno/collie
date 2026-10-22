import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import OrqCore
import OrqDevice
import OrqProtocol
import OrqTheme
import SwiftUI

/// H.264 (scrcpy, Annex B) → what `AVSampleBufferDisplayLayer` takes.
struct VideoFormat {
    static func description(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var f: CMFormatDescription?
        let st = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                guard let s = s.bindMemory(to: UInt8.self).baseAddress, let p = p.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: [s, p],
                                                                           parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                                                                           formatDescriptionOut: &f)
            }
        }
        return st == noErr ? f : nil
    }

    /// One AVCC access unit, shown as soon as it decodes (live view: no clock).
    static func sampleBuffer(avcc: Data, format: CMVideoFormatDescription, pts: UInt64) -> CMSampleBuffer? {
        guard !avcc.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
              avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                   dataLength: avcc.count) }) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(clamping: pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

/// Where a `video`-sized picture lands in `view` (aspect fit, centered).
func videoRect(view: CGSize, video: CGSize) -> CGRect {
    guard video.width > 0, video.height > 0 else { return .zero }
    return AVMakeRect(aspectRatio: video, insideRect: CGRect(origin: .zero, size: view))
}

/// A view point (top-left origin) in video pixels; nil outside the picture.
func devicePoint(_ p: CGPoint, view: CGSize, video: CGSize) -> (x: Int32, y: Int32)? {
    let r = videoRect(view: view, video: video)
    guard r.width > 0, r.contains(p) else { return nil }
    return (Int32((p.x - r.minX) / r.width * video.width), Int32((p.y - r.minY) / r.height * video.height))
}

/// iOS Simulator mouse gesture (in points): a short, nearly still press is a tap; anything else one swipe on release.
enum SimGesture {
    static func classify(down: CGPoint, up: CGPoint, seconds: Double) -> SimInput {
        if hypot(up.x - down.x, up.y - down.y) < 8 && seconds < 0.5 { return .tap(x: up.x, y: up.y) }
        return .swipe(x1: down.x, y1: down.y, x2: up.x, y2: up.y, seconds: min(max(seconds, 0.1), 2))
    }
}

/// Scroll deltas (points; the panel scales wheel lines ×10) summed until the scroll pauses, then one swipe from the
/// center the way the content moved, at most 40% of the screen.
struct ScrollAccumulator {
    private var dx = 0.0, dy = 0.0
    mutating func add(dx: Double, dy: Double) { self.dx += dx; self.dy += dy }
    mutating func flush(at center: CGPoint, screen: CGSize) -> SimInput? {
        defer { dx = 0; dy = 0 }
        guard dx != 0 || dy != 0 else { return nil }
        let mx = screen.width * 0.4, my = screen.height * 0.4
        return .swipe(x1: center.x, y1: center.y, x2: center.x + min(max(dx, -mx), mx), y2: center.y + min(max(dy, -my), my), seconds: 0.3)
    }
}

/// Latest decoded JPEG: the reader thread fills it, main takes it. One main hop per burst, never one per frame.
private final class FrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    /// true = it was empty (the caller schedules a `take`).
    func put(_ i: CGImage) -> Bool { lock.withLock { defer { image = i }; return image == nil } }
    func take() -> CGImage? { lock.withLock { defer { image = nil }; return image } }
}

/// The Device plug-in's view: the phone's screen from `ui.device` (H.264 → `AVSampleBufferDisplayLayer`) and input back
/// as scrcpy control messages. iOS Simulator panels (`state["platform"] == "ios"`) get whole JPEGs and send `SimInput`
/// JSON (points) instead. Agent commands (`device.*`) run in the daemon, not here. The stream is open while the view
/// is in a window (culled or closed: the daemon ends the session 5 s after its last viewer).
@MainActor public final class DevicePanel: PluginPanelView {
    let panel: Panel
    let host: PanelHostContext
    let ios: Bool
    private let screen: Screen
    private var stream: StreamClient?
    private var gen = 0            // bumped per connect/disconnect: a stale reader or open never touches state
    private var closed = false
    private var retried = false    // one silent reconnect when the session ended as we joined
    private var format: CMVideoFormatDescription?
    private var videoSize = CGSize.zero
    private var needKey = false
    private var touching = false
    private let sendQueue = DispatchQueue(label: "orq.device.send")
    private var pressed: (at: CGPoint, time: ContinuousClock.Instant)?   // iOS: where the mouse went down
    private var scrolled = ScrollAccumulator()
    private var scrollTick = 0

    public var view: NSView { screen }
    /// The footer under the video (buttons row 52 + device/transport line ~26 + borders, with room): fixed, so the
    /// video area and the touch mapping never depend on font metrics.
    static let footerHeight: CGFloat = 86

    public required init(panel: Panel, host: PanelHostContext) {
        self.panel = panel; self.host = host
        ios = panel.state["platform"] == .string("ios")
        let serial: String = if case .string(let v)? = panel.state["serial"] { v } else { "" }
        screen = Screen(ios: ios, serial: serial)
        screen.owner = self
    }

    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .unavailable, message: "device commands run in the daemon")
    }

    public func close() {
        closed = true; disconnect()
        screen.display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        screen.image.contents = nil
    }

    // MARK: stream

    fileprivate func windowChanged() { if screen.window != nil { connect() } else { disconnect() } }

    fileprivate func reconnect() { disconnect(); connect() }

    func connect() {
        guard !closed, stream == nil else { return }
        gen += 1
        let g = gen, open = host.openStream, id = panel.id
        screen.status("Conectando…", retry: false)
        Task { [weak self] in
            do throws(ProtocolError) {
                let s = try await open("ui.device", ["panel": .string(id.uuidString)])
                guard let self, self.gen == g else { s.close(); return }
                self.stream = s
                let slot = FrameSlot()
                Self.read(s, slot) { [weak self] f in self?.frame(f, g) } show: { [weak self] in
                    guard let self, self.gen == g, let i = slot.take() else { return }
                    // the meta (points) comes once, at session start: follow a rotation by the frame's orientation
                    let v = self.videoSize
                    if (i.width > i.height) != (v.width > v.height) { self.videoSize = CGSize(width: v.height, height: v.width) }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.screen.image.contents = i
                    CATransaction.commit()
                }
            } catch {
                guard let self, self.gen == g else { return }
                self.screen.status(error.message, retry: true)
            }
        }
    }

    private func disconnect() {
        gen += 1
        stream?.close(); stream = nil
        touching = false; pressed = nil
    }

    /// Read on its own thread (long-lived blocking read, as `DaemonClient` does for events); frames hop to main in order.
    /// nil = the stream ended. JPEGs decode here into `slot` and main shows the newest (`show`).
    private nonisolated static func read(_ s: StreamClient, _ slot: FrameSlot, _ deliver: @escaping @MainActor @Sendable (StreamFrame?) -> Void,
                                         show: @escaping @MainActor @Sendable () -> Void) {
        // Typed on purpose: release (whole-module) builds inferred `@MainActor` for an untyped closure here, and its
        // executor check trapped on this thread at the first iOS frame.
        let loop: @Sendable () -> Void = {
            while let f = try? s.nextBlocking(timeoutSeconds: 1e9) {
                if case .jpeg(let d) = f {
                    guard let src = CGImageSourceCreateWithData(d as CFData, nil),
                          let i = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    else { continue }
                    if slot.put(i) { DispatchQueue.main.async { MainActor.assumeIsolated { show() } } }
                    continue
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver(f) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(nil) } }
        }
        Thread(block: loop).start()
    }

    // ponytail: AnnexB → sample buffer runs on main (~30 small packets/s); move to the reader thread if it shows up in profiles
    private func frame(_ f: StreamFrame?, _ g: Int) {
        guard g == gen else { return }
        switch f {
        case nil:   // closed by the daemon (after `ended`/`error`, or it went away)
            stream = nil; touching = false; pressed = nil
            if !screen.hasStatus { screen.status("Aparelho desconectado", retry: true) }
        case .deviceStatus(let state, let message)?:
            switch state {
            case "connecting": screen.status("Conectando…", retry: false)
            case "streaming": screen.status(nil, retry: false); retried = false
            case "ended" where message == nil && !retried:   // ended as we joined: the next viewer gets a new session
                retried = true
                Task { [weak self] in self?.reconnect() }
            case "ended": screen.status("Aparelho desconectado", retry: true)
            default: screen.status(message ?? "Erro no aparelho", retry: true)
            }
        case .videoMeta(let w, let h)?:   // iOS: the screen in points (no SPS follows)
            if videoSize == .zero || ios { videoSize = CGSize(width: Int(w), height: Int(h)) }
        case .video(let d, let pts, let config, let key)?:
            if config {   // SPS/PPS: a new format (also after a rotation); the next keyframe starts it
                guard let ps = AnnexB.parameterSets(d), let f = VideoFormat.description(sps: ps.sps, pps: ps.pps) else { return }
                format = f
                let dim = CMVideoFormatDescriptionGetDimensions(f)
                videoSize = CGSize(width: Int(dim.width), height: Int(dim.height))
                needKey = true
                return
            }
            let r = screen.display.sampleBufferRenderer
            if r.status == .failed { r.flush(); needKey = true }
            if needKey { guard key else { return }; needKey = false }
            guard let format, let sb = VideoFormat.sampleBuffer(avcc: AnnexB.avcc(d), format: format, pts: pts) else { return }
            r.enqueue(sb)
        default: break
        }
    }

    // MARK: input

    private func send(_ messages: Data...) {
        guard let s = stream else { return }
        sendQueue.async { for m in messages { try? s.sendBlocking(.in(m), timeoutSeconds: 2) } }
    }

    private var size: (w: UInt16, h: UInt16) { (UInt16(clamping: Int(videoSize.width)), UInt16(clamping: Int(videoSize.height))) }

    private func send(_ input: SimInput) { if let d = try? JSONEncoder().encode(input) { send(d) } }

    func mouse(_ a: Scrcpy.Action, at p: CGPoint) {
        let area = screen.videoArea.size
        var p = p
        if a != .down {   // a drag that leaves the picture stays on its edge
            guard touching else { return }
            let r = videoRect(view: area, video: videoSize)
            p = CGPoint(x: min(max(p.x, r.minX), r.maxX - 0.5), y: min(max(p.y, r.minY), r.maxY - 0.5))
        }
        guard let d = devicePoint(p, view: area, video: videoSize) else { return }
        touching = a != .up
        guard ios else { return send(Scrcpy.touch(a, x: d.x, y: d.y, width: size.w, height: size.h)) }
        let r = videoRect(view: area, video: videoSize)   // points: round (devicePoint truncates to a pixel index)
        let pt = CGPoint(x: min(max(((p.x - r.minX) / r.width * videoSize.width).rounded(), 0), videoSize.width - 1),
                       y: min(max(((p.y - r.minY) / r.height * videoSize.height).rounded(), 0), videoSize.height - 1))   // not past the last point
        // no move events: a drag is one swipe on release
        if a == .down { pressed = (pt, .now) }
        if a == .up, let down = pressed {
            pressed = nil
            send(SimGesture.classify(down: down.at, up: pt, seconds: (ContinuousClock.now - down.time) / .seconds(1)))
        }
    }

    fileprivate func scroll(_ e: NSEvent, at p: CGPoint) {
        if ios {   // trackpad deltas are points; a wheel's are lines
            guard videoSize != .zero else { return }
            let k = e.hasPreciseScrollingDeltas ? 1.0 : 10.0
            scrolled.add(dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k)
            scrollTick += 1
            let t = scrollTick
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, t == self.scrollTick, let s = self.scrolled.flush(at: CGPoint(x: self.videoSize.width / 2, y: self.videoSize.height / 2),
                                                                                  screen: self.videoSize) else { return }
                self.send(s)
            }
            return
        }
        guard let d = devicePoint(p, view: screen.videoArea.size, video: videoSize) else { return }
        send(Scrcpy.scroll(x: d.x, y: d.y, width: size.w, height: size.h, h: Float(e.scrollingDeltaX / 10), v: Float(e.scrollingDeltaY / 10)))
    }

    fileprivate func key(_ a: Scrcpy.Action, _ code: Int32, repeat r: Bool = false) { send(Scrcpy.key(a, keycode: code, repeat: r ? 1 : 0)) }
    fileprivate func press(_ code: Int32) { send(Scrcpy.key(.down, keycode: code), Scrcpy.key(.up, keycode: code)) }
    fileprivate func back() { send(Scrcpy.backOrScreenOn(.down), Scrcpy.backOrScreenOn(.up)) }
    fileprivate func text(_ s: String) {
        guard !s.isEmpty else { return }
        guard ios else { return send(Scrcpy.text(s)) }
        if (try? SimText.validate(s)) != nil { send(.text(s)) }   // the simulator types US-keyboard ASCII only
    }
    /// iOS: true when the key went as a HID usage.
    fileprivate func simKey(_ macKeyCode: UInt16) -> Bool {
        guard ios, let u = IOSKeys.usage(macKeyCode: macKeyCode) else { return false }
        send(.key(u)); return true
    }
    fileprivate func home() { if ios { send(.button("home")) } else { press(3) } }
    fileprivate func lock() { send(.button("lock")) }
}

/// `sunken` screen + video layer (iOS: an image layer), a status overlay with **Reconectar**, and a footer: the buttons
/// (Voltar / Início / Recentes; iOS: Início / Bloquear), then the device and its transport (adb / simctl).
/// Typing goes through the input system (`NSTextInputClient`) so dead keys compose accents; mapped keys go as keycodes.
@MainActor private final class Screen: NSView, @preconcurrency NSTextInputClient {
    weak var owner: DevicePanel?
    let display = AVSampleBufferDisplayLayer()
    let image = CALayer()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Reconectar", target: nil, action: nil)
    private let overlay = NSStackView()
    private var bar: NSView!

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var barHeight: CGFloat { DevicePanel.footerHeight }
    /// Top-left, above the footer: the touch mapping takes its origin as (0, 0).
    var videoArea: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight)) }
    var hasStatus: Bool { !overlay.isHidden }

    init(ios: Bool, serial: String) {
        super.init(frame: .zero)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        image.contentsGravity = .resizeAspect
        layer?.addSublayer(ios ? image : display)
        applyChrome()
        label.textColor = OrqColor.text; label.alignment = .center
        retry.target = self; retry.action = #selector(reconnect)
        overlay.orientation = .vertical; overlay.alignment = .centerX
        overlay.addArrangedSubview(label); overlay.addArrangedSubview(retry)
        addSubview(overlay)
        let buttons: [DeviceFooter.Action] = ios
            ? [.init(title: "Início") { [weak self] in self?.home() }, .init(title: "Bloquear") { [weak self] in self?.lock() }]
            : [.init(title: "Voltar") { [weak self] in self?.back() }, .init(title: "Início") { [weak self] in self?.home() },
               .init(title: "Recentes") { [weak self] in self?.recents() }]
        bar = NSHostingView(rootView: DeviceFooter(buttons: buttons, serial: serial, transport: ios ? "simctl" : "adb"))
        addSubview(bar)
        status("Conectando…", retry: false)
    }

    /// `cgColor` resolves under the view's appearance, again on theme change (as the canvas nodes).
    private func applyChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = OrqColor.sunken.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyChrome() }
    required init?(coder: NSCoder) { fatalError() }

    func status(_ text: String?, retry showRetry: Bool) {
        overlay.isHidden = text == nil
        label.stringValue = text ?? ""
        retry.isHidden = !showRetry
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display.frame = videoArea; image.frame = videoArea
        CATransaction.commit()
        bar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        let w = min(bounds.width - 24, 320), h = overlay.fittingSize.height
        overlay.frame = CGRect(x: (bounds.width - w) / 2, y: (videoArea.height - h) / 2, width: max(0, w), height: h)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.windowChanged() }

    @objc private func reconnect() { owner?.reconnect() }
    @objc private func back() { owner?.back() }
    @objc private func home() { owner?.home() }
    @objc private func lock() { owner?.lock() }
    @objc private func recents() { owner?.press(187) }

    // MARK: mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); owner?.mouse(.down, at: point(e)) }
    override func mouseDragged(with e: NSEvent) { owner?.mouse(.move, at: point(e)) }
    override func mouseUp(with e: NSEvent) { owner?.mouse(.up, at: point(e)) }
    override func scrollWheel(with e: NSEvent) { owner?.scroll(e, at: point(e)) }

    // MARK: keyboard

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { return super.keyDown(with: e) }
        if !hasMarkedText(), owner?.simKey(e.keyCode) == true { return }
        if !hasMarkedText(), owner?.ios != true, let k = AndroidKeys.keycode(macKeyCode: e.keyCode) { return owner?.key(.down, k, repeat: e.isARepeat) ?? () }
        if e.modifierFlags.contains(.control) { return }
        interpretKeyEvents([e])
    }
    override func keyUp(with e: NSEvent) {
        if owner?.ios != true, let k = AndroidKeys.keycode(macKeyCode: e.keyCode), !e.modifierFlags.contains(.command) { owner?.key(.up, k) }
    }

    // Only composed text matters: no document behind it, so ranges are empty.
    private var marked = ""
    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        owner?.text(String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }))
    }
    override func doCommand(by selector: Selector) {}   // unmapped commands (e.g. ctrl-…): nothing to send
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
    func unmarkText() { marked = "" }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(videoArea, to: nil)) ?? .zero
    }
}

/// The Device panel's footer: its buttons (`secondary`), then the device and the transport.
private struct DeviceFooter: View {
    struct Action { let title: String; let run: @MainActor () -> Void }
    let buttons: [Action]
    let serial: String, transport: String
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.orqBorder).frame(height: 1)
            HStack(spacing: 6) {
                ForEach(buttons.indices, id: \.self) { i in Button(buttons[i].title, action: buttons[i].run) }
            }
            .buttonStyle(OrqButtonStyle(.secondary)).padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            PanelFooter(serial, trailing: transport)
        }
        .frame(height: DevicePanel.footerHeight, alignment: .top).clipped()
        .background(Color.orqSurface)
    }
}
