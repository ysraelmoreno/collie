import AppKit
import SwiftUI
import CollieClient
import CollieCore
import ColliePlugins
import CollieProtocol
import CollieTheme

/// Hosts a panel's plug-in view; switching tabs or moving the panel only re-parents the instance.
struct PanelContent: NSViewRepresentable {
    let store: PanelViewStore
    let panel: Panel
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ c: NSView, context: Context) {
        let v = store.instance(for: panel.id)?.view
        guard c.subviews.first !== v else { return }
        c.subviews.forEach { $0.removeFromSuperview() }
        if let v { v.frame = c.bounds; v.autoresizingMask = [.width, .height]; c.addSubview(v) }
    }
}

/// One dock: tabs for its panels, and the selected one's view. Size (width, or height for the bottom dock) is
/// remembered in UserDefaults; the surrounding HSplitView/VSplitView (NSSplitView) does the resizing.
struct DockView: View {
    let placement: PanelPlacement
    let client: DaemonClient
    let store: PanelViewStore
    @State private var selected: UUID?
    @State private var saveSize: Task<Void, Never>?
    @AppStorage(AppearanceKeys.structure) private var structure = WindowStructure.compact.rawValue

    private var panels: [Panel] { client.panels.filter { $0.placement == placement } }
    private var sizeKey: String { "dock.\(placement.rawValue).size" }
    private var bottom: Bool { placement == .dockBottom }

    var body: some View {
        let ps = panels
        let current = ps.first { $0.id == selected } ?? ps.first
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(ps) { p in
                    Button { selected = p.id } label: {
                        Text(p.name).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(p.id == current?.id ? Color.collieText : .collieMuted)
                            .background(p.id == current?.id ? Color.collieRaised : .clear, in: .rect(cornerRadius: 6))
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(p.id == current?.id ? .isSelected : [])
                }
                Spacer(minLength: 0)
                if let current { PanelMenu(panel: current, client: client) }
            }
            .font(.collieUI(13)).padding(.horizontal, 6).frame(height: 30)
            Rectangle().fill(Color.collieBorder).frame(height: 1)
            if let current {
                if store.instance(for: current.id) != nil {
                    PanelContent(store: store, panel: current).id(current.id)
                } else {
                    Text("Plug-in indisponível").foregroundStyle(Color.collieMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .collieFocusPanel)) { n in
            if let id = n.object as? UUID, panels.contains(where: { $0.id == id }) { selected = id }
        }
        // Compacta: the dock is a card inset 12, radius 18. Values, not branches: the panel view keeps its identity.
        .background(Color.collieSidebar)
        .clipShape(.rect(cornerRadius: compact ? 18 : 0))
        .overlay(RoundedRectangle(cornerRadius: compact ? 18 : 0).strokeBorder(Color.collieBorder.opacity(compact ? 1 : 0), lineWidth: 1))
        .padding(compact ? 12 : 0)
        .frame(minWidth: bottom ? 0 : 200, idealWidth: bottom ? nil : stored(260),
               minHeight: bottom ? 120 : 0, idealHeight: bottom ? stored(220) : nil)
        .onGeometryChange(for: CGFloat.self, of: { [bottom = placement == .dockBottom] in bottom ? $0.size.height : $0.size.width }) { size in
            guard size > 0 else { return }
            let key = sizeKey
            saveSize?.cancel()   // debounced: written once the drag settles
            saveSize = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { UserDefaults.standard.set(Double(size), forKey: key) }
            }
        }
    }

    private var compact: Bool { WindowStructure(rawValue: structure) != .full }

    private func stored(_ fallback: CGFloat) -> CGFloat {
        let v = UserDefaults.standard.double(forKey: sizeKey)
        return v > 0 ? v : fallback
    }
}

/// Left | canvas | right over bottom; an empty dock is not part of the split (collapsed).
struct DockShell<Canvas: View>: View {
    let client: DaemonClient
    let store: PanelViewStore
    @ViewBuilder let canvas: Canvas

    private func has(_ p: PanelPlacement) -> Bool { client.panels.contains { $0.placement == p } }

    var body: some View {
        VSplitView {
            HSplitView {
                if has(.dockLeft) { DockView(placement: .dockLeft, client: client, store: store) }
                canvas.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if has(.dockRight) { DockView(placement: .dockRight, client: client, store: store) }
            }
            if has(.dockBottom) { DockView(placement: .dockBottom, client: client, store: store) }
        }
        .background(Color.collieBackground)
    }
}

extension Notification.Name {
    /// Select a docked panel's tab (`object`: its UUID), e.g. the one Work panel instead of opening another.
    static let collieFocusPanel = Notification.Name("collie.focusPanel")
}
