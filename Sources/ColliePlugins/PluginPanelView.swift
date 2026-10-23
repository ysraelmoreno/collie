import AppKit
import Foundation
import CollieCore
import CollieProtocol

/// What a plugin view needs from the app: its panel, the daemon root (screenshots land under it), the workspace id,
/// an admin daemon call (`call`), a way to send plugin events (`emit` → `HostConnection.emit`), and an admin `ui.*`
/// stream (`openStream`, e.g. `ui.device`; unavailable unless the app provides it).
public struct PanelHostContext: Sendable {
    public let panel: Panel
    public let root: URL
    public let workspaceId: UUID?
    public typealias Call = @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue
    /// An admin command on the daemon (the app's `DaemonClient`).
    public let call: Call
    public let emit: @Sendable (_ name: String, _ payload: JSONValue) -> Void
    public typealias OpenStream = @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> StreamClient
    public let openStream: OpenStream
    public init(panel: Panel, root: URL, workspaceId: UUID?, call: @escaping Call,
                emit: @escaping @Sendable (_ name: String, _ payload: JSONValue) -> Void,
                openStream: @escaping OpenStream = { _, _ throws(ProtocolError) in throw ProtocolError(code: .unavailable, message: "no daemon streams here") }) {
        self.panel = panel; self.root = root; self.workspaceId = workspaceId; self.call = call; self.emit = emit; self.openStream = openStream
    }
}

/// An app-side plugin view (the same protocol an external plugin would implement).
@MainActor public protocol PluginPanelView: AnyObject {
    init(panel: Panel, host: PanelHostContext)
    var view: NSView { get }
    func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue
    /// A plugin event the daemon emitted for this panel (`ui.events`). Default: ignored.
    func receive(event: String, payload: JSONValue)
    /// Release everything (panel removed, or the app quits).
    func close()
    /// `panel` disappeared (closed by the user or a Shepherd; also seen after a relaunch if it was closed meanwhile),
    /// whether or not a view was ever created for it: delete its isolated data here. Not called on app quit.
    static func panelRemoved(_ panel: Panel, host: PanelHostContext)
    /// Once per daemon session, after the snapshot: `livePanels` are this plug-in's panels. Sweep orphaned data here.
    /// `host.panel` is a placeholder (no panel is involved).
    static func reconcile(livePanels: [Panel], host: PanelHostContext)
}
public extension PluginPanelView {
    static func panelRemoved(_ panel: Panel, host: PanelHostContext) {}
    static func reconcile(livePanels: [Panel], host: PanelHostContext) {}
    func receive(event: String, payload: JSONValue) {}
}

/// Runs `action` at once on the first `fire()`; further fires within `window` collapse into one run at its end
/// (which opens a new window). Owned by a panel model.
@MainActor final class RefreshCoalescer {
    private let window: Duration
    private let action: () async -> Void
    private var open = false, pending = false, closed = false
    private var timer: Task<Void, Never>?
    init(window: Duration, action: @escaping () async -> Void) { self.window = window; self.action = action }
    func fire() async {
        if closed { return }
        if open { pending = true; return }
        open = true
        await action()   // the window starts once it is done: a slow refresh never eats it
        timer = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.window)
                guard self.pending, !self.closed, !Task.isCancelled else { self.open = false; return }
                self.pending = false
                await self.action()
            }
        }
    }
    /// The panel closed: no more refreshes.
    func cancel() { closed = true; timer?.cancel(); timer = nil }
}

/// Registry keyed by plugin id. Task-5 plugins register themselves at launch; an unregistered id has no view.
@MainActor public enum PluginViews {
    struct Entry {
        let make: @MainActor (Panel, PanelHostContext) -> any PluginPanelView
        let removed: @MainActor (Panel, PanelHostContext) -> Void
        let reconcile: @MainActor ([Panel], PanelHostContext) -> Void
    }
    private static var entries: [String: Entry] = [:]
    public static func register<V: PluginPanelView>(_ pluginId: String, _ type: V.Type) {
        entries[pluginId] = Entry(make: { V(panel: $0, host: $1) }, removed: { V.panelRemoved($0, host: $1) },
                                  reconcile: { V.reconcile(livePanels: $0, host: $1) })
    }
    public static func unregister(_ pluginId: String) { entries[pluginId] = nil }
    public static func make(_ panel: Panel, host: PanelHostContext) -> (any PluginPanelView)? {
        entries[panel.pluginId]?.make(panel, host)
    }
    static func removed(_ panel: Panel, host: PanelHostContext) { entries[panel.pluginId]?.removed(panel, host) }
    static var registered: [String] { Array(entries.keys) }
    static func reconcile(_ id: String, _ live: [Panel], host: PanelHostContext) { entries[id]?.reconcile(live, host) }
}

/// The live view instance of every panel. Instances survive moves and culling (only detached) and are released
/// when the panel disappears from `panels` or on `closeAll()`. Also the dispatch target of the plugin host.
@MainActor public final class PanelViewStore {
    private var live: [UUID: any PluginPanelView] = [:]
    private var failed: Set<UUID> = []   // no view for this plugin: don't retry on every call
    private var known: [UUID: Panel] = [:]   // the previous mirror: what `sync` diffs against
    /// Headless panels' views: each in a never-ordered `BrowserInput.HostWindow` (plan 2K, Task 4 spike), so WebKit keeps
    /// the page laid out, rendering and active (trusted input, `:hover`) with no dock tab or canvas node.
    private var hosts: [UUID: NSWindow] = [:]
    private let panels: @MainActor () -> [Panel]
    private let context: @MainActor (Panel) -> PanelHostContext

    public init(panels: @escaping @MainActor () -> [Panel], context: @escaping @MainActor (Panel) -> PanelHostContext) {
        self.panels = panels; self.context = context
    }

    /// The panel's view, created on demand; nil when its plugin has no view (or the panel is unknown).
    public func instance(for id: UUID) -> (any PluginPanelView)? {
        if let v = live[id] { return v }
        guard !failed.contains(id), let p = panels().first(where: { $0.id == id }) else { return nil }
        guard let v = PluginViews.make(p, host: context(p)) else { failed.insert(id); return nil }
        live[id] = v
        // ponytail: headless is fixed at open (the daemon refuses moves in or out), so only creation hosts the view
        if p.placement == .headless {
            let w = BrowserInput.HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1, height: 1),
                                            styleMask: .borderless, backing: .buffered, defer: false)
            v.view.frame = .zero   // an empty slot: the page keeps its viewport (`Container.offscreenFrame`)
            w.contentView?.addSubview(v.view)
            hosts[id] = w
        }
        return v
    }

    /// Diffs against the previous mirror: for every panel that disappeared, the plug-in's static `panelRemoved` runs
    /// (live or never instantiated) and a live view is closed.
    public func sync(_ current: [Panel]) {
        let ids = Set(current.map(\.id))
        for (id, p) in known where !ids.contains(id) { PluginViews.removed(p, host: context(p)) }
        for (id, v) in live where !ids.contains(id) { v.close(); live[id] = nil; unhost(id, v) }
        failed.formIntersection(ids)
        known = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Call once per daemon session after the first snapshot (`panels` already mirrored): each registered plug-in
    /// sweeps what no live panel owns. Also resets the diff baseline so offline removals are not misreported.
    public func sessionStarted(_ current: [Panel]) {
        known = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in PluginViews.registered {
            let placeholder = Panel(id: UUID(), name: "", pluginId: id, placement: .canvas)
            PluginViews.reconcile(id, current.filter { $0.pluginId == id }, host: context(placeholder))
        }
    }

    /// Delivers a plugin event to the panel's live view; a panel without one drops it (never creates a view).
    public func deliver(panel: UUID, event: String, payload: JSONValue) { live[panel]?.receive(event: event, payload: payload) }

    public func closeAll() { for (id, v) in live { v.close(); unhost(id, v) }; live = [:] }

    private func unhost(_ id: UUID, _ v: any PluginPanelView) {
        guard let w = hosts.removeValue(forKey: id) else { return }
        v.view.removeFromSuperview(); w.close()
    }

    public func dispatch(_ panel: UUID, _ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        // the host call can beat the `.panel` event on ui.events: give the mirror up to 1 s
        for _ in 0..<20 where !panels().contains(where: { $0.id == panel }) { try? await Task.sleep(for: .milliseconds(50)) }
        guard panels().contains(where: { $0.id == panel }) else { throw ProtocolError(code: .notFound, message: "Panel not found") }
        guard let v = instance(for: panel) else { throw ProtocolError(code: .unavailable, message: "Plug-in indisponível") }
        return try await v.handle(command, args)
    }
}
