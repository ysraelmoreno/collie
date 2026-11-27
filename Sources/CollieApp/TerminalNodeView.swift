import AppKit
import SwiftUI
import SwiftTerm
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme

@MainActor @Observable final class NodeModel {
    var exitCode: Int32?
    /// Mouse over the node, or the node selected: the title bar's action icons show.
    var hover = false
    var selected = false
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
    private let press = NodePress()
    private var title: TitleHost<NodeTitleBar>!
    private let corner = DragHandle()
    /// Overlay on the body's bottom edge (never part of the terminal's frame: no PTY resize when it shows).
    private let strip: TitleHost<AccessStrip>   // TitleHost: its buttons take clicks at any zoom
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
        strip = TitleHost(rootView: AccessStrip(id: id, client: client))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        observeChrome()
        title = TitleHost(rootView: NodeTitleBar(id: id, client: client, model: model,
            restart: { [weak self] in self?.restart() },
            kill: { [weak self] in self?.kill() },
            captureMemory: { [weak self] in self?.captureMemory() },
            edit: { [weak self] in self?.edit() },
            closeNode: { [weak self] in self?.confirmClose() },
            setLot: { [weak self] in self?.setLot($0) },
            fullscreen: { [weak self] in if let self { self.canvas.toggleFullscreen(self.id) } }))
        title.onDrag = { [weak self] d in self?.move(d) }
        title.onClick = { [weak self] in self?.focus() }
        title.onSelect = { [weak self] m in if let self { self.press.down(self.id, canvas: self.canvas, modifiers: m) } }
        title.menuProvider = { [weak self] e in self?.menu(for: e) }
        title.onMouseUp = { [weak self] in self?.released() }
        corner.onMouseUp = { [weak self] in self?.bringToFront() }
        corner.onDrag = { [weak self] d in self?.resize(d) }
        addSubview(title)
        addSubview(strip)
        strip.isHidden = true
        addSubview(corner)
        leash.onDrag = { [weak self] p, done in
            guard let self else { return }
            leashDragging = !done; updateActions()
            onLeashDrag?(id, p, done)
        }
        addSubview(leash)
        node.onStreamChange = { [weak self] s in self?.attach(s) }
        attach(node.stream)
        // Preferences write the font to the standard defaults; any other write is ignored (no reflow).
        NotificationCenter.default.addObserver(self, selector: #selector(themeSwapped), name: .collieThemeChanged, object: nil)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyFont() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: style

    /// Re-runs `applyChrome` whenever this node's badge changes (the attention border).
    private func observeChrome() {
        withObservationTracking { applyChrome(); updateStrip() } onChange: { [weak self] in
            Task { @MainActor in self?.observeChrome() }
        }
    }

    /// While the terminal has a request (access, leash, app card), at any zoom: a request is never hidden.
    private func updateStrip() {
        let show = !NodeRequest.of(id, client: client).isEmpty
        if strip.isHidden == show { strip.isHidden = !show; needsLayout = true }
    }

    // MARK: hover

    private var hoverArea: NSTrackingArea?
    private var leashDragging = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { model.hover = true; updateActions() }
    override func mouseExited(with event: NSEvent) { model.hover = false; updateActions() }
    /// The leash ring is an action icon too; never hidden mid-drag (it would drop the drag).
    private func updateActions() { leash.isHidden = !(model.hover || model.selected || leashDragging) }

    /// Layer colors are fixed `cgColor`s: resolved here under the view's appearance, again on every theme change.
    private func applyChrome() {
        let attention = client.badges[id] == .attention, selected = canvas.selection.contains(id)
        if model.selected != selected { model.selected = selected }
        updateActions()
        layer?.borderWidth = selected ? 2 : attention ? 1.5 : 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (attention ? CollieColor.attention : selected ? CollieColor.accent : CollieColor.border).cgColor
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
        themeSwapped()
    }

    /// Also from `collieThemeChanged`: the palette changed with the appearance unchanged. Only colors are set; the
    /// terminal, its process and scrollback are untouched.
    @objc private func themeSwapped() {
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
        // Like the Finder: outside the selection the right-click moves it here; inside, the menu acts on all of it.
        canvas.selectionState = Selecting.contextClick(canvas.selectionState, id)
        if canvas.selection.count > 1,
           let many = NodeBatch.menu(ids: canvas.selection, client: client, canvas: canvas, edit: { [weak self] in self?.onEdit?($0) }) {
            return many
        }
        let m = NSMenu()
        m.addItem(ActionItem(tr("Tela cheia", "Fullscreen")) { [weak self] in if let self { self.canvas.toggleFullscreen(self.id) } })
        m.addItem(.separator())
        m.addItem(ActionItem(tr("Editar…", "Edit…")) { [weak self] in self?.edit() })
        m.addItem(ActionItem(tr("Reiniciar", "Restart")) { [weak self] in self?.restart() })
        m.addItem(ActionItem(tr("Matar", "Kill")) { [weak self] in self?.kill() })
        if isClaude { m.addItem(ActionItem(tr("Salvar na memória", "Save to memory")) { [weak self] in self?.captureMemory() }) }
        let lots = NSMenuItem(title: tr("Lote", "Lot"), action: nil, keyEquivalent: ""), sub = NSMenu()
        let mine = client.lot(of: id)?.id
        for choice in LotChoice.all(client.lots) {
            let item = ActionItem(choice.title) { [weak self] in self?.setLot(choice.lot) }
            item.state = choice.lot?.id == mine ? .on : .off
            sub.addItem(item)
        }
        lots.submenu = sub
        m.addItem(lots)
        m.addItem(.separator())
        m.addItem(ActionItem(tr("Fechar nó…", "Close node…")) { [weak self] in self?.confirmClose() })
        return m
    }

    /// Grouping only: a lot never leashes anything.
    private func setLot(_ lot: Lot?) {
        guard let name else { return }
        Task { do { try await client.setLot(name, lot?.name) } catch { Log.canvas.error("lot \(name): \(error)") } }
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
            t.onClick = { [weak self] in
                guard let self else { return }
                // ⌘/⇧ stay the terminal's own (links, extending its text selection): those select from the title bar
                if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { press.down(id, canvas: canvas, modifiers: []) }
                focus()
            }
            t.onMouseUp = { [weak self] in self?.released() }
            addSubview(t, positioned: .below, relativeTo: strip)
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
            addSubview(l, positioned: .below, relativeTo: strip)
            label = l
        }
        updateStrip()
        needsLayout = true
    }

    /// Before removal: stop reading and forget the controller's callback (the controller outlives this view).
    func unmount() {
        AccessPopoverState.shared.close(id)
        stopReader()
        node.onStreamChange = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        NotificationCenter.default.removeObserver(self, name: .collieThemeChanged, object: nil)
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
        DispatchQueue.main.async { [weak self] in self?.rasterScale = 0; self?.updateRasterScale(); self?.reconcileGrid() }
    }

    /// During a window live resize (drag, fullscreen) SwiftTerm only queues a new size for its next frame tick,
    /// and it has no end-of-resize flush: apply it now.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reconcileGrid()
    }

    /// If the grid lags the frame (a queued size never applied, or applied late over a newer one), re-runs SwiftTerm's
    /// frame path, as `setFontKeepingModes` does: `processSizeChange` resizes, then `sizeChanged` resizes the PTY.
    /// No-op when the grid is what SwiftTerm would compute for the frame, so it cannot loop. Never during a live resize
    /// (it would only queue). Returns whether it re-ran the frame path.
    @discardableResult func reconcileGrid() -> Bool {
        guard let t = term, !t.inLiveResize else { return false }
        let size = t.frame.size, d = t.terminalDimensions, grid = t.getOptimalFrameSize().size
        guard size.width > 0, size.height > 0, d.cols > 0, d.rows > 0 else { return false }
        // SwiftTerm's own math (`processSizeChange`): cols = Int((width - scroller) / cellW), rows = Int(height / cellH).
        // The scroller reserves width only in the legacy style (MacTerminalView `reservedScrollerWidth`).
        let scroller = t.scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let cellW = (grid.width - scroller) / CGFloat(d.cols), cellH = grid.height / CGFloat(d.rows)
        guard Int((size.width - scroller) / cellW) != d.cols || Int(size.height / cellH) != d.rows else { return false }
        Log.canvas.debug("grid \(self.id) stale \(d.cols)x\(d.rows) for \(size.debugDescription, privacy: .public): resync")
        t.setFrameSize(.zero)
        t.setFrameSize(size)
        return true
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
        strip.frame = CGRect(x: 0, y: bounds.height - AccessStrip.height, width: bounds.width, height: AccessStrip.height)
        label?.frame = bodyFrame.insetBy(dx: 4, dy: max(bodyFrame.height / 2 - 10 / canvas.zoom, 0))
        leash.frame = CGRect(x: max(bounds.width - 82, 0), y: (Self.titleHeight - 12) / 2, width: 12, height: 12)
        corner.frame = Self.cornerFrame(bounds)
        reconcileGrid()
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
        // A queued size applied by a later frame tick can undo a newer synchronous one: check once it has landed.
        DispatchQueue.main.async { [weak self] in self?.reconcileGrid() }
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

    /// Mouse up on the title or body: the press ends (a click inside a group collapses it) and the node comes to the front.
    private func released() {
        press.up(id, canvas: canvas)
        bringToFront()
    }

    /// A selected node takes the rest of the selection along.
    private func move(_ d: CGSize) {
        press.dragged()
        canvas.move(canvas.selection.contains(id) ? canvas.selection : [id], by: d)
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

    private var isClaude: Bool { client.terminals.first { $0.id == id }?.preset == .claude }

    private func captureMemory() {
        guard let name else { return }
        Task { do { try await client.captureMemory(name) } catch { Log.canvas.error("memory capture \(name): \(error)") } }
    }

    private func confirmClose() {
        guard let name, let window else { return }
        let a = NSAlert()
        a.messageText = tr("Fechar \(name)?", "Close \(name)?")
        a.informativeText = tr("O terminal será encerrado.", "The terminal will be ended.")
        a.addButton(withTitle: tr("Fechar nó", "Close node"))
        a.addButton(withTitle: tr("Cancelar", "Cancel"))
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
    /// Files and images dropped on the terminal paste their paths (`TerminalDrop`); SwiftTerm takes no drops itself.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, registeredDraggedTypes.isEmpty { registerForDraggedTypes(TerminalDrop.types) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { TerminalDrop.accepts(sender.draggingPasteboard) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TerminalDrop.receive(sender.draggingPasteboard) { [weak self] text in
            guard let self else { return }
            window?.makeFirstResponder(self)
            pasteText(text)   // bracketed when the program asked for it, so agents see a paste
        }
    }
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
    /// The modifiers of the press, for the selection.
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var menuProvider: ((NSEvent) -> NSMenu?)?
    override func mouseDown(with event: NSEvent) { onSelect?(event.modifierFlags); onClick?(); super.mouseDown(with: unzoomed(event)) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: unzoomed(event)); onMouseUp?() }

    /// A terminal node scales its bounds by the canvas zoom, and SwiftUI reads a click as the window offset from this
    /// view's top-left without that scale: at any zoom ≠ 1 its controls (the ⤢, the access badge) missed every click.
    /// The location is rewritten so that offset is the one in this view's own points. No-op unscaled (panels, fullscreen).
    // ponytail: matches SwiftUI's offset math as of macOS 14/15; TerminalFullscreenClickTests fails if that changes.
    private func unzoomed(_ e: NSEvent) -> NSEvent {
        let r = convert(bounds, to: nil)
        guard bounds.width > 0, bounds.height > 0 else { return e }
        let sx = r.width / bounds.width, sy = r.height / bounds.height
        guard abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 else { return e }
        let p = e.locationInWindow
        let q = NSPoint(x: r.minX + (p.x - r.minX) / sx, y: r.maxY - (r.maxY - p.y) / sy)
        return NSEvent.mouseEvent(with: e.type, location: q, modifierFlags: e.modifierFlags, timestamp: e.timestamp,
                                  windowNumber: e.windowNumber, context: nil, eventNumber: e.eventNumber,
                                  clickCount: e.clickCount, pressure: e.pressure) ?? e
    }
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
    let restart: () -> Void, kill: () -> Void, captureMemory: () -> Void, edit: () -> Void, closeNode: () -> Void
    let setLot: (Lot?) -> Void
    let fullscreen: () -> Void

    var body: some View {
        let t = client.terminals.first { $0.id == id }
        let exited = model.exitCode != nil || client.badges[id] == .stopped
        let h = TerminalHeader.make(record: t, badge: model.exitCode != nil ? .stopped : client.badges[id],
                                    connections: client.connections, lot: client.lot(of: id))
        let actions = model.hover || model.selected
        HStack(spacing: 8) {
            Circle().fill(color(h.state)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(h.title).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1).help(h.help)
            if case .disconnected = client.state { Text(tr("desconectado", "disconnected")).foregroundStyle(Color.collieDanger) }
            else {
                Text(h.state.text).foregroundStyle(color(h.state)).lineLimit(1)
                    .help(model.exitCode.map { tr("Saiu com código \($0)", "Exited with code \($0)") } ?? "")
            }
            if exited, t != nil { Button(tr("Reiniciar", "Restart"), action: restart).controlSize(.mini) }
            if let w = h.warning {   // a free terminal is a risk: always visible
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Color.collieDanger).help(w).accessibilityLabel(w)
            }
            Spacer(minLength: 0)
            Group {
                if let t, CursorMemoryBadge.isCursor(preset: t.preset, command: t.command) { CursorMemoryTag(name: t.name, client: client) }
                FullscreenButton(action: fullscreen)
            }
            .opacity(actions ? 1 : 0).allowsHitTesting(actions)
            // Invisible off hover, never removed: the keyboard (and VoiceOver) still reach it.
            menu(t, h).opacity(actions ? 1 : 0)
        }
        .font(.collieMono(11))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.collieSidebar)
        .background(alignment: .bottomTrailing) {   // the access popover: the strip's ⓘ and the menu's "Acessos…" open it
            Color.clear.frame(width: 1, height: 1)
                .popover(isPresented: AccessPopoverState.shared.binding(id), arrowEdge: .bottom) { AccessPopover(id: id, client: client) }
        }
    }

    private func menu(_ t: TerminalRecord?, _ h: TerminalHeader) -> some View {
        Menu {
            Section { ForEach(h.menuItems, id: \.self) { Text($0) } }
            if let t, t.sandbox != .free {
                if AccessCopy.showsDetectionTag(detection: client.detection, reason: client.detectionReason) {
                    Text(AccessCopy.detection(reason: client.detectionReason).tag)
                }
                let cards = client.accessCards.filter { $0.terminal == id }.count
                let grants = client.grants.filter { $0.scope == .terminal && $0.owner == id }.count
                if cards + grants > 0 {
                    Button(tr("Acessos (\(cards) pedidos, \(grants) liberados)…", "Access (\(cards) requests, \(grants) granted)…")) {
                        AccessPopoverState.shared.open.insert(id)
                    }
                }
            }
            Divider()
            Button(tr("Tela cheia", "Fullscreen"), action: fullscreen).keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button(tr("Editar…", "Edit…"), action: edit)
            Button(tr("Reiniciar", "Restart"), action: restart)
            Button(tr("Matar", "Kill"), action: kill)
            if t?.preset == .claude { Button(tr("Salvar na memória", "Save to memory"), action: captureMemory) }
            Menu(tr("Lote", "Lot")) {
                let mine = client.lot(of: id)?.id
                ForEach(LotChoice.all(client.lots)) { c in
                    Toggle(c.title, isOn: Binding(get: { c.lot?.id == mine }, set: { _ in setLot(c.lot) }))
                }
            }
            Divider()
            Button(tr("Fechar nó…", "Close node…"), action: closeNode)
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(tr("Ações do terminal", "Terminal actions")).accessibilityLabel(tr("Ações de \(h.title)", "Actions for \(h.title)"))
    }

    private func color(_ s: TerminalHeader.State) -> SwiftUI.Color {
        switch s {
        case .done: .collieMuted
        case .working: .collieSecondary
        case .waiting: .collieAttention
        case .stopped: .collieDanger
        }
    }
}

/// What a terminal's title bar shows (spec lateral única, "Canvas"): a dot, the name and the state in a word. The rest
/// (Shepherd and how many it herds, tool, model, free/sandboxed, lot) goes to ⋯ and the name's tooltip; a free terminal
/// keeps a visible warning, as it is a risk.
struct TerminalHeader: Equatable {
    enum State: Equatable {
        case working, waiting, done, stopped
        var text: String {
            switch self {
            case .working: tr("trabalhando", "working")
            case .waiting: tr("esperando você", "waiting for you")
            case .done: tr("concluído", "done")
            case .stopped: tr("parado", "stopped")
            }
        }
    }
    let title: String
    let state: State
    /// Free terminals only: the warning icon's hover text.
    let warning: String?
    let menuItems: [String]
    var help: String { ([title] + menuItems).joined(separator: "\n") }

    /// `badge`: `.stopped` also when the process exited; nil (never reported) is "parado".
    static func make(record t: TerminalRecord?, badge: StatusBadge?, connections: [Connection], lot: Lot?) -> TerminalHeader {
        let state: State = switch badge {
        case .working: .working
        case .attention: .waiting
        case .idle: .done
        case .stopped, nil: .stopped
        }
        var items: [String] = []
        if let t {
            if t.isShepherd {
                let n = connections.filter { $0.a == t.id || $0.b == t.id }.count
                items.append(tr("Pastor · pastoreando \(n)", "Shepherd · shepherding \(n)"))
            }
            items.append(tr("Ferramenta: \(t.preset.rawValue)", "Tool: \(t.preset.rawValue)"))
            if let m = t.model { items.append(tr("Modelo: \(m)", "Model: \(m)")) }
            items.append(t.sandbox == .free ? tr("Livre: sem sandbox", "Free: no sandbox") : tr("Com sandbox", "Sandboxed"))
        }
        if let lot { items.append(lot.goal.isEmpty ? tr("Lote: \(lot.name)", "Lot: \(lot.name)") : tr("Lote: \(lot.name) — \(lot.goal)", "Lot: \(lot.name) — \(lot.goal)")) }
        let warning = t?.sandbox == .free ? tr("Terminal livre: sem sandbox, nenhuma guia chega a ele", "Free terminal: no sandbox, no leash reaches it") : nil
        return TerminalHeader(title: t?.name ?? "", state: state, warning: warning, menuItems: items)
    }
}

/// One entry of the "Lote" pickers: no lot, then every lot by name.
struct LotChoice: Identifiable, Equatable {
    let lot: Lot?
    var id: UUID? { lot?.id }
    var title: String { lot?.name ?? tr("Sem lote", "No lot") }
    static func all(_ lots: [Lot]) -> [LotChoice] { [LotChoice(lot: nil)] + lots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { LotChoice(lot: $0) } }
}
