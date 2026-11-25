import Foundation
import CollieClient
import CollieCore

/// Descobrir's filter chips, by catalog kind.
enum CatalogFilter: CaseIterable {
    case all, panel, agent, engine
    var title: String { switch self { case .all: "Todos"; case .panel: "Painéis"; case .agent: "Agentes"; case .engine: "Motores" } }
    var kind: PluginCatalog.Kind? { switch self { case .all: nil; case .panel: .panel; case .agent: .agent; case .engine: .engine } }
}

/// What a catalog card's button does. `update(needsConfirm: false)`: one click, no confirmation (nothing new asked).
enum CatalogAction: Equatable { case install, installed, update(needsConfirm: Bool), recalled(reason: String), engine }

/// A Descobrir card: the catalog item and its button.
struct CatalogRow: Identifiable, Equatable {
    let item: PluginCatalogView.Item
    let action: CatalogAction
    var id: String { item.id }
}

/// Pure rules of Preferências → Plug-ins → Descobrir (spec "No app"; decided by the owner on 2026-11-24).
enum PluginCatalogModel {
    static func rows(_ v: PluginCatalogView, filter: CatalogFilter, installed: [PluginRow] = []) -> [CatalogRow] {
        v.items
            .filter { $0.latest != nil || $0.installed != nil }   // ponytail: nothing this Collie can install and not installed: hidden
            .filter { item in filter.kind.map { item.kind == $0 } ?? true }
            .map { item in CatalogRow(item: item, action: action(item, installed: installed.first { $0.id == item.id })) }
    }

    /// `installed`: the `plugin.list` row of the same id, whose permission lines a newer version is compared with.
    static func action(_ item: PluginCatalogView.Item, installed: PluginRow? = nil) -> CatalogAction {
        if item.kind == .engine { return .engine }
        if let r = item.recalled ?? installed?.recalled.map({ .init(reason: $0.reason) }) { return .recalled(reason: r.reason) }
        guard item.installed != nil else { return .install }
        guard item.update, let latest = item.latest else { return .installed }
        return .update(needsConfirm: !PluginInstallPrompt(catalog: item, latest: latest, replacing: installed).newPermissions.isEmpty)
    }

    /// The catalog version a recalled or outdated row can go to; nil: none newer.
    static func target(_ item: PluginCatalogView.Item) -> PluginCatalogView.Latest? { item.update ? item.latest : nil }

    /// "0,8 MB" (pt-BR decimal comma).
    static func size(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }

    /// The line above the list for a catalog that isn't plainly fresh; nil: none.
    static func banner(_ v: PluginCatalogView) -> String? {
        switch v.state {
        case "unavailable": "O catálogo não carregou. Os plug-ins instalados seguem funcionando."
        case "stale": "Catálogo desatualizado: a lista pode não ter as versões e os recolhimentos mais novos."
        default: nil
        }
    }
}
