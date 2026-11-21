import SwiftUI
import CollieClient
import CollieCore
import CollieTheme

/// M8.3: the Laços modal's model. Pure: built from the `Work` (`WorkFeed.work`), the terminals and a clock given by the
/// caller, or from a `WorkArchive`; every text from the work is kept as it came (the view shows it with `Text(verbatim:)`).
enum LoopsModal {
    static let idleText = "Nenhum laço rodando"

    /// The tab asked for; Histórico when no loop of the paddock runs (Em andamento would be empty).
    static func initialTab(_ requested: LoopsTab, running: Running?) -> LoopsTab { running == nil ? .history : requested }

    /// "Abrir no canvas": the Prévia artifact of before (`HistoryPage`, M7.1), through the old hook. Returns the hook's
    /// notice (`HistoryOpener.message`, fixed text) once it is done; nil means the Prévia opened (M9.1, B2).
    @MainActor static func openInCanvas(_ id: String, ctx: ShellContext) async -> String? {
        await ctx.onOpenHistory(id)
        return ctx.historyNotice()
    }

    /// The Histórico tab's state: the detail shown, the id being fetched and the fixed error text (M9.1).
    struct Load: Equatable {
        var detail: Detail?
        var loading: String?
        var error: String?
        /// A click on a row: the newest request wins.
        mutating func begin(_ id: String) { loading = id; error = nil }
        /// The fetch of `id` came back (`d` nil: it failed). An answer for an id no longer asked is dropped (B8).
        mutating func end(_ id: String, _ d: Detail?) {
            guard loading == id else { return }
            if let d { detail = d } else { error = HistoryOpener.failure }
            loading = nil
        }
        /// "Abrir no canvas" came back with the hook's notice; true when the modal may close (the Prévia opened, B2).
        /// The notice stays in the modal until the next try.
        mutating func canvas(_ notice: String?) -> Bool {
            error = notice
            return notice == nil
        }
    }

    struct TaskLine: Equatable, Identifiable {
        var row: LoopSection.TaskRow
        /// The newest attempt's agent: its terminal's name while it lives, else the agent's name (the job's id).
        var agent: String?
        /// The live terminal a click focuses; nil when it is gone (or none ran).
        var terminal: UUID?
        /// How long the attempt under way has run ("4 min"); nil unless this task runs now.
        var elapsed: String?
        var id: String { row.id }
        var agentText: String {
            guard let agent else { return "—" }
            return terminal == nil ? "\(agent) · encerrado" : agent
        }
    }

    struct Running: Equatable {
        var title: String
        var progress: String
        var fraction: Double
        /// "check rodando" (`LoopCard.phase`).
        var phase: String
        var since: String?
        /// "turno de até 30 min" (`WorkLoopState.timeout`).
        var turnLimit: String
        var tasks: [TaskLine]
    }

    /// The paddock's running loop (the same rule as the Trilho card); nil when none runs.
    static func running(work: Work?, paddock: UUID?, terminals: [TerminalRecord], now: Date, timeZone: TimeZone = .current) -> Running? {
        let s = LoopSection.make(work: work, paddock: paddock, timeZone: timeZone)
        guard let card = LoopCard.make(work: work, paddock: paddock), let w = work, let loop = w.loop else { return nil }
        let names = Dictionary(terminals.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let lines = s.rows.map { r in
            // ponytail: jobs carry the task's title, not its id (as `LoopSection.agent`)
            let job = w.jobs.last { $0.kind == .loop && $0.label == r.title }
            let live = job?.terminal.flatMap { t in names[t].map { (t, $0) } }
            let elapsed = r.state == .running && job?.state == .running ? job.map { HistoryRow.duration(Int(now.timeIntervalSince($0.startedAt))) } : nil
            return TaskLine(row: r, agent: live?.1 ?? job?.id, terminal: live?.0, elapsed: elapsed)
        }
        return Running(title: card.title, progress: card.progressText, fraction: card.fraction, phase: card.phase,
                       since: s.header?.since, turnLimit: "turno de até " + HistoryRow.duration(loop.timeout), tasks: lines)
    }

    /// A closed work's detail inside the modal: what `HistoryPage` shows, as plain values.
    struct Detail: Equatable {
        struct Fact: Equatable, Hashable { var label: String; var value: String }
        struct TaskLine: Equatable, Identifiable {
            var id: String, title: String, state: String, tries: String
            var commits: [String], why: [String]
            /// M10.3: the task's counts ("tokens: …"); nil: the archive has none.
            var tokens: String? = nil
        }
        struct EventLine: Equatable, Identifiable {
            var id: Int, time: String, task: String, kind: String, detail: String
        }
        var id: String, title: String
        var notices: [String]
        var facts: [Fact]
        var tasks: [TaskLine]
        var timeline: [EventLine]
        var loopSummary: String
        var notes: [String]
        /// M10.3: the work's counts in all ("tokens: …"); nil: the archive has none (written before, or no attempt read).
        var tokens: String?

        init(_ a: WorkArchive, timeZone: TimeZone = .current) {
            id = a.id; title = a.title
            notices = (a.reconstructed ? [HistoryPage.reconstructedNotice] : []) + (a.truncated ? [HistoryPage.truncatedNotice] : [])
            facts = HistoryPage.facts(for: a, timeZone: timeZone).map { Fact(label: $0.label, value: $0.value) }
            tasks = a.tasks.map { t in
                TaskLine(id: t.id, title: t.title, state: Self.state(t.state), tries: "\(t.tries)",
                         commits: t.commits.map { String($0.prefix(8)) }, why: [t.failure, t.evidenceNote].compactMap { $0 },
                         tokens: WorkArchive.tokensLine(t.tokens))
            }
            tokens = WorkArchive.tokensLine(a.tokens)
            // the daemon already cuts at 500; an older or foreign archive is cut here too (the newest kept)
            timeline = a.timeline.suffix(WorkArchive.timelineMax).enumerated().map { i, e in
                EventLine(id: i, time: HistoryPage.format("HH:mm:ss", e.at, timeZone), task: e.task ?? "", kind: e.kind, detail: e.detail)
            }
            loopSummary = a.loopSummary; notes = a.notes
        }

        /// The archive's raw state in words; an unknown one as it came.
        static func state(_ raw: String) -> String {
            switch TaskState(rawValue: raw) {
            case .done?: "feita"; case .deferred?: "adiada"; case .open?: "aberta"; case .inProgress?: "rodando"; case .abandoned?: "abandonada"
            case nil: raw
            }
        }
    }
}

/// M8.3: the "Laços" sheet (`ctx.onOpenLoops`): Em andamento (the running loop, live through `WorkFeed`) and Histórico
/// (the last 20; a click shows the detail here). Tab and selection are `@State`: nothing kept between openings.
struct LoopsSheet: View {
    let ctx: ShellContext
    @Environment(\.dismiss) private var dismiss
    @State private var tab: LoopsTab
    @State private var load = LoopsModal.Load()

    init(ctx: ShellContext, initial: LoopsTab) {
        self.ctx = ctx
        let c = ctx.client
        _tab = State(initialValue: LoopsModal.initialTab(initial, running: LoopsModal.running(work: c.workFeed.work, paddock: c.currentPaddock,
                                                                                              terminals: c.terminals, now: Date())))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Laços").font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText)
                Spacer()
                Picker("Aba", selection: $tab) {
                    Text("Em andamento").tag(LoopsTab.running)
                    Text("Histórico").tag(LoopsTab.history)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Group {
                switch tab {
                case .running: runningTab
                case .history: if let d = load.detail { detailView(d) } else { historyTab }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = load.error { Text(verbatim: error).foregroundStyle(Color.collieDanger).font(.collieUI(12)) }
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(CollieButtonStyle(.secondary))
        .padding(24).frame(width: 720, height: 520).background(Color.collieSurface)
    }

    // MARK: Em andamento

    private var runningTab: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            let c = ctx.client
            if let r = LoopsModal.running(work: c.workFeed.work, paddock: c.currentPaddock, terminals: c.terminals, now: tl.date) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(verbatim: r.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(verbatim: r.progress).font(.collieMono(12)).monospacedDigit().foregroundStyle(Color.collieSecondary)
                    }
                    LoopProgressBar(fraction: r.fraction)
                    Text(verbatim: [r.phase, r.since, r.turnLimit].compactMap { $0 }.joined(separator: " · "))
                        .font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { ForEach(r.tasks) { taskRow($0) } }
                    }
                }
            } else {
                Text(LoopsModal.idleText).font(.collieUI(13)).foregroundStyle(Color.collieMuted)
            }
        }
    }

    private func taskRow(_ t: LoopsModal.TaskLine) -> some View {
        HStack(spacing: 8) {
            LoopStateIcon(state: t.row.state)
            Text(verbatim: t.row.title).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(verbatim: t.row.triesText).font(.collieMono(11)).foregroundStyle(Color.collieMuted).frame(width: 96, alignment: .leading)
            Button { if let id = t.terminal { dismiss(); ctx.focus(id) } } label: {
                Text(verbatim: t.agentText).font(.collieMono(11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(t.terminal == nil ? Color.collieMuted : Color.collieAccent)
            }
            .buttonStyle(.plain).disabled(t.terminal == nil).frame(width: 180, alignment: .leading)
            .help(t.terminal == nil ? "Terminal encerrado" : "Focar o terminal")
            Text(verbatim: t.elapsed ?? "").font(.collieMono(11)).monospacedDigit().foregroundStyle(Color.collieMuted).frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([t.row.accessibilityLabel, t.agent.map { _ in "agente \(t.agentText)" }, t.elapsed].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: Histórico

    private var historyTab: some View {
        let rows = HistorySection.make(ctx.client.workFeed.history).rows
        return Group {
            if rows.isEmpty {
                Text("Nenhum laço no histórico").font(.collieUI(13)).foregroundStyle(Color.collieMuted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { ForEach(rows) { historyRow($0) } }
                }
            }
        }
    }

    private func historyRow(_ r: HistoryRow) -> some View {
        Button { Task { await open(r.id) } } label: {
            HStack(spacing: 8) {
                Circle().fill(color(r.outcome)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: r.title).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                    Text(verbatim: r.detailText).font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                }
                Spacer(minLength: 8)
                if load.loading == r.id { ProgressView().controlSize(.small) }
                Text(verbatim: r.stopText).font(.collieUI(12)).foregroundStyle(color(r.outcome))
            }
            .padding(.vertical, 6).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([r.title, r.detailText, r.stopText].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    private func color(_ o: HistoryRow.Outcome) -> Color {
        switch o { case .complete: .collieSecondary; case .withDeferred: .collieAttention; case .stopped: .collieDanger }
    }

    private func open(_ id: String) async {
        load.begin(id)
        let d = try? await ctx.fetchHistory(id)
        load.end(id, d.map { LoopsModal.Detail($0) })
    }

    // MARK: Detalhe

    private func detailView(_ d: LoopsModal.Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("‹ Histórico") { load.detail = nil; load.error = nil }.buttonStyle(.plain).foregroundStyle(Color.collieAccent)
                Spacer()
                Button("Abrir no canvas") {
                    load.error = nil
                    Task { if load.canvas(await LoopsModal.openInCanvas(d.id, ctx: ctx)) { dismiss() } }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: d.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText)
                    ForEach(Array(d.notices.enumerated()), id: \.offset) { _, n in
                        Text(verbatim: n).font(.collieUI(12)).foregroundStyle(Color.collieText).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.collieAttention.opacity(0.15), in: .rect(cornerRadius: 6))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(Array(d.facts.enumerated()), id: \.offset) { _, f in
                            GridRow {
                                Text(verbatim: f.label).foregroundStyle(Color.collieMuted)
                                Text(verbatim: f.value).foregroundStyle(Color.collieText).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.collieUI(12))
                    if let tk = d.tokens { Text(verbatim: tk).font(.collieUI(12)).foregroundStyle(Color.collieMuted) }
                    heading("TAREFAS")
                    ForEach(d.tasks) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(verbatim: "\(t.id) \(t.title)").foregroundStyle(Color.collieText)
                                Spacer(minLength: 8)
                                Text(verbatim: "\(t.state) · \(t.tries) tentativas").foregroundStyle(Color.collieMuted)
                            }
                            .font(.collieUI(12))
                            if let tk = t.tokens { Text(verbatim: tk).font(.collieUI(11)).foregroundStyle(Color.collieMuted) }
                            if !t.commits.isEmpty { Text(verbatim: t.commits.joined(separator: " ")).font(.collieMono(11)).foregroundStyle(Color.collieMuted) }
                            ForEach(Array(t.why.enumerated()), id: \.offset) { Text(verbatim: $0.element).font(.collieUI(11)).foregroundStyle(Color.collieMuted) }
                        }
                        .padding(.vertical, 3)
                    }
                    heading("LINHA DO TEMPO")
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(d.timeline) { e in
                            GridRow {
                                Text(verbatim: e.time).monospacedDigit()
                                Text(verbatim: e.task)
                                Text(verbatim: e.kind)
                                Text(verbatim: e.detail).foregroundStyle(Color.collieText)
                            }
                        }
                    }
                    .font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                    if !d.loopSummary.isEmpty { heading("RESUMO DO LAÇO"); Text(verbatim: d.loopSummary).font(.collieUI(12)) }
                    if !d.notes.isEmpty { heading("NOTAS"); ForEach(Array(d.notes.enumerated()), id: \.offset) { Text(verbatim: $0.element).font(.collieUI(12)) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).padding(.top, 6).accessibilityAddTraits(.isHeader)
    }
}
