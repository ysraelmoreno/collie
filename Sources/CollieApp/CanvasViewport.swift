import AppKit
import SwiftUI
import os
import CollieCanvas
import CollieClient
import CollieCore
import ColliePlugins
import CollieTheme

enum Log { static let canvas = Logger(subsystem: "dev.collie.app", category: "canvas") }

struct CanvasView: NSViewRepresentable {
    let client: DaemonClient
    let canvas: CanvasState
    let root: URL
    let store: PanelViewStore
    var onNewTerminal: (CGPoint) -> Void = { _ in }
    var onOpenPanel: (CGPoint) -> Void = { _ in }
    var onEdit: (UUID) -> Void = { _ in }
    var onApplyHerd: (CGPoint) -> Void = { _ in }
    var onSaveHerd: () -> Void = {}
    func makeNSView(context: Context) -> CanvasViewport {
        let v = CanvasViewport(client: client, canvas: canvas, root: root, store: store)
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ v: CanvasViewport, context: Context) {
        v.onNewTerminal = onNewTerminal; v.onOpenPanel = onOpenPanel; v.onEdit = onEdit
        v.onApplyHerd = onApplyHerd; v.onSaveHerd = onSaveHerd
    }
    static func dismantleNSView(_ v: CanvasViewport, coordinator: ()) { v.teardown() }
}

/// The infinite canvas. Owns one NodeController per daemon terminal; only nodes in `visibleNodes(margin: 200)`
/// have a view, and only those (at zoom ≥ 0.5) have a mounted terminal and an open stream.
@MainActor final class CanvasViewport: NSView {
    static let interactiveZoom: CGFloat = 0.5

    private let client: DaemonClient
    private let canvas: CanvasState
    private let root: URL
    private let store: PanelViewStore
    private var panelViews: [UUID: PanelNodeView] = [:]
    private var nodes: [UUID: NodeController] = [:]
    private var views: [UUID: TerminalNodeView] = [:]
    var onNewTerminal: (CGPoint) -> Void = { _ in }
    var onOpenPanel: (CGPoint) -> Void = { _ in }
    var onEdit: (UUID) -> Void = { _ in }
    var onApplyHerd: (CGPoint) -> Void = { _ in }
    var onSaveHerd: () -> Void = {}
    private let minimap: Minimap
    private let leashes: LeashLayer
    private var spaceDown = false
    private var scrollMonitor: Any?
    private var lastVisible: Set<UUID> = []
    private var lastGrid: (CGPoint, CGFloat) = (.zero, 0)

    // layout.json: nothing is placed or saved until it has been read (once, after the first connect).
    private var layoutLoaded = false, loadingLayout = false
    private var layoutURL: URL?
    private var lastSaved: LayoutFile?
    private var saveTask: Task<Void, Never>?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(client: DaemonClient, canvas: CanvasState, root: URL, store: PanelViewStore) {
        self.client = client; self.canvas = canvas; self.root = root; self.store = store
        minimap = Minimap(canvas: canvas)
        leashes = LeashLayer(client: client, canvas: canvas)
        super.init(frame: .zero)
        wantsLayer = true   // background and grid are drawn in draw(_:), so the dynamic tokens follow the theme
        addSubview(leashes)   // below the nodes (they are inserted under the minimap, above this)
        addSubview(minimap)
        observe()
        // key monitors: ignore BrowserInput.sentinel events — see BrowserInput.sentinel
        // The terminal's scrollWheel is not overridable: route scrolls here unless the terminal under the cursor has focus.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated { self?.interceptScroll(e) ?? false } ? nil : e
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// After this nothing re-syncs: the observation chain is invalidated and an in-flight layout load is ignored.
    func teardown() {
        tornDown = true
        generation += 1
        saveTask?.cancel(); saveTask = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        for v in views.values { v.unmount(); v.removeFromSuperview() }   // drops their defaults observers
        views = [:]
        for n in nodes.values { n.close() }
        nodes = [:]
        for v in panelViews.values { v.unmount(); v.removeFromSuperview() }   // detach only: the store owns the instances
        panelViews = [:]
    }

    /// Re-runs `sync` whenever anything it read (terminals, state, frames, offset, zoom) changes.
    /// Calling it again replaces the previous tracking (`generation`), so there is only ever one chain.
    private var generation = 0
    private var tornDown = false
    private func observe() {
        guard !tornDown else { return }
        generation += 1
        let gen = generation
        withObservationTracking { sync() } onChange: { [weak self] in
            Task { @MainActor in if let self, self.generation == gen { self.observe() } }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        leashes.frame = CGRect(origin: .zero, size: newSize)
        minimap.frame = CGRect(x: newSize.width - 180 - 12, y: newSize.height - 120 - 12, width: 180, height: 120)
        sync()
    }

    private var keyObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        window.makeFirstResponder(self)
        // a Space keyUp delivered elsewhere must not leave the canvas stuck in pan mode
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceDown = false }
        }
    }

    override func resignFirstResponder() -> Bool { spaceDown = false; return super.resignFirstResponder() }

    private func sync() {
        guard !tornDown else { return }
        guard layoutLoaded else { loadLayoutOnce(); return }
        let size = bounds.size
        let ids = visibleTerminals(client.terminals, paddock: client.currentPaddock).map(\.id)   // this paddock only
        let panelIds = visiblePanels(client.panels, paddock: client.currentPaddock).filter { $0.placement == .canvas }.map(\.id)
        if client.state == .connected {
            // frames of other paddocks (and of docked panels, kept for when they return to the canvas) stay
            let live = Set(client.terminals.map(\.id)).union(client.panels.map(\.id))
            for id in canvas.frames.keys where !live.contains(id) { canvas.frames[id] = nil }
        }
        let shown = Set(ids + panelIds)
        if canvas.shown != shown { canvas.shown = shown }
        for id in ids + panelIds where canvas.frames[id] == nil { canvas.place(id, viewport: size) }

        let zoom = canvas.zoom, interactive = zoom >= Self.interactiveZoom
        let inView = size.width > 0 ? canvas.visibleNodes(viewport: size, margin: 200) : []
        let visible = inView.intersection(ids)
        if visible != lastVisible {
            Log.canvas.debug("visible \(visible.count) of \(ids.count) zoom \(zoom)")
            lastVisible = visible
        }
        NodeController.sync(&nodes, terminals: ids, visible: interactive ? visible : [], client: client)
        for (id, v) in views where !visible.contains(id) {
            v.unmount(); v.removeFromSuperview(); views[id] = nil
        }
        for id in visible {
            guard let node = nodes[id], let f = canvas.frames[id] else { continue }
            let v = views[id] ?? {
                let v = TerminalNodeView(id: id, client: client, canvas: canvas, node: node)
                addSubview(v, positioned: .below, relativeTo: minimap)
                v.onLeashDrag = { [weak self] id, p, done in self?.leashDrag(id, p, done) }
                v.onEdit = { [weak self] id in self?.onEdit(id) }
                views[id] = v
                return v
            }()
            v.place(CGRect(origin: canvas.toScreen(f.origin), size: CGSize(width: f.width * zoom, height: f.height * zoom)), canvasSize: f.size)
            v.setInteractive(interactive)
        }
        // Panel nodes: culled ones are detached, never released (a webview lives as long as its panel).
        let shownPanels = inView.intersection(panelIds)
        for (id, v) in panelViews where !shownPanels.contains(id) { v.unmount(); v.removeFromSuperview(); panelViews[id] = nil }
        for id in shownPanels {
            guard let f = canvas.frames[id] else { continue }
            let v = panelViews[id] ?? {
                let v = PanelNodeView(id: id, client: client, canvas: canvas, store: store)
                addSubview(v, positioned: .below, relativeTo: minimap)
                v.onLeashDrag = { [weak self] id, p, done in self?.leashDrag(id, p, done) }
                panelViews[id] = v
                return v
            }()
            v.frame = CGRect(origin: canvas.toScreen(f.origin), size: CGSize(width: f.width * zoom, height: f.height * zoom))
            v.setInteractive(interactive)
        }
        if (canvas.offset, zoom) != lastGrid { lastGrid = (canvas.offset, zoom); needsDisplay = true }
        minimap.viewport = size
        minimap.needsDisplay = true
        leashes.update()
        scheduleSave()
    }

    // MARK: background

    static let gridStep: CGFloat = 24   // canvas pt

    /// Background plus a 1 pt dot every 24 canvas pt, only over the dirty rect; no dots below zoom 0.5.
    override func draw(_ dirtyRect: NSRect) {
        CollieColor.background.setFill()
        dirtyRect.fill()
        let zoom = canvas.zoom
        guard zoom >= 0.5, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let step = Self.gridStep, a = canvas.toCanvas(dirtyRect.origin)
        let b = canvas.toCanvas(CGPoint(x: dirtyRect.maxX, y: dirtyRect.maxY))
        let px = window?.backingScaleFactor ?? 2   // snap dots to backing pixels so they stay crisp
        var dots: [CGRect] = []
        dots.reserveCapacity(Int((b.x - a.x) / step + 2) * Int((b.y - a.y) / step + 2))
        var y = (a.y / step).rounded(.down) * step
        while y <= b.y {
            var x = (a.x / step).rounded(.down) * step
            while x <= b.x {
                let p = canvas.toScreen(CGPoint(x: x, y: y))
                dots.append(CGRect(x: ((p.x - 0.5) * px).rounded() / px, y: ((p.y - 0.5) * px).rounded() / px, width: 1, height: 1))
                x += step
            }
            y += step
        }
        CollieColor.grid.setFill()
        ctx.fill(dots)   // one call for the whole grid
    }

    // MARK: leashes

    /// Dragging from node `id`'s handle: a dashed line follows the mouse; releasing over another node connects them.
    private func leashDrag(_ id: UUID, _ windowPoint: CGPoint, _ done: Bool) {
        let p = convert(windowPoint, from: nil)
        guard let f = canvas.frames[id] else { return }
        let o = canvas.toScreen(f.origin)
        leashes.pending = done ? nil : (CGPoint(x: o.x + f.width * canvas.zoom, y: o.y + f.height * canvas.zoom / 2), p)
        let frames = views.mapValues(\.frame).merging(panelViews.mapValues(\.frame)) { a, _ in a }
        guard done, let other = frames.first(where: { $0.key != id && $0.value.contains(p) })?.key,
              let a = client.nodeName(id), let b = client.nodeName(other) else { return }
        Task { do { try await client.leash(a, b) } catch { Log.canvas.error("leash \(a)-\(b): \(error)") } }
    }

    // MARK: layout.json

    private func loadLayoutOnce() {
        guard client.state == .connected, !loadingLayout else { return }   // the daemon has written default-workspace
        loadingLayout = true
        let root = root
        Task {
            let (url, file) = await Task.detached { () -> (URL?, LayoutFile?) in
                let f = root.appendingPathComponent("default-workspace")
                guard let s = try? String(contentsOf: f, encoding: .utf8),
                      let ws = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return (nil, nil) }
                let url = Paths(root: root).workspaceDir(ws).appendingPathComponent("layout.json")
                return (url, LayoutStore.load(url))
            }.value
            guard !tornDown else { return }
            if let file { apply(file) }
            Log.canvas.debug("layout \(url?.path ?? "none", privacy: .public) loaded=\(file != nil)")
            layoutURL = url
            lastSaved = file
            layoutLoaded = true
            observe()   // the tracking so far only covered `client.state`
        }
    }

    private func apply(_ f: LayoutFile) {
        if f.zoom.isFinite { canvas.zoom = min(max(f.zoom, CanvasState.zoomRange.lowerBound), CanvasState.zoomRange.upperBound) }
        if f.offset.x.isFinite, f.offset.y.isFinite { canvas.offset = f.offset }
        canvas.frames = f.frames.filter { _, r in
            [r.origin.x, r.origin.y, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0
        }
    }

    /// Debounced 500 ms; the write happens off main.
    private func scheduleSave() {
        guard let url = layoutURL else { return }
        let f = LayoutFile(offset: canvas.offset, zoom: canvas.zoom, frames: canvas.frames)
        guard f != lastSaved else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.lastSaved = f
            let err = await Task.detached { () -> String? in
                do { try LayoutStore.save(f, to: url); return nil } catch { return "\(error)" }
            }.value
            if let err { Log.canvas.error("layout save: \(err, privacy: .public)") }
        }
    }

    // MARK: input

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    /// true = handled here (canvas pan/zoom); the event goes on to the terminal only when it has focus.
    private func interceptScroll(_ e: NSEvent) -> Bool {
        guard e.window === window, bounds.contains(point(e)),
              let hit = window?.contentView?.hitTest(e.locationInWindow), hit.isDescendant(of: self) else { return false }
        // the hit may be a SwiftTerm subview (e.g. its scroller): find the enclosing terminal
        let chain = sequence(first: hit, next: { $0.superview })
        let term = chain.first { $0 is NodeTerminal }
        if !e.modifierFlags.contains(.command), let term, window?.firstResponder === term { return false }
        if chain.contains(where: { $0 is PanelBody }) { return false }   // a page scrolls (and ⌘-zooms) itself
        scrollWheel(with: e)
        return true
    }

    override func scrollWheel(with e: NSEvent) {
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        if e.modifierFlags.contains(.command) {
            canvas.zoom(by: exp(e.scrollingDeltaY * k * 0.01), around: point(e))
        } else {
            canvas.pan(by: CGSize(width: e.scrollingDeltaX * k, height: e.scrollingDeltaY * k))
        }
    }

    /// Zoom over a panel's content belongs to the panel. WebKit hands a pinch to the page as gesture events (figcraft
    /// zooms on them); one it passes up here must not zoom the canvas under the pointer. Title bars, terminals and
    /// empty canvas zoom the canvas.
    static func zoomsCanvas(hit: NSView?) -> Bool {
        !sequence(first: hit, next: { $0?.superview }).contains { $0 is PanelBody }
    }

    /// The keyboard focus is inside a panel (e.g. FigCraft): ⌘= / ⌘- / ⌘0 are its own then.
    static func focusIsInPanel(_ responder: NSResponder?) -> Bool {
        guard let v = responder as? NSView else { return false }
        return sequence(first: v, next: { $0.superview }).contains { $0 is PanelBody }
    }

    override func magnify(with e: NSEvent) {
        guard Self.zoomsCanvas(hit: window?.contentView?.hitTest(e.locationInWindow)) else { return }
        canvas.zoom(by: 1 + e.magnification, around: point(e))
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // Caps Lock / keypad / fn flags are ignored; ⌘⇧= arrives as "+" (or "=" on some layouts)
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command || mods == [.command, .shift], !Self.focusIsInPanel(window?.firstResponder)
        else { return super.performKeyEquivalent(with: e) }
        switch (e.charactersIgnoringModifiers, mods == .command) {
        case ("=", _), ("+", _): canvas.zoom(by: 1.25, around: center)
        case ("-", true): canvas.zoom(by: 0.8, around: center)
        case ("0", true): canvas.zoom(by: 1 / canvas.zoom, around: center)
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }

    // Space+drag pans over nodes too; it needs the canvas (not a terminal) focused — click empty canvas first.
    override func keyDown(with e: NSEvent) { if e.keyCode == 49 { spaceDown = true } else { super.keyDown(with: e) } }
    override func keyUp(with e: NSEvent) { if e.keyCode == 49 { spaceDown = false } else { super.keyUp(with: e) } }

    override func hitTest(_ p: NSPoint) -> NSView? {
        if spaceDown, frame.contains(p) { return self }
        return super.hitTest(p)
    }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self) }

    /// Only reached by clicks that land on empty canvas (nodes and the minimap answer their own right-clicks).
    override func menu(for e: NSEvent) -> NSMenu? {
        guard let sv = superview, hitTest(sv.convert(e.locationInWindow, from: nil)) === self else { return nil }   // hitTest takes superview coords
        let at = canvas.toCanvas(point(e))
        let m = NSMenu()
        m.addItem(ActionItem("Novo terminal aqui…") { [weak self] in self?.onNewTerminal(at) })
        m.addItem(ActionItem("Abrir painel aqui…") { [weak self] in self?.onOpenPanel(at) })
        m.addItem(ActionItem("Aplicar rebanho aqui…") { [weak self] in self?.onApplyHerd(at) })
        m.addItem(ActionItem(canvas.selection.isEmpty ? "Salvar canvas como rebanho…" : "Salvar seleção como rebanho…") { [weak self] in
            self?.onSaveHerd()
        })
        m.addItem(.separator())
        m.addItem(ActionItem("Ajustar à tela") { [weak self] in
            guard let self else { return }
            canvas.fitAll(viewport: bounds.size)
        })
        m.addItem(ActionItem("Zoom 100%") { [weak self] in
            guard let self else { return }
            canvas.zoom(by: 1 / canvas.zoom, around: CGPoint(x: bounds.midX, y: bounds.midY))
        })
        return m
    }
    // Dragging empty canvas pans as well.
    override func mouseDragged(with e: NSEvent) { canvas.pan(by: CGSize(width: e.deltaX, height: e.deltaY)) }
}

/// A menu item with a closure action (NSMenuItem holds its target weakly, so the item is its own target).
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Bottom-right overview: every node frame and the viewport, scaled to their union. Click/drag centres the viewport.
@MainActor final class Minimap: NSView {
    private let canvas: CanvasState
    var viewport: CGSize = .zero
    override var isFlipped: Bool { true }

    init(canvas: CanvasState) { self.canvas = canvas; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private var visibleRect_: CGRect {
        CGRect(origin: canvas.offset, size: CGSize(width: viewport.width / canvas.zoom, height: viewport.height / canvas.zoom))
    }

    /// Canvas-space rect shown, and the canvas→minimap scale.
    private var mapping: (CGRect, CGFloat) {
        let u = canvas.shownFrames.reduce(visibleRect_) { $0.union($1) }.insetBy(dx: -40, dy: -40)
        return (u, min(bounds.width / max(u.width, 1), bounds.height / max(u.height, 1)))
    }

    override func draw(_ dirtyRect: NSRect) {
        CollieColor.sidebar.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let (u, s) = mapping
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - u.minX) * s, y: (r.minY - u.minY) * s, width: r.width * s, height: r.height * s)
        }
        CollieColor.muted.setFill()
        for r in canvas.shownFrames { map(r).fill() }
        CollieColor.accent.setStroke()
        let v = NSBezierPath(rect: map(visibleRect_)); v.lineWidth = 1.5; v.stroke()
    }

    override func mouseDown(with e: NSEvent) { centre(e) }
    override func mouseDragged(with e: NSEvent) { centre(e) }

    private func centre(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let (u, s) = mapping
        let c = CGPoint(x: u.minX + p.x / s, y: u.minY + p.y / s)
        canvas.offset = CGPoint(x: c.x - viewport.width / canvas.zoom / 2, y: c.y - viewport.height / canvas.zoom / 2)
    }
}
