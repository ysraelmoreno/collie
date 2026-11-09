import SwiftUI
import AppKit
import CollieCore
import CollieProtocol
import CollieTheme
import ColliePlugins

/// A collie-ui block as a panel ("Anexar como painel"). `state.json` is the block as the chat showed it. Linked to an
/// app do cercado (`state.app`/`command`), ↻ (and `refresh` seconds, ≥ 5) asks the daemon to call that command again
/// and draws what it returns, which must be a block of the same kind; a snapshot panel keeps the JSON.
@MainActor @Observable final class UIBlockModel {
    private(set) var block: UIBlock?
    private(set) var json = ""
    private(set) var error: String?
    private(set) var updated: Date?
    let linked: Bool
    let refreshSeconds: Int?
    private let panel: Panel
    private let call: PanelHostContext.Call

    init(panel: Panel, call: @escaping PanelHostContext.Call) {
        self.panel = panel; self.call = call
        if case .string(let j)? = panel.state["json"] { json = j; block = UIBlock.parse(j) }
        linked = { if case .string(_)? = panel.state["app"], case .string(_)? = panel.state["command"] { true } else { false } }()
        refreshSeconds = { if case .number(let n)? = panel.state["refresh"], n.isFinite { max(UIBlockSource.minRefresh, min(UIBlockSource.maxRefresh, Int(n))) } else { nil } }()
    }

    func refresh() async {
        guard linked else { return }
        do {
            let r = try await call("admin.block.refresh", ["panel": .string(panel.id.uuidString)])
            guard case .object(let o) = r, let data = o["data"], let bytes = try? JSONEncoder().encode(data),
                  let text = String(data: bytes, encoding: .utf8), let fresh = UIBlock.parse(text) else {
                error = "o comando não devolveu um bloco collie-ui válido"; return
            }
            guard fresh.kind == block?.kind else { error = "o comando devolveu \(fresh.kind), esperado \(block?.kind ?? "?")"; return }
            block = fresh; json = text; updated = Date(); error = nil
        } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
    }
}

private struct UIBlockPanelView: View {
    let model: UIBlockModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.linked ? "ligado ao app" : "instantâneo").font(.collieMono(10)).foregroundStyle(Color.collieMuted)
                if let u = model.updated { Text(u, style: .time).font(.collieMono(10)).foregroundStyle(Color.collieMuted) }
                Spacer()
                if model.linked { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Color.collieAccent) }
            }
            if let e = model.error { Text(e).font(.collieMono(11)).foregroundStyle(Color.collieDanger) }
            ScrollView {
                if let b = model.block { UIBlockView(block: b, json: model.json, compact: false, choose: nil) }
                else { Text("Bloco inválido.").font(.collieMono(11)).foregroundStyle(Color.collieMuted) }
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.collieSurface)
        .task(id: model.refreshSeconds) {
            guard model.linked else { return }
            await model.refresh()
            guard let s = model.refreshSeconds else { return }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(s)); await model.refresh() }
        }
    }
}

@MainActor final class UIBlockPanel: PluginPanelView {
    let model: UIBlockModel
    let view: NSView
    init(panel: Panel, host: PanelHostContext) {
        model = UIBlockModel(panel: panel, call: host.call)
        view = NSHostingView(rootView: UIBlockPanelView(model: model))
    }
    func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .notFound, message: "uiblock has no commands")
    }
    func close() {}
}
