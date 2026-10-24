import AppKit
import Foundation
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI

/// A memory row as `memory.list` returns it: the record plus where it lives (`lot`: the lot's name, for a lot's store)
/// and, for maps, since when its path is gone.
public struct MemoryRow: Decodable, Identifiable, Equatable, Sendable {
    public let record: MemoryRecord
    public let file: String?
    public let missingSince: Date?
    public let lot: String?
    public var id: UUID { record.id }
    private enum K: String, CodingKey { case file, missingSince, lot }
    public init(from d: Decoder) throws {
        record = try MemoryRecord(from: d)
        let c = try d.container(keyedBy: K.self)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        missingSince = try c.decodeIfPresent(Date.self, forKey: .missingSince)
        lot = try? c.decodeIfPresent(String.self, forKey: .lot)
    }
}
public struct MemoryRepo: Decodable, Identifiable, Equatable, Sendable {
    public let path: String, scope: String, paddock: String?
    public var id: String { path }
    public var label: String { scope == "global" ? "global" : (paddock ?? URL(fileURLWithPath: path).lastPathComponent) }
}
public struct MemoryProblem: Decodable, Identifiable, Equatable, Sendable {
    public let file: String, error: String
    public var id: String { file }
}
public struct CleanupEntry: Decodable, Identifiable, Equatable, Sendable {
    public let action: String, id: UUID, into: UUID?, reason: String
}

/// One automatic action of the curator (`memory.digest`): `before` is what Desfazer writes back.
public struct DigestRow: Decodable, Identifiable, Equatable, Sendable {
    public let id: UUID, at: Date, action: String, title: String, reason: String, store: String
    public let created: [UUID], before: [MemoryRecord], undone: Bool, resolved: Bool
    public var isAsk: Bool { action == "ask" }
}
/// The curator's availability and today's usage (`memory.digest`'s `curator`).
public struct CuratorInfo: Decodable, Equatable, Sendable {
    public let available: Bool, reason: String?, today: Int, cap: Int, inputTokens: Int, outputTokens: Int, costUSD: Double
}

/// The opt-in daily notification (off by default): at 18:00 local, once a day, when today's digest has something.
public enum MemoryDigestNotice {
    public static let defaultsKey = "memory.dailyNotification", lastPostedKey = "memory.dailyNotification.lastPosted"
    public static let defaultOn = false, hour = 18
    public struct Item: Sendable { public var at: Date, ask: Bool; public init(at: Date, ask: Bool) { self.at = at; self.ask = ask } }
    public static func items(_ rows: [DigestRow]) -> [Item] { rows.filter { !$0.undone && !($0.isAsk && $0.resolved) }.map { Item(at: $0.at, ask: $0.isAsk) } }
    /// nil: nothing to post now. "Collie aprendeu <n> coisas, <m> precisa(m) de você" (the `m` part only when > 0).
    public static func message(enabled: Bool, items: [Item], now: Date, lastPosted: Date?, calendar: Calendar = .current) -> String? {
        guard enabled, calendar.component(.hour, from: now) >= hour, lastPosted.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true else { return nil }
        let today = items.filter { calendar.isDate($0.at, inSameDayAs: now) }
        let n = today.filter { !$0.ask }.count, m = today.filter(\.ask).count
        guard n + m > 0 else { return nil }
        let learned = "Collie aprendeu \(n) \(n == 1 ? "coisa" : "coisas")"
        return m == 0 ? learned : learned + ", \(m) \(m == 1 ? "precisa" : "precisam") de você"
    }
}

/// State and daemon calls of the Memory panel (all async; the daemon does the work). The admin picks the store with `repo`.
@MainActor public final class MemoryPanelModel: ObservableObject {
    public enum Tab: String, CaseIterable, Sendable {
        case learning = "Aprendizado", review = "Revisar", decisions = "Decisões", map = "Mapa", cleanup = "Limpeza"
    }

    @Published public private(set) var repos: [MemoryRepo] = []
    @Published public var repo: String?
    @Published public var tab: Tab = .learning
    /// The last 7 days of the curator's digest (Aprendizado), and its status line.
    @Published public private(set) var digest: [DigestRow] = []
    @Published public private(set) var curator: CuratorInfo?
    /// Lot store key ("lot:<id>") → the lot's name, for "Promover ao projeto".
    private var lotNames: [String: String] = [:]
    @Published public private(set) var unreviewed: [MemoryRow] = []
    /// Captured, not yet reviewed (MemoryCapture): the picked repo's and every lot's, never injected until approved.
    @Published public private(set) var proposals: [MemoryRow] = []
    /// Every lot's active memories (R8): what an agent saved inside a lot, reviewable and promotable from here.
    @Published public private(set) var lotMemories: [MemoryRow] = []
    @Published public private(set) var decisions: [MemoryRow] = []
    @Published public private(set) var procedures: [MemoryRow] = []
    @Published public private(set) var superseded: [MemoryRow] = []
    @Published public private(set) var maps: [MemoryRow] = []
    @Published public private(set) var archived: [MemoryRow] = []
    /// Every active record (pitfalls too): the roots of the replacement chains.
    @Published public private(set) var active: [MemoryRow] = []
    @Published public private(set) var discarded: [MemoryRow] = []
    @Published public private(set) var plan: [CleanupEntry] = []
    @Published public private(set) var problems: [MemoryProblem] = []
    @Published public private(set) var error: String?
    /// Set by the confirmation dialog; `purge()` does nothing without it.
    @Published public var purgeConfirmed = false

    private let call: PanelHostContext.Call
    public init(call: @escaping PanelHostContext.Call) { self.call = call }

    private func send(_ command: String, _ args: [String: JSONValue] = [:]) async -> JSONValue? {
        var a = args
        if let repo { a["repo"] = .string(repo) }
        do { return try await call(command, a) }
        catch { self.error = error.message; return nil }
    }
    private func decode<T: Decodable>(_ v: JSONValue?) -> T? {
        guard let v, let data = try? JSONEncoder().encode(v) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }
    private struct Listing: Decodable { var records: [MemoryRow]; var problems: [MemoryProblem] }
    private func list(_ status: String, unreviewed: Bool = false, lot: String? = nil) async -> Listing? {
        var args: [String: JSONValue] = ["status": .string(status)]
        if unreviewed { args["unreviewed"] = .bool(true) }
        if let lot { args["lot"] = .string(lot) }
        return decode(await send("memory.list", args))
    }

    /// Repos (first time) and every list the tabs show.
    public func load() async {
        error = nil
        if let r: [MemoryRepo] = decode(await send("memory.repos")) { repos = r }   // refreshed each time: new paddocks appear
        if repo == nil || !repos.contains(where: { $0.path == repo }) { repo = repos.first?.path }
        guard repo != nil else { return }
        if let l = await list("active", unreviewed: true) { unreviewed = l.records; problems = l.problems }
        if let l = await list("active") {
            active = l.records
            decisions = l.records.filter { $0.record.kind == .decision }
            procedures = l.records.filter { $0.record.kind == .procedure }
            maps = l.records.filter { $0.record.kind == .map }
        }
        if let l = await list("superseded") { superseded = l.records }
        if let l = await list("archived") { archived = l.records }
        if let l = await list("discarded") { discarded = l.records }
        var props = await list("proposed")?.records ?? []
        struct LotName: Decodable { var name: String; var id: UUID? }
        let lots: [LotName] = decode(await send("lot.list")) ?? []
        lotNames = Dictionary(lots.compactMap { l in l.id.map { ("lot:\($0.uuidString.lowercased())", l.name) } }, uniquingKeysWith: { a, _ in a })
        struct Digest: Decodable { var entries: [DigestRow]; var curator: CuratorInfo? }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86400))
        if let dg: Digest = decode(await send("memory.digest", ["since": .string(since)])) { digest = dg.entries; curator = dg.curator }
        for l in lots { props += await list("proposed", lot: l.name)?.records ?? [] }
        proposals = props
        var mem: [MemoryRow] = []
        for l in lots { mem += await list("active", lot: l.name)?.records ?? [] }
        lotMemories = mem
    }

    /// "Precisa de você" (open asks) first, then "Hoje" and "Esta semana" (the rest of the 7 days), newest first; empty
    /// groups left out.
    public func learningGroups(now: Date = Date(), calendar: Calendar = .current) -> [(title: String, rows: [DigestRow])] {
        let rows = digest.sorted { $0.at > $1.at }
        let groups: [(String, [DigestRow])] = [
            ("Precisa de você", rows.filter { $0.isAsk && !$0.resolved && !$0.undone }),
            ("Hoje", rows.filter { !$0.isAsk && calendar.isDate($0.at, inSameDayAs: now) }),
            ("Esta semana", rows.filter { !$0.isAsk && !calendar.isDate($0.at, inSameDayAs: now) && now.timeIntervalSince($0.at) <= 7 * 86400 }),
        ]
        return groups.filter { !$0.1.isEmpty }.map { (title: $0.0, rows: $0.1) }
    }
    /// "Curador: 12/40 hoje · 18 mil tokens · US$ 0,04", or "curador indisponível: <motivo>".
    public var curatorLine: String? {
        guard let c = curator else { return nil }
        if !c.available { return "curador indisponível: \(c.reason ?? "desconhecido")" }
        let t = c.inputTokens + c.outputTokens
        let tokens = t < 1_000 ? "\(t)" : t < 1_000_000 ? "\(Int((Double(t) / 1_000).rounded())) mil"
            : (Double(t) / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "pt_BR"))) + " mi"
        let cost = c.costUSD.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "pt_BR")))
        return "Curador: \(c.today)/\(c.cap) hoje · \(tokens) tokens · US$ \(cost)"
    }
    public func undo(_ e: DigestRow) async { await change("memory.undo", ["entry": .string(e.id.uuidString)]) }
    public func resolve(_ e: DigestRow, keepNewer: Bool) async {
        await change("memory.resolve", ["entry": .string(e.id.uuidString), "keep": .string(keepNewer ? "newer" : "older")])
    }
    /// The curator's daily job cap (0 = off).
    public func setCap(_ n: Int) async { await change("memory.curator", ["cap": .number(Double(max(0, n)))]) }
    /// An ask from a lot's job that suggests the project: its memory and lot, for "Promover ao projeto".
    public func promoteSuggestion(_ e: DigestRow) -> (id: UUID, lot: String)? {
        guard e.isAsk, let lot = lotNames[e.store], e.title.localizedCaseInsensitiveContains("projeto"), let id = e.before.first?.id else { return nil }
        return (id, lot)
    }
    public func promoteSuggested(_ e: DigestRow) async {
        guard let s = promoteSuggestion(e) else { return }
        await promote(s.id, lot: s.lot)
    }

    /// Lot memories by lot name, each group newest first.
    public var lotMemoryGroups: [(lot: String, rows: [MemoryRow])] {
        let keys = Array(Set(lotMemories.compactMap(\.lot))).sorted()
        return keys.map { k in (k, lotMemories.filter { $0.lot == k }.sorted { $0.record.createdAt > $1.record.createdAt }) }
    }

    /// Proposals by lot (the project's last, `lot` nil), each group newest first.
    public var proposalGroups: [(lot: String?, rows: [MemoryRow])] {
        let keys = Array(Set(proposals.map(\.lot))).sorted { ($0 ?? "\u{10FFFF}") < ($1 ?? "\u{10FFFF}") }
        return keys.map { k in (k, proposals.filter { $0.lot == k }.sorted { $0.record.createdAt > $1.record.createdAt }) }
    }
    /// Every proposal of the group, approved one by one (each replaces the active memory of its subject); one reload.
    public func approveAll(lot: String?) async {
        error = nil
        for r in proposals where r.lot == lot {
            guard await send("memory.review", reviewArgs(r.id, "approve", lot: lot)) != nil else { break }
        }
        await load()
    }
    public func selectRepo(_ path: String) async { repo = path; await load(); if tab == .cleanup { await planCleanup() } }

    private func change(_ command: String, _ args: [String: JSONValue]) async {
        error = nil
        if await send(command, args) != nil { await load() }
    }
    /// `lot`: the record lives in that lot's store (a row's `lot`).
    public func approve(_ id: UUID, lot: String? = nil) async { await review(id, "approve", lot: lot) }
    /// Out of injections but kept: restorable, and `purge` never deletes it.
    public func archive(_ id: UUID, lot: String? = nil) async { await review(id, "archive", lot: lot) }
    /// A lot memory becomes the project's (unreviewed, unpinned); the lot's copy is superseded.
    public func promote(_ id: UUID, lot: String) async { await change("memory.promote", ["id": .string(id.uuidString), "lot": .string(lot)]) }
    public func discard(_ id: UUID, lot: String? = nil) async { await review(id, "discard", lot: lot) }
    private func reviewArgs(_ id: UUID, _ action: String, lot: String?, _ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var a = extra.merging(["id": .string(id.uuidString), "action": .string(action)]) { a, _ in a }
        if let lot { a["lot"] = .string(lot) }
        return a
    }
    private func review(_ id: UUID, _ action: String, lot: String? = nil, _ extra: [String: JSONValue] = [:]) async {
        await change("memory.review", reviewArgs(id, action, lot: lot, extra))
    }
    /// Editing counts as approving (the daemon marks it reviewed).
    public func edit(_ id: UUID, title: String, body: String, subject: String, lot: String? = nil) async {
        await review(id, "approve", lot: lot, ["title": .string(title), "body": .string(body), "subject": .string(subject)])
    }
    private func withLot(_ id: UUID, _ lot: String?) -> [String: JSONValue] {
        var a: [String: JSONValue] = ["id": .string(id.uuidString)]
        if let lot { a["lot"] = .string(lot) }
        return a
    }
    public func restore(_ id: UUID, lot: String? = nil) async { await change("memory.restore", withLot(id, lot)); if tab == .cleanup { await planCleanup() } }
    public func pin(_ id: UUID, _ pinned: Bool = true, lot: String? = nil) async { await change(pinned ? "memory.pin" : "memory.unpin", withLot(id, lot)) }

    /// Leaves `error` alone: it runs right after `load`, whose error must stay visible.
    public func planCleanup() async {
        struct Plan: Decodable { var items: [CleanupEntry] }
        if let p: Plan = decode(await send("memory.cleanup")) { plan = p.items }
    }
    public func applyCleanup() async {
        error = nil
        guard await send("memory.cleanup", ["apply": .bool(true)]) != nil else { return }
        await load(); await planCleanup()
    }
    /// Deletes the discarded files for good: only after the user confirmed (`purgeConfirmed`).
    public func purge() async {
        guard purgeConfirmed else { return }
        purgeConfirmed = false
        await change("memory.purge", [:])
    }

    /// The decision's replacement chain, newest superseded first: what it replaced, and what that replaced.
    public func history(of row: MemoryRow) -> [MemoryRow] {
        var out: [MemoryRow] = [], next = row.record.supersedes
        while let id = next, let r = superseded.first(where: { $0.id == id }), !out.contains(where: { $0.id == id }) {
            out.append(r); next = r.record.supersedes
        }
        return out
    }
    /// Superseded records no active record's history reaches (e.g. merged duplicates): restorable only from here.
    public var unchained: [MemoryRow] {
        let reached = Set(active.flatMap { history(of: $0).map(\.id) })
        return superseded.filter { !reached.contains($0.id) }
    }
    public func title(_ id: UUID) -> String {
        (active + unreviewed + superseded + archived + discarded).first { $0.id == id }?.record.title ?? id.uuidString.prefix(8).lowercased()
    }
}

/// The Memory plug-in: a SwiftUI review panel over the `memory.*` admin commands. No agent commands.
@MainActor public final class MemoryPanel: PluginPanelView {
    let model: MemoryPanelModel
    public let view: NSView
    public init(panel: Panel, host: PanelHostContext) {
        model = MemoryPanelModel(call: host.call)
        view = NSHostingView(rootView: MemoryPanelView(model: model))
    }
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .notFound, message: "memory has no commands")
    }
    public func close() {}
}

@MainActor private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "pt_BR"); f.unitsStyle = .short; return f
}()

struct MemoryPanelView: View {
    @ObservedObject var model: MemoryPanelModel
    @State private var editing: MemoryRow?
    @State private var confirmPurge = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.problems.isEmpty { problemsBar }
            if let e = model.error {
                Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .background(Color.collieBackground)
            PanelFooter("\(model.active.count) ativas · \(model.unreviewed.count) para revisar", trailing: ".collie/memory")
        }
        .background(Color.collieSurface)
        .task { await model.load() }
        .onChange(of: model.tab) { _, t in if t == .cleanup { Task { await model.planCleanup() } } }
        .sheet(item: $editing) { row in EditSheet(row: row) { t, b, s in Task { await model.edit(row.id, title: t, body: b, subject: s, lot: row.lot) } } }
        .confirmationDialog("Esvaziar descartadas?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Apagar \(model.discarded.count) arquivo(s)", role: .destructive) { model.purgeConfirmed = true; Task { await model.purge() } }
        } message: { Text("\(model.discarded.count) arquivo(s) serão apagados do disco. Isso não pode ser desfeito.") }
    }

    private var header: some View {
        VStack(spacing: 0) {
            PanelHeader("Memória") {
                Picker("Repositório", selection: Binding(get: { model.repo ?? "" }, set: { p in Task { await model.selectRepo(p) } })) {
                    ForEach(model.repos) { Text($0.label).tag($0.path) }
                }.labelsHidden().fixedSize()
            }
            VStack(spacing: 10) {
                tabs
                TextField("Buscar na memória", text: $query).collieField()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Color.collieBorder).frame(height: 1)
        }
    }

    /// Segmented: the selected tab on `surface`; Revisar shows its count (text, in `attention`).
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(MemoryPanelModel.Tab.allCases, id: \.self) { t in
                let on = model.tab == t
                Button { model.tab = t } label: {
                    HStack(spacing: 4) {
                        Text(t.rawValue).font(.collieUI(13, on ? .semibold : .medium)).foregroundStyle(on ? Color.collieText : .collieTextSecondary)
                        if t == .review && !(model.unreviewed.isEmpty && model.proposals.isEmpty && model.lotMemories.isEmpty) {
                            Text("\(model.unreviewed.count + model.proposals.count + model.lotMemories.filter { !$0.record.reviewed }.count)").font(.collieMono(11)).foregroundStyle(Color.collieAttention)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.collieSurface : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)   // system focus ring is kept
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3).background(RoundedRectangle(cornerRadius: 10).fill(Color.collieSidebar))
    }

    /// The search box narrows what the tab lists (title, text, subject, path); the lists themselves don't change.
    private func shown(_ rows: [MemoryRow]) -> [MemoryRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { r in [r.record.title, r.record.body, r.record.subject, r.record.path ?? ""].contains { $0.localizedStandardContains(q) } }
    }

    private var problemsBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(model.problems.count) arquivo(s) com erro").font(.collieUI(12, .semibold)).foregroundStyle(Color.collieAttention)
            ForEach(model.problems) {
                Text("\(URL(fileURLWithPath: $0.file).lastPathComponent): \($0.error)").font(.collieMono(11)).foregroundStyle(Color.collieTextSecondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(Color.collieAttentionTint)
    }

    /// One digest row: title, reason, its actions.
    private func digestItem(_ e: DigestRow, @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CollieTag(e.isAsk ? "pergunta" : e.action, tone: e.isAsk ? .attention : .neutral)
                Text(relative.localizedString(for: e.at, relativeTo: Date())).font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                if e.undone { CollieTag("desfeito", tone: .neutral) }
            }
            Text(e.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText)
            if !e.reason.isEmpty { Text(e.reason).font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary) }
            HStack(spacing: 6) { actions() }.padding(.top, 2)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .collieCard(highlight: e.isAsk ? Color.collieAttention.opacity(0.5) : nil)
    }

    @ViewBuilder private var learning: some View {
        if let line = model.curatorLine {
            HStack {
                Text(line).font(.collieMono(12)).foregroundStyle(model.curator?.available == false ? Color.collieAttention : .collieTextSecondary)
                Spacer()
                if let c = model.curator {
                    Stepper("Limite diário: \(c.cap)", value: Binding(get: { c.cap }, set: { n in Task { await model.setCap(n) } }), in: 0...1_000)
                        .font(.collieUI(12)).fixedSize()
                }
            }
        }
        let groups = model.learningGroups()
        // procedures the curator noticed in the works: they wait for the user (approve → active → a skill)
        let noticed = model.proposals.filter { $0.record.kind == .procedure }
        if groups.isEmpty && noticed.isEmpty { empty("Nada aprendido nesta semana.") }
        if !noticed.isEmpty {
            section("Precisa de você")
            ForEach(noticed) { r in
                item(r, meta: meta(r), badge: "procedimento novo") {
                    act("Aprovar", .primary) { Task { await model.approve(r.id, lot: r.lot) } }
                    act("Descartar", .quiet) { Task { await model.discard(r.id, lot: r.lot) } }
                }
            }
        }
        ForEach(groups, id: \.title) { g in
            if !(g.title == "Precisa de você" && !noticed.isEmpty) { section(g.title) }
            ForEach(g.rows) { e in
                digestItem(e) {
                    if e.isAsk {
                        act("Manter a nova", .primary) { Task { await model.resolve(e, keepNewer: true) } }
                        act("Manter a antiga") { Task { await model.resolve(e, keepNewer: false) } }
                        if model.promoteSuggestion(e) != nil { act("Promover ao projeto") { Task { await model.promoteSuggested(e) } } }
                    } else if !e.undone {
                        act("Desfazer") { Task { await model.undo(e) } }
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .learning: learning
        case .review:
            if !model.proposals.isEmpty {
                section("Propostas")
                noMatch(model.proposals)
                ForEach(model.proposalGroups, id: \.lot) { g in
                    HStack {
                        Text(g.lot.map { "Lote \($0)" } ?? "Projeto").font(.collieUI(12, .semibold)).foregroundStyle(Color.collieTextSecondary)
                        Spacer()
                        act("Aprovar todas") { Task { await model.approveAll(lot: g.lot) } }
                    }
                    ForEach(shown(g.rows)) { r in
                        item(r, meta: meta(r), badge: "proposta") {
                            act("Aprovar", .primary) { Task { await model.approve(r.id, lot: r.lot) } }
                            act("Editar") { editing = r }
                            act("Descartar", .quiet) { Task { await model.discard(r.id, lot: r.lot) } }
                        }
                    }
                }
                section("Não revisadas")
            }
            if model.unreviewed.isEmpty { empty("Nada para revisar.") }
            noMatch(model.unreviewed)
            ForEach(shown(model.unreviewed)) { r in
                item(r, meta: meta(r)) {
                    act("Aprovar", .primary) { Task { await model.approve(r.id) } }
                    act("Editar") { editing = r }
                    act("Descartar", .quiet) { Task { await model.discard(r.id) } }
                }
            }
            if !model.lotMemories.isEmpty {
                section("Memórias dos lotes")
                noMatch(model.lotMemories)
                ForEach(model.lotMemoryGroups, id: \.lot) { g in
                    Text("Lote \(g.lot)").font(.collieUI(12, .semibold)).foregroundStyle(Color.collieTextSecondary)
                    ForEach(shown(g.rows)) { r in
                        item(r, meta: meta(r), badge: r.record.reviewed ? nil : "não revisada") {
                            if !r.record.reviewed { act("Aprovar", .primary) { Task { await model.approve(r.id, lot: r.lot) } } }
                            act("Promover ao projeto") { Task { await model.promote(r.id, lot: g.lot) } }
                            act(r.record.pinned ? "desafixar" : "fixar") { Task { await model.pin(r.id, !r.record.pinned, lot: r.lot) } }
                            act("Arquivar") { Task { await model.archive(r.id, lot: r.lot) } }
                            act("Descartar", .quiet) { Task { await model.discard(r.id, lot: r.lot) } }
                        }
                    }
                }
            }
        case .decisions:
            if model.decisions.isEmpty { empty("Nenhuma decisão vigente.") }
            noMatch(model.decisions)
            ForEach(shown(model.decisions)) { r in
                let hist = model.history(of: r)
                item(r, meta: meta(r)) {
                    act(r.record.pinned ? "desafixar" : "fixar") { Task { await model.pin(r.id, !r.record.pinned) } }
                }
                if !hist.isEmpty {
                    DisclosureGroup("ver histórico (\(hist.count))") {
                        ForEach(hist) { h in
                            item(h, meta: "substituída · \(relative.localizedString(for: h.record.updatedAt, relativeTo: Date()))") {
                                act("↺ restaurar") { Task { await model.restore(h.id) } }
                            }
                        }
                    }.font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary).padding(.horizontal, 8)
                }
            }
            if !model.procedures.isEmpty {
                section("Procedimentos")
                ForEach(shown(model.procedures)) { r in
                    item(r, meta: meta(r)) {
                        act(r.record.pinned ? "desafixar" : "fixar") { Task { await model.pin(r.id, !r.record.pinned) } }
                        act("Arquivar") { Task { await model.archive(r.id) } }
                    }
                }
            }
        case .map:
            if model.maps.isEmpty { empty("Nenhum mapa gravado.") }
            noMatch(model.maps)
            ForEach(shown(model.maps)) { r in
                item(r, meta: r.record.path ?? "", badge: r.missingSince != nil ? "caminho sumiu" : nil) {
                    if r.missingSince != nil { act("Arquivar") { Task { await model.archive(r.id) } } }
                }
            }
        case .cleanup:
            HStack {
                Text(model.plan.isEmpty ? "Nada a limpar." : "\(model.plan.count) item(ns) no plano").font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary)
                Spacer()
                Button("Aplicar limpeza") { Task { await model.applyCleanup() } }.disabled(model.plan.isEmpty).buttonStyle(CollieButtonStyle(.secondary))
            }
            ForEach(model.plan) { e in
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title(e.id)).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
                    Text(e.reason).font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).collieCard()
            }
            noMatch(model.archived + model.unchained + model.discarded)
            section("Arquivadas")
            ForEach(shown(model.archived)) { r in
                item(r, meta: meta(r)) { act("↺ restaurar") { Task { await model.restore(r.id) } } }
            }
            section("Substituídas sem cadeia")
            ForEach(shown(model.unchained)) { r in
                item(r, meta: meta(r)) { act("↺ restaurar") { Task { await model.restore(r.id) } } }
            }
            section("Descartadas")
            ForEach(shown(model.discarded)) { r in
                item(r, meta: meta(r)) { act("↺ restaurar") { Task { await model.restore(r.id) } } }
            }
            Button("Esvaziar descartadas…") { confirmPurge = true }.disabled(model.discarded.isEmpty).buttonStyle(CollieButtonStyle(.secondary))
        }
    }

    /// Author and when (the kind is the card's tag).
    private func meta(_ r: MemoryRow) -> String {
        "gravada por \(r.record.origin) · \(relative.localizedString(for: r.record.createdAt, relativeTo: Date()))"
    }
    private func section(_ s: String) -> some View { Text(s).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).padding(.top, 4) }
    /// The search filtered a non-empty list down to nothing.
    @ViewBuilder private func noMatch(_ rows: [MemoryRow]) -> some View {
        if !rows.isEmpty && shown(rows).isEmpty { empty("Nada encontrado.") }
    }
    private func empty(_ s: String) -> some View { Text(s).font(.collieUI(13)).foregroundStyle(Color.collieMuted).padding(.vertical, 4) }
    private func act(_ title: String, _ kind: CollieButtonStyle.Kind = .secondary, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(CollieButtonStyle(kind))
    }
    private func item(_ r: MemoryRow, meta: String, badge: String? = nil, @ViewBuilder actions: () -> some View) -> some View {
        let pitfall = r.record.kind == .pitfall
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CollieTag(r.record.kind.label, tone: pitfall ? .attention : r.record.kind == .decision ? .accent : .neutral)
                Text(meta).font(.collieMono(11)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle)
                if let badge { CollieTag(badge, tone: .attention) }
            }
            Text(r.record.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText)
            HStack(spacing: 6) { actions() }.padding(.top, 2)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .collieCard(highlight: pitfall ? Color.collieAttention.opacity(0.5) : nil)
    }
}

extension MemoryKind {
    /// The card tag's text.
    var label: String { switch self { case .feedback: "regra"; case .decision: "decisão"; case .map: "mapa"; case .pitfall: "armadilha"; case .procedure: "procedimento" } }
}

private struct EditSheet: View {
    let row: MemoryRow
    let save: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""
    @State private var subject = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editar memória").font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText)
            TextField("Título", text: $title).collieField()
            TextField("Assunto", text: $subject).collieField()
            TextEditor(text: $body_).font(.collieUI(13)).scrollContentBackground(.hidden).padding(6).frame(minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.collieSunken))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.collieBorder, lineWidth: 1))
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(CollieButtonStyle(.secondary))
                Button("Salvar e aprovar") { save(title, body_, subject); dismiss() }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || subject.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(CollieButtonStyle(.primary))
            }
        }.padding(20).frame(width: 380).background(Color.collieSurface)
        .onAppear { title = row.record.title; body_ = row.record.body; subject = row.record.subject }
    }
}
