import AppKit
import SwiftUI
import SwiftTerm
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme

@MainActor @Observable final class NodeModel {
    var exitCode: Int32?
}

/// One canvas node: title bar, then the live terminal (or a "zoomed out" label), plus a resize corner.
/// Its bounds are the node's canvas size and its frame the screen size: zoom scales it, cols/rows follow canvas size only.
@MainActor final class TerminalNodeView: NSView, TerminalViewDelegate {
    static let titleHeight: CGFloat = 32   // the stored frame includes it: the body is what is left
    static let minSize = CGSize(width: 320, height: 200)   // canvas pt

    let id: UUID
    private let client: DaemonClient
    private let canvas: CanvasState
    private let node: NodeController
    private let model = NodeModel()
    private var title: TitleHost<NodeTitleBar>!
    private let corner = DragHandle()
    private let leash = LeashHandle()
    /// Leash drag from this node's handle: window-space point, and whether the mouse was released.
    var onLeashDrag: ((UUID, CGPoint, Bool) -> Void)?
    private(set) var term: NodeTerminal?
    private var label: NSTextField?
    private var stream: TerminalStream?
    private var reader: Task<Void, Never>?
    private var fontChoice = AppearanceSettings(defaults: .standard).terminalFont
    private var defaultsObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    init(id: UUID, client: DaemonClient, canvas: CanvasState, node: NodeController) {
        self.id = id; self.client = client; self.canvas = canvas; self.node = node
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        observeChrome()
        title = TitleHost(rootView: NodeTitleBar(id: id, client: client, model: model,
            restart: { [weak self] in self?.restart() },
            kill: { [weak self] in self?.kill() },
            edit: { [weak self] in self?.edit() },
            closeNode: { [weak self] in self?.confirmClose() }))
        title.onDrag = { [weak self] d in self?.move(d) }
        title.onClick = { [weak self] in self?.focus() }
        title.menuProvider = { [weak self] e in self?.menu(for: e) }
        title.onMouseUp = { [weak self] in self?.bringToFront() }
        corner.onMouseUp = { [weak self] in self?.bringToFront() }
        corner.onDrag = { [weak self] d in self?.resize(d) }
        addSubview(title)
        addSubview(corner)
        leash.onDrag = { [weak self] p, done in if let self { self.onLeashDrag?(self.id, p, done) } }
        addSubview(leash)
        node.onStreamChange = { [weak self] s in self?.attach(s) }
        attach(node.stream)
        // Preferences write the font to the standard defaults; any other write is ignored (no reflow).
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyFont() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: style

    /// Re-runs `applyChrome` whenever this node's badge changes (the attention border).
    private func observeChrome() {
        withObservationTracking { applyChrome() } onChange: { [weak self] in
            Task { @MainActor in self?.observeChrome() }
        }
    }

    /// Layer colors are fixed `cgColor`s: resolved here under the view's appearance, again on every theme change.
    private func applyChrome() {
        let attention = client.badges[id] == .attention
        layer?.borderWidth = attention ? 1.5 : 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (attention ? CollieColor.attention : CollieColor.border).cgColor
            layer?.backgroundColor = CollieColor.surface.cgColor
        }
    }

    /// SwiftTerm keeps fixed colors too. The ANSI palette is left alone.
    private func applyColors(_ t: NodeTerminal) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            func fixed(_ c: NSColor) -> NSColor { NSColor(cgColor: c.cgColor) ?? c }
            t.nativeBackgroundColor = fixed(CollieColor.sunken)
            t.nativeForegroundColor = fixed(CollieColor.text)
            t.caretColor = fixed(CollieColor.accent)
            t.selectedTextBackgroundColor = fixed(CollieColor.accent).withAlphaComponent(0.3)
            t.selectedTextForegroundColor = fixed(CollieColor.text)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
        if let term { applyColors(term) }
    }

    /// Setting the font resizes cols/rows; `sizeChanged` then resizes the PTY. The process is never restarted.
    private func reapplyFont() {
        let f = AppearanceSettings(defaults: .standard).terminalFont
        guard f != fontChoice else { return }
        fontChoice = f
        term?.setFontKeepingModes(f.font)
    }

    /// Set by the canvas: opens the edit sheet for this terminal.
    var onEdit: ((UUID) -> Void)?
    private func edit() { onEdit?(id) }

    /// Right-click on the title or border; the terminal body falls through to this menu too (apps with mouse reporting still get the right-click).
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(ActionItem("Editar…") { [weak self] in self?.edit() })
        m.addItem(ActionItem("Reiniciar") { [weak self] in self?.restart() })
        m.addItem(ActionItem("Matar") { [weak self] in self?.kill() })
        m.addItem(.separator())
        m.addItem(ActionItem("Fechar nó…") { [weak self] in self?.confirmClose() })
        return m
    }

    private var name: String? { client.terminals.first { $0.id == id }?.name }

    // MARK: mounting

    /// interactive: the SwiftTerm view is mounted; otherwise a static label (zoom < 0.5).
    func setInteractive(_ on: Bool) {
        if on, term == nil {
            label?.removeFromSuperview(); label = nil
            let t = NodeTerminal(frame: bodyFrame, font: fontChoice.font)
            t.optionAsMetaKey = false   // ⌥C types "ç" (US / Brazilian Pro layouts), as in Terminal; not ESC c
            applyColors(t)
            t.terminalDelegate = self
            t.onClick = { [weak self] in self?.focus() }
            t.onMouseUp = { [weak self] in self?.bringToFront() }
            addSubview(t, positioned: .below, relativeTo: corner)
            term = t
            startReader()
        } else if !on, label == nil {
            stopReader()
            term?.removeFromSuperview(); term = nil
            let l = NSTextField(labelWithString: name ?? "")
            l.alignment = .center
            l.textColor = CollieColor.muted
            l.lineBreakMode = .byTruncatingTail
            l.font = CollieFont.ui(13 / canvas.zoom, .semibold)   // counter-scaled: 13 screen pt at any zoom
            addSubview(l, positioned: .below, relativeTo: corner)
            label = l
        }
        needsLayout = true
    }

    /// Before removal: stop reading and forget the controller's callback (the controller outlives this view).
    func unmount() {
        stopReader()
        node.onStreamChange = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    /// `screen` is the node's screen frame, `canvasSize` its canvas size. Setting the frame resets the bounds
    /// scaling, so every frame write goes through here: zoom and pan never touch cols/rows (no SIGWINCH).
    func place(_ screen: CGRect, canvasSize: CGSize) {
        frame = screen
        setBoundsSize(canvasSize)
        if canvasSize != self.canvasSize { self.canvasSize = canvasSize; needsLayout = true }
        if canvas.zoom != lastZoom {
            lastZoom = canvas.zoom
            label?.font = CollieFont.ui(13 / lastZoom, .semibold)
            if label != nil { needsLayout = true }
            updateRasterScale()
        }
    }
    private var lastZoom: CGFloat = 0
    /// Layout reads this, not `bounds`: scaled bounds come back with float error (599.99…), which could drop a column.
    private var canvasSize: CGSize = .zero

    /// Content is drawn at canvas size and scaled by zoom: rasterize at screen pixels so 200% stays crisp.
    /// Integer multiples of the backing scale only: SwiftTerm snaps cells to 1/backing, so 2.74 would leave seams.
    /// It therefore changes only when zoom crosses 1.0, not on every pinch step.
    // ponytail: the SwiftUI title host keeps AppKit's scale (its layers aren't views; rescaling them without a redraw is unsafe).
    private(set) var rasterScale: CGFloat = 0
    private func updateRasterScale() {
        let px = window?.backingScaleFactor ?? 2
        let s = min(px * max(1, canvas.zoom.rounded(.up)), px * 2)   // the min is only a guard: zoomRange tops out at 2
        guard s != rasterScale else { return }
        rasterScale = s
        for v in subviews where v !== title { v.setRasterScale(s) }
    }

    override func didAddSubview(_ v: NSView) {
        super.didAddSubview(v)
        if rasterScale > 0, v !== title { v.setRasterScale(rasterScale) }
    }

    /// AppKit resets every layer's scale on a backing change: re-apply once all subviews have had theirs.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        DispatchQueue.main.async { [weak self] in self?.rasterScale = 0; self?.updateRasterScale() }
    }

    private var bodyFrame: CGRect {
        CGRect(x: 0, y: Self.titleHeight, width: canvasSize.width, height: max(canvasSize.height - Self.titleHeight, 0))
    }

    override func layout() {
        super.layout()
        let bounds = CGRect(origin: .zero, size: canvasSize)
        title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight)
        if let t = term {
            t.frame = bodyFrame
            Log.canvas.debug("grid \(self.id) frame \(self.bodyFrame.size.debugDescription, privacy: .public) dims \(t.terminalDimensions.cols)x\(t.terminalDimensions.rows) live \(self.inLiveResize)")
        }
        label?.frame = bodyFrame.insetBy(dx: 4, dy: max(bodyFrame.height / 2 - 10 / canvas.zoom, 0))
        leash.frame = CGRect(x: max(bounds.width - 56, 0), y: (Self.titleHeight - 12) / 2, width: 12, height: 12)
        corner.frame = Self.cornerFrame(bounds)
    }

    /// Inset from the 14 pt rounded corner so the grip isn't clipped.
    static func cornerFrame(_ b: CGRect) -> CGRect { CGRect(x: b.width - 18, y: b.height - 18, width: 14, height: 14) }

    // MARK: stream

    private func attach(_ s: TerminalStream?) {
        stopReader()
        stream = s
        startReader()
    }

    /// One task per stream (not per frame), off main: SwiftTerm's `feed` is thread-safe and parses on its own pipeline.
    private func startReader() {
        guard reader == nil, let s = stream, let t = term else { return }
        let dims = t.terminalDimensions
        s.resize(cols: UInt16(clamping: dims.cols), rows: UInt16(clamping: dims.rows))
        let model = model
        reader = Task.detached {
            for await f in s.frames {
                switch f {
                case .replay(let d, _):
                    t.resetToInitialState()   // the replay replaces the screen
                    t.feed(byteArray: [UInt8](d)[...])
                    await MainActor.run { model.exitCode = nil }
                case .out(let d): t.feed(byteArray: [UInt8](d)[...])
                case .exited(let code): await MainActor.run { model.exitCode = code }
                default: break
                }
            }
        }
    }

    // Cancelling the reader is harmless: the controller has already closed (or replaced) that stream.
    private func stopReader() { reader?.cancel(); reader = nil }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { stream?.send(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Log.canvas.debug("pty resize \(newCols)x\(newRows)")
        stream?.resize(cols: UInt16(clamping: newCols), rows: UInt16(clamping: newRows))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: actions

    private func focus() { if let term { window?.makeFirstResponder(term) } }

    /// On mouseUp (never mid-drag: re-adding a view cancels its mouse tracking). Re-adding drops first responder,
    /// so focus is restored when it was inside this node.
    func bringToFront() {
        guard let sv = superview, sv.subviews.last(where: { $0 is TerminalNodeView || $0 is PanelNodeView }) !== self else { return }
        let focused = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        sv.addSubview(self, positioned: .below, relativeTo: sv.subviews.first { $0 is Minimap })
        if focused { focus() }
    }

    private func move(_ d: CGSize) {
        guard var f = canvas.frames[id] else { return }
        f.origin.x += d.width / canvas.zoom
        f.origin.y += d.height / canvas.zoom
        canvas.frames[id] = f
    }

    private func resize(_ d: CGSize) {
        guard var f = canvas.frames[id] else { return }
        f.size.width = max(Self.minSize.width, f.width + d.width / canvas.zoom)
        f.size.height = max(Self.minSize.height, f.height + d.height / canvas.zoom)
        canvas.frames[id] = f
    }

    private func restart() {
        guard let name else { return }
        Task {
            do { try await client.restart(name) } catch { Log.canvas.error("restart \(name): \(error)") }
            // reattach so the new process starts with a fresh replay (only if the node still has a stream)
            if node.streamOpen { node.setVisible(false); node.setVisible(true) }
        }
    }

    private func kill() {
        guard let name else { return }
        Task { do { try await client.kill(name) } catch { Log.canvas.error("kill \(name): \(error)") } }
    }

    private func confirmClose() {
        guard let name, let window else { return }
        let a = NSAlert()
        a.messageText = "Fechar \(name)?"
        a.informativeText = "O terminal será encerrado."
        a.addButton(withTitle: "Fechar nó")
        a.addButton(withTitle: "Cancelar")
        a.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.kill() }
        }
    }
}

extension TerminalView {
    /// SwiftTerm's `font` setter resizes through `resize(cols:rows:)`, which soft-resets the running program
    /// (DECSTR: application cursor/keypad, cursor visibility, SGR, charset, ANSI palette), and the modes it
    /// clears are not public to snapshot. With a zero frame the setter skips that resize; restoring the frame
    /// then resizes through the frame path (no reset), which also calls `sizeChanged`, so the PTY gets the new size.
    // ponytail: relies on SwiftTerm 1.99.0's `resetFont` frame guard (pinned exact); covered by TerminalFontTests.
    func setFontKeepingModes(_ f: NSFont) {
        let frame = self.frame
        setFrameSize(.zero)
        font = f
        setFrameSize(frame.size)
    }
}

/// Keeps the font size fixed; reports clicks so the title bar and body focus the same way.
final class NodeTerminal: TerminalView {
    var onClick: (() -> Void)?, onMouseUp: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?(); super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); onMouseUp?() }
    /// Views SwiftTerm adds later (caret, progress bar, marked text) take the terminal's current scale.
    override func didAddSubview(_ v: NSView) {
        super.didAddSubview(v)
        if let s = layer?.contentsScale { v.setRasterScale(s) }
    }
}

extension NSView {
    /// Pixels per point for this view's layer and its subviews' (the node scales them by zoom).
    func setRasterScale(_ s: CGFloat) {
        layer?.contentsScale = s
        needsDisplay = true
        subviews.forEach { $0.setRasterScale(s) }
    }
}

/// Title bar host: drags move the node (AppKit deltas, so moving the view mid-drag can't feed back).
final class TitleHost<V: View>: NSHostingView<V> {
    var onDrag: ((CGSize) -> Void)?
    var onClick: (() -> Void)?, onMouseUp: (() -> Void)?
    var menuProvider: ((NSEvent) -> NSMenu?)?
    override func mouseDown(with event: NSEvent) { onClick?(); super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); onMouseUp?() }
    // The hosting view would swallow the right-click: show the node's menu ourselves.
    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?(event) { NSMenu.popUpContextMenu(m, with: event, for: self) } else { super.rightMouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(CGSize(width: event.deltaX, height: event.deltaY)) }
}

/// The small ring in the title bar: dragging from it to another node connects them with a leash.
final class LeashHandle: NSView {
    var onDrag: ((CGPoint, Bool) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        CollieColor.muted.setStroke()
        let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)); p.lineWidth = 1.5; p.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { onDrag?(event.locationInWindow, false) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow, false) }
    override func mouseUp(with event: NSEvent) { onDrag?(event.locationInWindow, true) }
}

/// The bottom-right resize corner.
final class DragHandle: NSView {
    var onDrag: ((CGSize) -> Void)?, onMouseUp: (() -> Void)?
    override func mouseUp(with event: NSEvent) { onMouseUp?() }
    override func draw(_ dirtyRect: NSRect) {
        CollieColor.muted.setStroke()
        let p = NSBezierPath()
        for i in [4.0, 8.0] {
            p.move(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + i))
            p.line(to: NSPoint(x: bounds.minX + i, y: bounds.maxY - 2))
        }
        p.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDragged(with event: NSEvent) { onDrag?(CGSize(width: event.deltaX, height: event.deltaY)) }
}

struct NodeTitleBar: View {
    let id: UUID
    let client: DaemonClient
    let model: NodeModel
    let restart: () -> Void, kill: () -> Void, edit: () -> Void, closeNode: () -> Void

    var body: some View {
        let t = client.terminals.first { $0.id == id }
        let status = NodeStatus(badge: client.badges[id], exitCode: model.exitCode)
        HStack(spacing: 8) {
            Circle().fill(color(status)).frame(width: 8, height: 8)
            Text(t?.name ?? "").font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
            if t?.isShepherd == true {
                CollieTag("Pastor", tone: .accent)
                Text("pastoreando \(client.connections.filter { $0.a == id || $0.b == id }.count)").foregroundStyle(Color.collieMuted)
            }
            Text(t?.preset.rawValue ?? "").foregroundStyle(Color.collieMuted).lineLimit(1)
            if case .disconnected = client.state { Text("desconectado").foregroundStyle(Color.collieDanger) }
            if let text = status.text { Text(text).foregroundStyle(color(status)).lineLimit(1) }
            if case .stopped = status { Button("Reiniciar", action: restart).controlSize(.mini) }
            Spacer(minLength: 0)
            Menu {
                Button("Editar…", action: edit)
                Button("Reiniciar", action: restart)
                Button("Matar", action: kill)
                Divider()
                Button("Fechar nó…", action: closeNode)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Ações do terminal").accessibilityLabel("Ações do terminal")
        }
        .font(.collieMono(11))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.collieSidebar)
    }

    private func color(_ s: NodeStatus) -> SwiftUI.Color {
        switch s {
        case .idle: .collieMuted
        case .working: .collieSecondary
        case .attention: .collieAttention
        case .stopped: .collieDanger
        }
    }
}
