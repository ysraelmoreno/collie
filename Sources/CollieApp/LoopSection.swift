import Foundation
import CollieCore
import CollieClient

/// The live loop of the Trilho context panel: what its section shows of the current paddock's active work. Pure: it takes
/// the `Work` (`WorkFeed.work`), never the client.
struct LoopSection: Equatable {
    enum State: Equatable { case done, running, deferred, open }
    struct TaskRow: Equatable, Identifiable {
        var id: String
        var title: String
        var state: State
        /// Attempts the loop used on this task, and the most it may use (`work run --tries`).
        var tries: Int
        var max: Int
        /// "tentativa 2/3".
        var triesText: String { "tentativa \(tries)/\(max)" }
        var stateText: String {
            switch state { case .done: "feita"; case .running: "rodando"; case .deferred: "adiada"; case .open: "aberta" }
        }
        /// What VoiceOver reads: the state in words, never only the icon.
        var accessibilityLabel: String { "\(title), \(stateText), \(triesText)" }
    }
    struct Header: Equatable {
        /// Short: "agente", "check", "portão" ("preparando" between phases).
        var phase: String
        /// "desde 02:02"; nil when the phase has no start.
        var since: String?
        /// Tasks done over the tasks the loop took: "3/6".
        var progress: String
    }
    var visible: Bool
    var rows: [TaskRow]
    var header: Header?

    /// "LAÇOS · 1/4" (done over taken).
    var title: String { "LAÇOS · " + (header?.progress ?? "0/0") }

    /// The terminal of the attempt a row stands for: the newest loop job of `work` that ran that task's title and
    /// recorded a terminal still in `alive`; nil when it is gone (the click then does nothing).
    // ponytail: jobs carry the task's title (`label`), not its id: two tasks with one title share the newest agent
    static func agent(forTask id: String, in work: Work?, alive: Set<UUID>) -> UUID? {
        guard let work, let title = work.tasks.first(where: { $0.id == id })?.title else { return nil }
        return work.jobs.last { $0.kind == .loop && $0.label == title && $0.terminal.map(alive.contains) == true }?.terminal
    }

    static let hidden = LoopSection(visible: false, rows: [], header: nil)

    /// Shown only while a loop of the active work of `paddock` is running (any phase). No work, a work of another paddock
    /// or a closed one, no loop, a finished or stopped loop: hidden.
    static func make(work: Work?, paddock: UUID?, timeZone: TimeZone = .current) -> LoopSection {
        guard let w = work, w.closedAt == nil, paddock != nil, w.paddockId == paddock,
              let loop = w.loop, loop.state == .running else { return .hidden }
        let mine = w.tasks.filter { $0.state != .abandoned && (loop.tasks?.contains($0.id) ?? true) }
        let rows = mine.map { t in
            TaskRow(id: t.id, title: t.title, state: state(of: t, loop: loop), tries: t.tries ?? 0, max: loop.tries)
        }
        let phase = loop.phase.map(shortPhase) ?? "preparando"
        let since = loop.phase == nil ? nil : loop.phaseSince.map { "desde " + hourMinute($0, timeZone) }
        return LoopSection(visible: true, rows: rows,
                           header: Header(phase: phase, since: since, progress: "\(rows.filter { $0.state == .done }.count)/\(rows.count)"))
    }

    private static func state(of t: WorkTask, loop: WorkLoopState) -> State {
        switch t.state {
        case .done: .done
        case .deferred: .deferred
        case .inProgress: .running
        case .open, .abandoned: t.id == loop.task ? .running : .open
        }
    }
    private static func shortPhase(_ p: WorkLoopState.Phase) -> String {
        switch p { case .agent: "agente"; case .check: "check"; case .gate: "portão" }
    }
    private static func hourMinute(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.timeZone = tz; f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// One closed work in the Trilho history: its `work.history` line as the owner reads it.
struct HistoryRow: Equatable, Identifiable {
    var id: String
    var title: String
    /// When it closed: "21/11 02:02" (local time).
    var whenText: String
    /// "4/6 feitas · 1 adiada".
    var resultText: String
    /// Why it ended, short: "concluído" when no loop stopped it.
    var stopText: String
    /// "<1 min", "12 min", "1h54", "1d 3h".
    var durationText: String

    init(_ e: HistoryEntry, timeZone: TimeZone = .current) {
        id = e.id; title = e.title
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.timeZone = timeZone; f.dateFormat = "dd/MM HH:mm"
        whenText = f.string(from: e.closedAt)
        resultText = "\(e.done)/\(e.total) feitas" + (e.deferred > 0 ? " · \(e.deferred) " + (e.deferred == 1 ? "adiada" : "adiadas") : "")
        stopText = Self.stop(e.stopReason)
        durationText = Self.duration(e.durationSeconds)
    }

    static func stop(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "concluído" }
        switch WorkLoopState.Stop.Code(rawValue: raw) {
        case .requested?: return "parado por você"
        case .workGone?: return "trabalho fechado"
        case .starterGone?: return "Pastor sumiu"
        case .maxReached?: return "limite de tentativas"
        case .budgetSpent?: return "orçamento esgotado"
        case .gitFailed?: return "git falhou"
        case .dirtyTree?: return "árvore modificada"
        case .othersWorking?: return "outro terminal trabalhando"
        case .cancelled?: return "daemon parou"
        case .daemonRestart?: return "daemon reiniciou"
        case .internal?: return "erro interno"
        case .adoptionFailed?: return "adoção falhou"
        case .unknown?, nil: return "motivo desconhecido"
        }
    }

    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "<1 min" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600)h" + String(format: "%02d", s % 3600 / 60) }
        return "\(s / 86_400)d \(s % 86_400 / 3600)h"
    }
}
