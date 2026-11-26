import AppKit
import Foundation
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI
import UniformTypeIdentifiers

/// `memory.stats` as the panel reads it (the daemon's `MemoryObservability.Report`).
public struct MemoryStatsReport: Decodable, Equatable, Sendable {
    public struct Day: Decodable, Equatable, Sendable { public let day: String; public let value: Double }
    public struct Ref: Decodable, Equatable, Sendable, Identifiable { public let id: UUID; public let title: String?; public let count: Int }
    public struct Repeat: Decodable, Equatable, Sendable, Identifiable {
        public let subject: String, corrections: Int, repeats: Int, last: Date, memory: UUID?
        public var id: String { subject }
    }
    public struct Usage: Decodable, Equatable, Sendable {
        public let injectionsPerDay: [Day], prompts: Int, promptsWithMemory: Int, coverage: Double?
        public let top: [Ref], dead: [Ref], deadShare: Double?, searches: Int, searchHits: Int
        /// Leva 1; nil from a daemon older than it.
        public let precision: Precision?
        /// Item 2 phase 1; nil from a daemon older than it.
        public let evidence: Evidence?
    }
    /// The daemon's `MemoryObservability.Precision` (its doc says what each count is).
    public struct Precision: Decodable, Equatable, Sendable {
        public let injected: Int, candidates: Int, used: Int, corrected: Int, unresolved: Int, flags: Int, rate: Double?
        /// The definition's version; nil from a daemon before item 2 (that one is 1).
        public var def: Int? = nil
    }
    /// The daemon's `MemoryObservability.Evidence`.
    public struct Evidence: Decodable, Equatable, Sendable {
        public let def: Int, candidates: Int, evidenced: Int, rate: Double?, byKind: [String: Int]
    }
    public struct Maintenance: Decodable, Equatable, Sendable {
        public let createdBySource: [String: Int], undone: Int, undonePct: Double?
        public let merges: Int, supersedes: Int, retractionsDelivered: Int, consolidations: Int, archivedLowScore: Int
        public let pendingAsks: Int, openContradictions: Int, averageAgeDays: Double?, averageScore: Double?
        public let curatorQueued: Int, curatorFailed: Int, curatorRuns: Int, curatorRunFailures: Int, lastCuratorRun: Date?
    }
    public struct Learning: Decodable, Equatable, Sendable { public let corrections: Int, repeatCorrections: Int, repeats: [Repeat] }
    public struct Cost: Decodable, Equatable, Sendable {
        public let curatorTokensPerDay: [Day], curatorUSDPerDay: [Day], injectedTokensPerDay: [Day], sessionTokensPerDay: [Day]
        public let curatorTokens: Int, curatorUSD: Double, injectedTokens: Int
        public let sessionInput: Int, sessionOutput: Int, sessionCacheRead: Int, sessionCacheCreation: Int
        public let completedTasks: Int, sessionTokensPerTask: Double?
    }
    public struct Week: Decodable, Equatable, Sendable {
        public let start: Date, tokensPerTask: Double?, searchesPerTask: Double?, coverage: Double?, repeatCorrections: Int, completedTasks: Int
    }
    public struct Trends: Decodable, Equatable, Sendable { public let current: Week, previous: Week }
    public let since: Date, until: Date, logSince: Date?, caveat: String
    public let usage: Usage, maintenance: Maintenance, learning: Learning, cost: Cost, trends: Trends
}

extension MemoryPanelModel {
    public static var statsPeriods: [(label: String, value: String)] = [("24 h", "24h"), (tr("7 dias", "7 days"), "7d"), (tr("30 dias", "30 days"), "30d"), (tr("90 dias", "90 days"), "90d")]

    public func loadStats() async {
        var a: [String: JSONValue] = ["since": .string(statsSince)]
        if let statsProject { a["project"] = .string(statsProject) }
        if let statsLot { a["lot"] = .string(statsLot) }
        guard let v = await send("memory.stats", a) else { return }
        statsJSON = v
        stats = decode(v)
    }

    /// The report as received, pretty-printed (Exportar JSON).
    public func statsExport() -> Data? {
        guard let statsJSON else { return nil }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? e.encode(statsJSON)
    }

    /// The row of an active memory (Abrir opens its file, Arquivar needs its lot).
    public func activeRow(_ id: UUID) -> MemoryRow? { (active + lotMemories).first { $0.id == id } }

    /// What needs a look: repeat corrections ≥ 3 this week, a failing curator, a stuck queue (> 24 h without a run), more
    /// than half the memories dead (only once the log covers the 30 days that takes).
    public static func alerts(_ r: MemoryStatsReport, now: Date = Date()) -> [String] {
        var out: [String] = []
        let rep = r.trends.current.repeatCorrections
        if rep >= 3 { out.append(tr("\(rep) correções repetidas nesta semana: a memória não está evitando o mesmo erro.", "\(rep) repeated corrections this week: memory is not preventing the same mistake.")) }
        let m = r.maintenance
        if m.curatorFailed > 0 || m.curatorRunFailures >= 3 {
            out.append(tr("Curador falhando: \(m.curatorRunFailures) chamada(s) com erro no período, \(m.curatorFailed) trabalho(s) parado(s) em failed/.", "Curator failing: \(m.curatorRunFailures) call(s) with errors in the period, \(m.curatorFailed) job(s) stuck in failed/."))
        }
        if m.curatorQueued > 0, m.lastCuratorRun.map({ now.timeIntervalSince($0) > 86_400 }) ?? true {
            out.append(tr("Fila do curador parada: \(m.curatorQueued) trabalho(s) esperando, nenhuma execução nas últimas 24 h.", "Curator queue stalled: \(m.curatorQueued) job(s) waiting, no run in the last 24 h."))
        }
        if let d = r.usage.deadShare, d > 0.5, let s = r.logSince, now.timeIntervalSince(s) >= 30 * 86_400 {
            out.append(tr("\(percent(d)) das memórias com mais de 30 dias não foram usadas nos últimos 30 dias.", "\(percent(d)) of memories older than 30 days were not used in the last 30 days."))
        }
        return out
    }

    /// "Tokens por tarefa: 12 mil → 9 mil (−25%)" — this week against the one before; "sem dados" when either is missing.
    public static func trendLine(_ label: String, current: Double?, previous: Double?, format: (Double) -> String) -> String {
        guard let c = current, let p = previous else { return tr("\(label): sem dados para comparar", "\(label): no data to compare") }
        let change = p == 0 ? "" : " (\(c >= p ? "+" : "−")\(percent(abs(c - p) / p)))"
        return "\(label): \(format(p)) → \(format(c))\(change)"
    }

    /// "Precisão: 50% das memórias injetadas por relevância foram usadas (1 de 2; …)" beside the coverage line.
    public static func precisionLine(_ p: MemoryStatsReport.Precision?) -> String {
        guard let p else { return tr("Precisão: o daemon instalado ainda não mede", "Precision: the installed daemon does not measure this yet") }
        guard let rate = p.rate else { return tr("Precisão: – (nenhuma memória injetada por relevância pode contar uso no período)", "Precision: – (no memory injected by relevance can count as used in the period)") }
        return tr("Precisão: \(percent(rate)) das memórias injetadas por relevância foram usadas (\(p.used) de \(p.candidates); ", "Precision: \(percent(rate)) of memories injected by relevance were used (\(p.used) of \(p.candidates); ")
            + tr("\(p.corrected) corrigidas, \(p.unresolved) sem desfecho)", "\(p.corrected) corrected, \(p.unresolved) unresolved)")
    }

    /// "Uso com evidência: 5% das memórias injetadas por relevância (2 de 40; citação 2 · leitura 1 · marcação 0)".
    public static func evidenceLine(_ e: MemoryStatsReport.Evidence?) -> String {
        guard let e else { return tr("Uso com evidência: o daemon instalado ainda não mede", "Use with evidence: the installed daemon does not measure this yet") }
        let kinds = tr("citação \(e.byKind["cite"] ?? 0) · leitura \(e.byKind["get"] ?? 0) · marcação \(e.byKind["flag"] ?? 0)", "citation \(e.byKind["cite"] ?? 0) · read \(e.byKind["get"] ?? 0) · flag \(e.byKind["flag"] ?? 0)")
        guard let rate = e.rate else { return tr("Uso com evidência: – (\(kinds))", "Use with evidence: – (\(kinds))") }
        return tr("Uso com evidência: \(percent(rate)) das memórias injetadas por relevância (\(e.evidenced) de \(e.candidates); \(kinds))", "Use with evidence: \(percent(rate)) of memories injected by relevance (\(e.evidenced) of \(e.candidates); \(kinds))")
    }

    static var ptBR: Locale { Locale(identifier: tr("pt_BR", "en_US")) }
    public static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
    /// 812, "18 mil", "1,2 mi".
    public static func tokens(_ t: Int) -> String {
        t < 1_000 ? "\(t)" : t < 1_000_000 ? "\(Int((Double(t) / 1_000).rounded()))" + tr(" mil", "k")
            : (Double(t) / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(ptBR)) + tr(" mi", "M")
    }
    public static func usd(_ x: Double) -> String { tr("US$ ", "$") + x.formatted(.number.precision(.fractionLength(2)).locale(ptBR)) }
    static var sourceLabels: [String: String] { ["correction": tr("correção", "correction"), "conversation": tr("conversa", "conversation"), "proposal": tr("proposta", "proposal"), "review": tr("revisão", "review"),
                               "consolidation": tr("consolidação", "consolidation"), "agent": tr("agente", "agent"), "user": tr("você", "you")] }
}

/// Memória — Observabilidade: is memory used, kept up and worth its tokens. No savings figure: only trends (the caveat).
struct MemoryObservabilityView: View {
    @ObservedObject var model: MemoryPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            if let r = model.stats { report(r) } else { Text(tr("Sem dados ainda.", "No data yet.")).font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker(tr("Período", "Period"), selection: Binding(get: { model.statsSince }, set: { model.statsSince = $0; reload() })) {
                ForEach(MemoryPanelModel.statsPeriods, id: \.value) { Text($0.label).tag($0.value) }
            }.fixedSize()
            Picker(tr("Projeto", "Project"), selection: Binding(get: { model.statsProject ?? "" }, set: { model.statsProject = $0.isEmpty ? nil : $0; reload() })) {
                Text(tr("Todos", "All")).tag("")
                ForEach(model.repos.filter { $0.scope != "global" }) { Text($0.label).tag($0.path) }
            }.fixedSize()
            Picker(tr("Lote", "Lot"), selection: Binding(get: { model.statsLot ?? "" }, set: { model.statsLot = $0.isEmpty ? nil : $0; reload() })) {
                Text(tr("Todos", "All")).tag("")
                ForEach(model.lotList, id: \.self) { Text($0).tag($0) }
            }.fixedSize()
            Spacer()
            Button(tr("Exportar JSON", "Export JSON")) { export() }.disabled(model.stats == nil).buttonStyle(CollieButtonStyle(.secondary))
        }.font(.collieUI(12))
    }

    private func reload() { Task { await model.loadStats() } }

    private func export() {
        guard let data = model.statsExport() else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]; p.nameFieldStringValue = tr("memoria-observabilidade.json", "memory-observability.json")
        if p.runModal() == .OK, let url = p.url { try? data.write(to: url) }
    }

    @ViewBuilder private func report(_ r: MemoryStatsReport) -> some View {
        Text(r.caveat.prefix(1).uppercased() + r.caveat.dropFirst() + ".")
            .font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary)
        ForEach(MemoryPanelModel.alerts(r), id: \.self) { a in
            Text(a).font(.collieUI(12, .semibold)).foregroundStyle(Color.collieAttention)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).collieCard(highlight: Color.collieAttention)
        }
        let u = r.usage, m = r.maintenance, c = r.cost, t = r.trends
        card(tr("Uso", "Usage")) {
            line(tr("Cobertura: ", "Coverage: ") + (u.coverage.map(MemoryPanelModel.percent) ?? "–") + tr(" dos prompts com memória (\(u.promptsWithMemory) de \(u.prompts))", " of prompts with memory (\(u.promptsWithMemory) of \(u.prompts))"))
            line(MemoryPanelModel.precisionLine(u.precision))
            line(MemoryPanelModel.evidenceLine(u.evidence))
            line(tr("Buscas dos agentes: \(u.searches) (\(u.searchHits) resultados)", "Agent searches: \(u.searches) (\(u.searchHits) results)"))
            bars(tr("Injeções por dia", "Injections per day"), u.injectionsPerDay)
            if !u.top.isEmpty { sub(tr("Mais usadas", "Most used")); ForEach(u.top) { memory($0, "\($0.count)×", archive: false) } }
            if !u.dead.isEmpty {
                sub(tr("Sem uso em 30 dias", "Unused in 30 days") + (u.deadShare.map { " (\(MemoryPanelModel.percent($0)))" } ?? ""))
                ForEach(u.dead.prefix(10)) { memory($0, nil, archive: true) }
            }
        }
        card(tr("Manutenção", "Maintenance")) {
            let made = m.createdBySource.sorted { $0.value > $1.value }
                .map { "\(MemoryPanelModel.sourceLabels[$0.key] ?? $0.key) \($0.value)" }.joined(separator: " · ")
            line(tr("Criadas: ", "Created: ") + (made.isEmpty ? tr("nenhuma", "none") : made))
            line(tr("Desfeitas: \(m.undone)", "Undone: \(m.undone)") + (m.undonePct.map { " (\(MemoryPanelModel.percent($0)))" } ?? "") + tr(" · substituídas \(m.supersedes) · mescladas \(m.merges)", " · superseded \(m.supersedes) · merged \(m.merges)"))
            line(tr("Retiradas avisadas: \(m.retractionsDelivered) · consolidações \(m.consolidations) · arquivadas por pontuação baixa \(m.archivedLowScore)", "Retractions delivered: \(m.retractionsDelivered) · consolidations \(m.consolidations) · archived for low score \(m.archivedLowScore)"))
            line(tr("Precisa de você: \(m.pendingAsks) confirmação(ões) · \(m.openContradictions) contradição(ões)", "Needs you: \(m.pendingAsks) confirmation(s) · \(m.openContradictions) contradiction(s)"))
            line(tr("Idade média: ", "Average age: ") + (m.averageAgeDays.map { tr("\(Int($0.rounded())) dias", "\(Int($0.rounded())) days") } ?? "–")
                 + tr(" · pontuação média ", " · average score ") + (m.averageScore.map { $0.formatted(.number.precision(.fractionLength(2)).locale(MemoryPanelModel.ptBR)) } ?? "–"))
            line(tr("Curador: \(m.curatorRuns) execuções (\(m.curatorRunFailures) com erro) · fila \(m.curatorQueued) · parados \(m.curatorFailed)", "Curator: \(m.curatorRuns) runs (\(m.curatorRunFailures) with errors) · queue \(m.curatorQueued) · stuck \(m.curatorFailed)"))
        }
        card(tr("Aprendizado", "Learning")) {
            line(tr("Correções: \(r.learning.corrections) · repetidas em até 14 dias: \(r.learning.repeatCorrections)", "Corrections: \(r.learning.corrections) · repeated within 14 days: \(r.learning.repeatCorrections)"))
            ForEach(r.learning.repeats) { x in
                HStack(spacing: 8) {
                    Text(tr("\(x.subject) — \(x.repeats)× de novo", "\(x.subject) — \(x.repeats)× again")).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                    Spacer()
                    if let id = x.memory, let row = model.activeRow(id), let f = row.file { act(tr("Abrir", "Open")) { open(f) } }
                }
            }
            line(MemoryPanelModel.trendLine(tr("Correções repetidas por semana", "Repeated corrections per week"), current: Double(t.current.repeatCorrections),
                                            previous: Double(t.previous.repeatCorrections)) { "\(Int($0))" })
        }
        card(tr("Custo", "Cost")) {
            line(tr("Curador: ", "Curator: ") + "\(MemoryPanelModel.tokens(c.curatorTokens)) tokens · \(MemoryPanelModel.usd(c.curatorUSD))")
            line(tr("Injetado nas sessões: ~\(MemoryPanelModel.tokens(c.injectedTokens)) tokens (estimativa: bytes ÷ 4)", "Injected into sessions: ~\(MemoryPanelModel.tokens(c.injectedTokens)) tokens (estimate: bytes ÷ 4)"))
            line(tr("Sessões: \(MemoryPanelModel.tokens(c.sessionInput)) entrada · \(MemoryPanelModel.tokens(c.sessionOutput)) saída · ", "Sessions: \(MemoryPanelModel.tokens(c.sessionInput)) input · \(MemoryPanelModel.tokens(c.sessionOutput)) output · ")
                 + tr("\(MemoryPanelModel.tokens(c.sessionCacheRead)) cache lido · \(MemoryPanelModel.tokens(c.sessionCacheCreation)) cache criado", "\(MemoryPanelModel.tokens(c.sessionCacheRead)) cache read · \(MemoryPanelModel.tokens(c.sessionCacheCreation)) cache created"))
            line(tr("Por tarefa concluída: ", "Per completed task: ") + (c.sessionTokensPerTask.map { MemoryPanelModel.tokens(Int($0)) + " tokens" } ?? "–") + tr(" (\(c.completedTasks) tarefas)", " (\(c.completedTasks) tasks)"))
            bars(tr("Tokens das sessões por dia", "Session tokens per day"), c.sessionTokensPerDay)
            bars(tr("Tokens do curador por dia", "Curator tokens per day"), c.curatorTokensPerDay)
            line(MemoryPanelModel.trendLine(tr("Tokens por tarefa", "Tokens per task"), current: t.current.tokensPerTask, previous: t.previous.tokensPerTask) {
                MemoryPanelModel.tokens(Int($0))
            })
            line(MemoryPanelModel.trendLine(tr("Buscas por tarefa", "Searches per task"), current: t.current.searchesPerTask, previous: t.previous.searchesPerTask) {
                $0.formatted(.number.precision(.fractionLength(1)).locale(MemoryPanelModel.ptBR))
            })
        }
    }

    private func card(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText)
            content()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).collieCard()
    }
    private func line(_ s: String) -> some View { Text(s).font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary) }
    private func sub(_ s: String) -> some View { Text(s).font(.collieUI(12, .semibold)).foregroundStyle(Color.collieText).padding(.top, 4) }
    private func act(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(CollieButtonStyle(.secondary))
    }
    private func open(_ file: String) { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }

    private func memory(_ ref: MemoryStatsReport.Ref, _ meta: String?, archive: Bool) -> some View {
        let row = model.activeRow(ref.id)
        return HStack(spacing: 8) {
            Text(ref.title ?? row?.record.title ?? String(ref.id.uuidString.prefix(8)).lowercased())
                .font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
            if let meta { Text(meta).font(.collieMono(11)).foregroundStyle(Color.collieMuted) }
            Spacer()
            if let f = row?.file { act(tr("Abrir", "Open")) { open(f) } }
            if archive, let row { act(tr("Arquivar", "Archive")) { Task { await model.archive(row.id, lot: row.lot); await model.loadStats() } } }
        }
    }

    /// ponytail: plain bars (no Charts dependency in the repo); the day and value are in the tooltip.
    private func bars(_ title: String, _ days: [MemoryStatsReport.Day]) -> some View {
        let top = max(days.map(\.value).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.collieUI(11)).foregroundStyle(Color.collieMuted)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days, id: \.day) { d in
                    RoundedRectangle(cornerRadius: 2).fill(Color.collieAccent.opacity(d.value > 0 ? 0.8 : 0.15))
                        .frame(height: max(2, 40 * d.value / top)).frame(maxWidth: 14)
                        .help("\(d.day): \(Int(d.value))")
                        .accessibilityLabel("\(d.day): \(Int(d.value))")
                }
            }.frame(height: 40, alignment: .bottom)
        }.padding(.top, 4)
    }
}
