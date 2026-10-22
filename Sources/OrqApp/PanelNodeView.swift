import AppKit
import SwiftUI
import OrqCanvas
import OrqClient
import OrqCore
import OrqPlugins
import OrqProtocol
import OrqTheme

/// The plugin view's slot inside a panel node (the canvas scroll interception recognizes it). A plug-in's content
/// size request (`browser.resize`) resizes the node.
final class PanelBody: NSView, PanelContentSizing {
    var onContentSize: ((CGSize) -> Void)?
    func setContentSize(_ size: CGSize) { onContentSize?(size) }
}

/// A canvas panel: title bar (name, plug-in, menu), the plug-in's live view, a cord handle and a resize corner.
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
    private let cord = CordHandle()
    private var label: NSTextField?
    private var mounted: NSView?
    var onCordDrag: ((UUID, CGPoint, Bool) -> Void)?

    override var isFlipped: Bool { true }

    init(id: UUID, client: DaemonClient, canvas: CanvasState, store: PanelViewStore) {
        self.id = id; self.client = client; self.canvas = canvas; self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyChrome()
        title = TitleHost(rootView: PanelTitleBar(id: id, client: client))
        title.onDrag = { [weak self] d in self?.move(d) }
        title.onMouseUp = { [weak self] in self?.bringToFront() }
        corner.onMouseUp = { [weak self] in self?.bringToFront() }
        corner.onDrag = { [weak self] d in self?.resize(d) }
        cord.onDrag = { [weak self] p, done in if let self { self.onCordDrag?(self.id, p, done) } }
        body.onContentSize = { [canvas, id] s in
            guard var f = canvas.frames[id] else { return }
            f.size = CGSize(width: max(Self.minSize.width, s.width), height: max(Self.minSize.height, s.height + Self.titleHeight))
            canvas.frames[id] = f
        }
        addSubview(body)
        addSubview(title)
        addSubview(cord)
        addSubview(corner)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Same rule as TerminalNodeView: `cgColor`s are resolved under the view's appearance, again on theme change.
    private func applyChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = OrqColor.border.cgColor
            layer?.backgroundColor = OrqColor.surface.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyChrome() }

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
        l.alignment = .center; l.textColor = OrqColor.muted; l.font = OrqFont.ui(13, .semibold)
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
        cord.frame = CGRect(x: max(bounds.width - 56, 0), y: (Self.titleHeight - 12) / 2, width: 12, height: 12)
        corner.frame = TerminalNodeView.cornerFrame(bounds)
    }

    /// On mouseUp (never mid-drag: re-adding a view cancels its mouse tracking).
    func bringToFront() {
        guard let sv = superview, sv.subviews.last(where: { $0 is TerminalNodeView || $0 is PanelNodeView }) !== self else { return }
        sv.addSubview(self, positioned: .below, relativeTo: sv.subviews.first { $0 is Minimap })
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
}

struct PanelTitleBar: View {
    let id: UUID
    let client: DaemonClient

    var body: some View {
        let p = client.panels.first { $0.id == id }
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color.orqMuted).accessibilityHidden(true)
            Text(p?.name ?? "").font(.orqUI(13, .semibold)).foregroundStyle(Color.orqText).lineLimit(1)
            Text(p.flatMap(Self.target) ?? p?.pluginId ?? "").foregroundStyle(Color.orqMuted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let p { PanelMenu(panel: p, client: client) }
        }
        .font(.orqMono(11))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.orqSidebar)
    }

    /// What the panel points at: a URL, a file or a device, when it has one.
    static func target(_ p: Panel) -> String? {
        for k in ["url", "file", "serial"] { if case .string(let s)? = p.state[k], !s.isEmpty { return s } }
        return nil
    }
}

/// "Mover para ▸ …" and "Fechar…", shared by the dock tabs and the canvas title bar.
struct PanelMenu: View {
    let panel: Panel
    let client: DaemonClient

    static let labels: [PanelPlacement: String] = [.dockLeft: "Doca esquerda", .dockRight: "Doca direita",
                                                   .dockBottom: "Doca baixo", .canvas: "Canvas"]
    static let order: [PanelPlacement] = [.dockLeft, .dockRight, .dockBottom, .canvas]

    var body: some View {
        let allowed = PluginRegistry.spec(panel.pluginId)?.placements ?? Self.order
        Menu {
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
