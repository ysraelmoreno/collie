import AppKit
import SwiftUI
import CollieCanvas
import CollieClient
import CollieCore
import ColliePlugins
import CollieProtocol
import CollieTheme

/// The plugin view's slot inside a panel node (the canvas scroll interception recognizes it). A plug-in's content
/// size request (`browser.resize`) resizes the node.
final class PanelBody: NSView, PanelContentSizing {
    var onContentSize: ((CGSize) -> Void)?
    func setContentSize(_ size: CGSize) { onContentSize?(size) }
}

/// A canvas panel: title bar (name, plug-in, menu), the plug-in's live view, a leash handle and a resize corner.
/// Culling detaches the plug-in view (`unmount`); the instance itself stays in the `PanelViewStore`.
@MainActor final class PanelNodeView: NSView {
    static let titleHeight: CGFloat = 32   // same chrome as TerminalNodeView
    static let minSize = CGSize(width: 320, height: 200)   // canvas pt

    let id: UUID
    private let client: DaemonClient
    private let canvas: CanvasState
    private let store: PanelViewStore
    private let body = PanelBody()
    private var title: TitleHost<PanelTitleBar>!
    private let corner = DragHandle()
    private let leash = LeashHandle()
    private let press = NodePress()
    private var label: NSTextField?
    private var mounted: NSView?
    var onLeashDrag: ((UUID, CGPoint, Bool) -> Void)?

    override var isFlipped: Bool { true }

    init(id: UUID, client: DaemonClient, canvas: CanvasState, store: PanelViewStore) {
        self.id = id; self.client = client; self.canvas = canvas; self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        observeChrome()
        title = TitleHost(rootView: PanelTitleBar(id: id, client: client, fullscreen: { [canvas, id] in canvas.toggleFullscreen(id) }))
        title.onDrag = { [weak self] d in self?.move(d) }
        title.onSelect = { [weak self] m in if let self { self.press.down(self.id, canvas: self.canvas, modifiers: m) } }
        title.menuProvider = { [weak self] e in self?.selectionMenu(e) }
        title.onMouseUp = { [weak self] in self?.released() }
        corner.onMouseUp = { [weak self] in self?.bringToFront() }
        corner.onDrag = { [weak self] d in self?.resize(d) }
        leash.onDrag = { [weak self] p, done in if let self { self.onLeashDrag?(self.id, p, done) } }
        body.onContentSize = { [canvas, id] s in
            guard var f = canvas.frames[id] else { return }
            f.size = CGSize(width: max(Self.minSize.width, s.width), height: max(Self.minSize.height, s.height + Self.titleHeight))
            canvas.frames[id] = f
        }
        addSubview(body)
        addSubview(title)
        addSubview(leash)
        addSubview(corner)
        NotificationCenter.default.addObserver(self, selector: #selector(themeSwapped), name: .collieThemeChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Same rule as TerminalNodeView: `cgColor`s are resolved under the view's appearance, again on theme change.
    private func applyChrome() {
        let selected = canvas.selection.contains(id)
        layer?.borderWidth = selected ? 2 : 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (selected ? CollieColor.accent : CollieColor.border).cgColor
            layer?.backgroundColor = CollieColor.surface.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyChrome() }
    /// `collieThemeChanged`: the palette changed with the appearance unchanged. Selector observers leave on dealloc.
    @objc private func themeSwapped() { applyChrome() }

    /// Re-runs `applyChrome` whenever the selection changes.
    private func observeChrome() {
        withObservationTracking { applyChrome() } onChange: { [weak self] in
            Task { @MainActor in self?.observeChrome() }
        }
    }

    /// Right-click on the title: the selection (moved here when the click is outside it) when it holds several nodes;
    /// otherwise nil, and the panel's own menu stays the "…" button.
    private func selectionMenu(_ event: NSEvent) -> NSMenu? {
        canvas.selectionState = Selecting.contextClick(canvas.selectionState, id)
        guard canvas.selection.count > 1 else { return nil }
        return NodeBatch.menu(ids: canvas.selection, client: client, canvas: canvas, edit: { [weak self] in self?.onEdit?($0) })
    }

    /// Set by the canvas: the edit sheet of a terminal (a selection can mix both kinds).
    var onEdit: ((UUID) -> Void)?

    private func released() {
        press.up(id, canvas: canvas)
        bringToFront()
    }

    /// interactive: the plug-in's view is attached; otherwise (zoom < 0.5) a static label.
    func setInteractive(_ on: Bool) {
        if on {
            label?.removeFromSuperview(); label = nil
            if mounted != nil, mounted?.superview === body { return }
            if let v = store.instance(for: id)?.view {
                v.frame = body.bounds; v.autoresizingMask = [.width, .height]
                body.addSubview(v)   // moves it here if it was docked
                mounted = v
            } else if label == nil {
                label = makeLabel("Plug-in indisponível")
            }
        } else if label == nil {
            detach()
            label = makeLabel(client.panels.first { $0.id == id }?.name ?? "")
        }
        needsLayout = true
    }

    private func makeLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .center; l.textColor = CollieColor.muted; l.font = CollieFont.ui(13, .semibold)
        body.addSubview(l)
        return l
    }

    /// Only if the view is still ours: after "Mover para" SwiftUI may already have re-parented it into a dock.
    private func detach() { if mounted?.superview === body { mounted?.removeFromSuperview() }; mounted = nil }

    /// Before removal from the canvas: detach the plug-in view (the store keeps it alive).
    func unmount() { detach(); label?.removeFromSuperview(); label = nil }

    override func layout() {
        super.layout()
        title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight)
        body.frame = CGRect(x: 0, y: Self.titleHeight, width: bounds.width, height: max(bounds.height - Self.titleHeight, 0))
        label?.frame = body.bounds.insetBy(dx: 4, dy: max(body.bounds.height / 2 - 10, 0))
        leash.frame = CGRect(x: max(bounds.width - 82, 0), y: (Self.titleHeight - 12) / 2, width: 12, height: 12)
        corner.frame = TerminalNodeView.cornerFrame(bounds)
    }

    /// On mouseUp (never mid-drag: re-adding a view cancels its mouse tracking).
    func bringToFront() {
        guard let sv = superview, sv.subviews.last(where: { $0 is TerminalNodeView || $0 is PanelNodeView }) !== self else { return }
        sv.addSubview(self, positioned: .below, relativeTo: sv.subviews.first { $0 is Minimap })
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
}

struct PanelTitleBar: View {
    let id: UUID
    let client: DaemonClient
    let fullscreen: () -> Void

    var body: some View {
        let p = client.panels.first { $0.id == id }
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color.collieMuted).accessibilityHidden(true)
            Text(p?.name ?? "").font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
            Text(p.flatMap(Self.target) ?? p?.pluginId ?? "").foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            FullscreenButton(action: fullscreen)
            if let p { PanelMenu(panel: p, client: client, fullscreen: fullscreen) }
        }
        .font(.collieMono(11))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.collieSidebar)
    }

    /// What the panel points at: a URL, a file or a device, when it has one.
    static func target(_ p: Panel) -> String? {
        for k in ["url", "file", "serial"] { if case .string(let s)? = p.state[k], !s.isEmpty { return s } }
        return nil
    }
}

/// The ⤢ in a canvas node's title bar.
struct FullscreenButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(.plain).foregroundStyle(Color.collieMuted)
            .help("Tela cheia ⌘⏎").accessibilityLabel("Tela cheia")
    }
}

/// "Mover para ▸ …" and "Fechar…", shared by the dock tabs and the canvas title bar.
struct PanelMenu: View {
    let panel: Panel
    let client: DaemonClient
    /// Canvas title bar only (a docked panel has no fullscreen).
    var fullscreen: (() -> Void)?

    static let labels: [PanelPlacement: String] = [.dockLeft: "Doca esquerda", .dockRight: "Doca direita",
                                                   .dockBottom: "Doca baixo", .canvas: "Canvas"]
    static let order: [PanelPlacement] = [.dockLeft, .dockRight, .dockBottom, .canvas]

    var body: some View {
        let allowed = PluginRegistry.spec(panel.pluginId)?.placements ?? Self.order
        Menu {
            if let fullscreen {
                Button("Tela cheia", action: fullscreen).keyboardShortcut(.return, modifiers: .command)
                Divider()
            }
            Menu("Mover para") {
                ForEach(Self.order.filter(allowed.contains), id: \.self) { pl in
                    Button(Self.labels[pl] ?? pl.rawValue) { move(to: pl) }.disabled(pl == panel.placement)
                }
            }
            Divider()
            Button("Fechar…") { confirmClose() }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Ações do painel").accessibilityLabel("Ações do painel")
    }

    private func move(to pl: PanelPlacement) {
        let name = panel.name, client = client
        Task { do { try await client.movePanel(name, to: pl) } catch { Log.canvas.error("move \(name): \(error)") } }
    }

    private func confirmClose() {
        let name = panel.name, client = client
        let a = NSAlert()
        a.messageText = "Fechar \(name)?"
        a.informativeText = panel.state["storage"] == .string("isolated")
            ? "O painel será fechado e os dados isolados dele serão apagados." : "O painel será fechado."
        a.addButton(withTitle: "Fechar painel")
        a.addButton(withTitle: "Cancelar")
        let close = { Task { @MainActor in do { try await client.closePanel(name) } catch { Log.canvas.error("close \(name): \(error)") } } }
        if let w = NSApp.keyWindow {
            a.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { _ = close() } }
        } else if a.runModal() == .alertFirstButtonReturn { _ = close() }
    }
}
