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
    public static let statsPeriods: [(label: String, value: String)] = [("24 h", "24h"), ("7 dias", "7d"), ("30 dias", "30d"), ("90 dias", "90d")]

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
        if rep >= 3 { out.append("\(rep) correções repetidas nesta semana: a memória não está evitando o mesmo erro.") }
        let m = r.maintenance
        if m.curatorFailed > 0 || m.curatorRunFailures >= 3 {
            out.append("Curador falhando: \(m.curatorRunFailures) chamada(s) com erro no período, \(m.curatorFailed) trabalho(s) parado(s) em failed/.")
        }
        if m.curatorQueued > 0, m.lastCuratorRun.map({ now.timeIntervalSince($0) > 86_400 }) ?? true {
            out.append("Fila do curador parada: \(m.curatorQueued) trabalho(s) esperando, nenhuma execução nas últimas 24 h.")
        }
        if let d = r.usage.deadShare, d > 0.5, let s = r.logSince, now.timeIntervalSince(s) >= 30 * 86_400 {
            out.append("\(percent(d)) das memórias com mais de 30 dias não foram usadas nos últimos 30 dias.")
        }
        return out
    }

    /// "Tokens por tarefa: 12 mil → 9 mil (−25%)" — this week against the one before; "sem dados" when either is missing.
    public static func trendLine(_ label: String, current: Double?, previous: Double?, format: (Double) -> String) -> String {
        guard let c = current, let p = previous else { return "\(label): sem dados para comparar" }
        let change = p == 0 ? "" : " (\(c >= p ? "+" : "−")\(percent(abs(c - p) / p)))"
        return "\(label): \(format(p)) → \(format(c))\(change)"
    }

    static let ptBR = Locale(identifier: "pt_BR")
    public static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
    /// 812, "18 mil", "1,2 mi".
    public static func tokens(_ t: Int) -> String {
        t < 1_000 ? "\(t)" : t < 1_000_000 ? "\(Int((Double(t) / 1_000).rounded())) mil"
            : (Double(t) / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(ptBR)) + " mi"
    }
    public static func usd(_ x: Double) -> String { "US$ " + x.formatted(.number.precision(.fractionLength(2)).locale(ptBR)) }
    static let sourceLabels = ["correction": "correção", "conversation": "conversa", "proposal": "proposta", "review": "revisão",
                               "consolidation": "consolidação", "agent": "agente", "user": "você"]
}

/// Memória — Observabilidade: is memory used, kept up and worth its tokens. No savings figure: only trends (the caveat).
struct MemoryObservabilityView: View {
    @ObservedObject var model: MemoryPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            if let r = model.stats { report(r) } else { Text("Sem dados ainda.").font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("Período", selection: Binding(get: { model.statsSince }, set: { model.statsSince = $0; reload() })) {
                ForEach(MemoryPanelModel.statsPeriods, id: \.value) { Text($0.label).tag($0.value) }
            }.fixedSize()
            Picker("Projeto", selection: Binding(get: { model.statsProject ?? "" }, set: { model.statsProject = $0.isEmpty ? nil : $0; reload() })) {
                Text("Todos").tag("")
                ForEach(model.repos.filter { $0.scope != "global" }) { Text($0.label).tag($0.path) }
            }.fixedSize()
            Picker("Lote", selection: Binding(get: { model.statsLot ?? "" }, set: { model.statsLot = $0.isEmpty ? nil : $0; reload() })) {
                Text("Todos").tag("")
                ForEach(model.lotList, id: \.self) { Text($0).tag($0) }
            }.fixedSize()
            Spacer()
            Button("Exportar JSON") { export() }.disabled(model.stats == nil).buttonStyle(CollieButtonStyle(.secondary))
        }.font(.collieUI(12))
    }

    private func reload() { Task { await model.loadStats() } }

    private func export() {
        guard let data = model.statsExport() else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]; p.nameFieldStringValue = "memoria-observabilidade.json"
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
        card("Uso") {
            line("Cobertura: " + (u.coverage.map(MemoryPanelModel.percent) ?? "–") + " dos prompts com memória (\(u.promptsWithMemory) de \(u.prompts))")
            line("Buscas dos agentes: \(u.searches) (\(u.searchHits) resultados)")
            bars("Injeções por dia", u.injectionsPerDay)
            if !u.top.isEmpty { sub("Mais usadas"); ForEach(u.top) { memory($0, "\($0.count)×", archive: false) } }
            if !u.dead.isEmpty {
                sub("Sem uso em 30 dias" + (u.deadShare.map { " (\(MemoryPanelModel.percent($0)))" } ?? ""))
                ForEach(u.dead.prefix(10)) { memory($0, nil, archive: true) }
            }
        }
        card("Manutenção") {
            let made = m.createdBySource.sorted { $0.value > $1.value }
                .map { "\(MemoryPanelModel.sourceLabels[$0.key] ?? $0.key) \($0.value)" }.joined(separator: " · ")
            line("Criadas: " + (made.isEmpty ? "nenhuma" : made))
            line("Desfeitas: \(m.undone)" + (m.undonePct.map { " (\(MemoryPanelModel.percent($0)))" } ?? "") + " · substituídas \(m.supersedes) · mescladas \(m.merges)")
            line("Retiradas avisadas: \(m.retractionsDelivered) · consolidações \(m.consolidations) · arquivadas por pontuação baixa \(m.archivedLowScore)")
            line("Precisa de você: \(m.pendingAsks) confirmação(ões) · \(m.openContradictions) contradição(ões)")
            line("Idade média: " + (m.averageAgeDays.map { "\(Int($0.rounded())) dias" } ?? "–")
                 + " · pontuação média " + (m.averageScore.map { $0.formatted(.number.precision(.fractionLength(2)).locale(MemoryPanelModel.ptBR)) } ?? "–"))
            line("Curador: \(m.curatorRuns) execuções (\(m.curatorRunFailures) com erro) · fila \(m.curatorQueued) · parados \(m.curatorFailed)")
        }
        card("Aprendizado") {
            line("Correções: \(r.learning.corrections) · repetidas em até 14 dias: \(r.learning.repeatCorrections)")
            ForEach(r.learning.repeats) { x in
                HStack(spacing: 8) {
                    Text("\(x.subject) — \(x.repeats)× de novo").font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                    Spacer()
                    if let id = x.memory, let row = model.activeRow(id), let f = row.file { act("Abrir") { open(f) } }
                }
            }
            line(MemoryPanelModel.trendLine("Correções repetidas por semana", current: Double(t.current.repeatCorrections),
                                            previous: Double(t.previous.repeatCorrections)) { "\(Int($0))" })
        }
        card("Custo") {
            line("Curador: \(MemoryPanelModel.tokens(c.curatorTokens)) tokens · \(MemoryPanelModel.usd(c.curatorUSD))")
            line("Injetado nas sessões: ~\(MemoryPanelModel.tokens(c.injectedTokens)) tokens (estimativa: bytes ÷ 4)")
            line("Sessões: \(MemoryPanelModel.tokens(c.sessionInput)) entrada · \(MemoryPanelModel.tokens(c.sessionOutput)) saída · "
                 + "\(MemoryPanelModel.tokens(c.sessionCacheRead)) cache lido · \(MemoryPanelModel.tokens(c.sessionCacheCreation)) cache criado")
            line("Por tarefa concluída: " + (c.sessionTokensPerTask.map { MemoryPanelModel.tokens(Int($0)) + " tokens" } ?? "–") + " (\(c.completedTasks) tarefas)")
            bars("Tokens das sessões por dia", c.sessionTokensPerDay)
            bars("Tokens do curador por dia", c.curatorTokensPerDay)
            line(MemoryPanelModel.trendLine("Tokens por tarefa", current: t.current.tokensPerTask, previous: t.previous.tokensPerTask) {
                MemoryPanelModel.tokens(Int($0))
            })
            line(MemoryPanelModel.trendLine("Buscas por tarefa", current: t.current.searchesPerTask, previous: t.previous.searchesPerTask) {
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
            if let f = row?.file { act("Abrir") { open(f) } }
            if archive, let row { act("Arquivar") { Task { await model.archive(row.id, lot: row.lot); await model.loadStats() } } }
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
