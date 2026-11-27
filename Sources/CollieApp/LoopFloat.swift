import AppKit
import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

/// L5: the running loop as a floating panel pinned beside the terminal that runs it (the work's terminal, its Shepherd),
/// or as a pill ("laço 3/7 · check rodando"). Pure model: built from the `Work` (`WorkFeed.work`) and the paddock's
/// terminals, the same rules as `LoopSection`/`LoopCard`.
enum LoopFloat {
    struct TaskLine: Equatable, Identifiable {
        var row: LoopSection.TaskRow
        var id: String { row.id }
        /// ✔ done, ● running, ◌ open, – deferred (decorative: `row.accessibilityLabel` says the state).
        var mark: String { LoopFloat.mark(row.state) }
    }
    struct Item: Equatable, Identifiable {
        /// The work's id.
        var id: UUID
        /// The owner terminal's node, when it is on this canvas; nil: the pill sits in the canvas's lower-left corner.
        var anchor: UUID?
        /// The owner's name (`work stop --terminal`); nil when its terminal is gone.
        var owner: String?
        var title: String
        var done: Int
        var total: Int
        /// The running task's title; nil between tasks.
        var current: String?
        var currentId: String?
        var attempt: Int?
        var tries: Int
        /// "check rodando" (`LoopCard.phase`).
        var phase: String
        var tasks: [TaskLine]

        var progressText: String { "\(done)/\(total)" }
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
        /// "tentativa 2 de 3"; nil when no task runs.
        var attemptText: String? { attempt.map { tr("tentativa \($0) de \(tries)", "attempt \($0) of \(tries)") } }
        /// "laço 3/7 · check rodando".
        var pillText: String { tr("laço \(progressText) · \(phase)", "loop \(progressText) · \(phase)") }
        var accessibilityLabel: String {
            [tr("laço \(title)", "loop \(title)"), tr("\(done) de \(total) feitas", "\(done) of \(total) done"), attemptText, phase]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    static func mark(_ s: LoopSection.State) -> String {
        switch s { case .done: "✔"; case .running: "●"; case .open: "◌"; case .deferred: "–" }
    }

    /// One item per running loop (`WorkFeed` follows one work, so at most one); a finished or stopped loop: none.
    /// `terminals`: the paddock's terminals on the canvas (`visibleTerminals`).
    static func make(work: Work?, terminals: [TerminalRecord]) -> [Item] {
        guard let w = work, let loop = w.loop, let card = LoopCard.make(work: w, paddock: w.paddockId) else { return [] }
        let rows = LoopSection.make(work: w, paddock: w.paddockId).rows
        let running = rows.first { $0.state == .running }
        let owner = terminals.first { $0.id == w.terminalId }
        return [Item(id: w.id, anchor: owner?.id, owner: owner?.name, title: w.title, done: card.done, total: card.total,
                     current: running?.title, currentId: running?.id, attempt: card.attempt, tries: loop.tries,
                     phase: card.phase, tasks: rows.map { TaskLine(row: $0) })]
    }

    static let width: CGFloat = 260
    /// The gap between node and panel, the short leash drawn across it.
    static let gap: CGFloat = 14
    static let margin: CGFloat = 12

    /// Which side of `node` the float goes: right, left when the expanded panel does not fit there; none: no node.
    static func side(node: CGRect?, viewport: CGSize) -> Side {
        guard let n = node else { return .none }
        let w = width + gap
        return n.maxX + w <= viewport.width || n.minX - w < 0 ? .right : .left
    }
    /// The float's screen frame for content of `size` (the leash gap included when anchored): top aligned beside
    /// `node` on `side`; no node: the viewport's lower-left corner.
    static func frame(node: CGRect?, side: Side, size: CGSize, viewport: CGSize) -> CGRect {
        guard let n = node, side != .none else {
            return CGRect(x: margin, y: viewport.height - size.height - margin, width: size.width, height: size.height)
        }
        return CGRect(x: side == .right ? n.maxX : n.minX - size.width, y: n.minY, width: size.width, height: size.height)
    }
    /// The node's side of the float (where the leash is drawn); none: not anchored.
    enum Side: Equatable { case right, left, none }

    static func collapsedKey(_ id: UUID) -> String { "loopFloat.collapsed.\(id.uuidString)" }
}

/// The float's hosting view: tells the canvas when its content changed size (collapsing, a task more) so it is placed again.
@MainActor final class LoopFloatHost: NSHostingView<LoopFloatView> {
    var onResize: () -> Void = {}
    override func invalidateIntrinsicContentSize() { super.invalidateIntrinsicContentSize(); onResize() }
}

/// The float itself: expanded (title, bar n/total, tasks, Parar / Adiar tarefa / Histórico) or a pill.
struct LoopFloatView: View {
    let item: LoopFloat.Item
    let side: LoopFloat.Side
    let client: DaemonClient
    let onHistory: () -> Void
    @AppStorage private var collapsed: Bool
    @State private var busy = false
    @State private var error: String?

    init(item: LoopFloat.Item, side: LoopFloat.Side, client: DaemonClient, onHistory: @escaping () -> Void) {
        self.item = item; self.side = side; self.client = client; self.onHistory = onHistory
        _collapsed = AppStorage(wrappedValue: false, LoopFloat.collapsedKey(item.id))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if side == .right { leash }
            Group { if collapsed { pill } else { panel } }
            if side == .left { leash }
        }
        .fixedSize()
    }

    /// The short leash to the owner node, at the height of the float's header.
    private var leash: some View {
        Rectangle().fill(Color.collieAccent.opacity(0.6)).frame(width: LoopFloat.gap, height: 1.5).padding(.top, 15)
            .accessibilityHidden(true)
    }

    private var pill: some View {
        Button { collapsed = false } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.collieAccent)
                Text(verbatim: item.pillText).font(.collieUI(12)).foregroundStyle(Color.collieText).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Color.collieSurface, in: .capsule)
            .overlay { Capsule().stroke(Color.collieBorder, lineWidth: 1) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(tr("Abrir o laço", "Open the loop"))
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityHint(tr("Abre o painel do laço", "Opens the loop panel"))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.collieAccent)
                    .accessibilityHidden(true)
                Text(verbatim: item.title).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(verbatim: item.progressText).font(.collieMono(11)).monospacedDigit().foregroundStyle(Color.collieSecondary)
                Button { collapsed = true } label: { Image(systemName: "minus").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.collieMuted)
                    .help(tr("Recolher", "Collapse")).accessibilityLabel(tr("Recolher o laço", "Collapse the loop"))
            }
            LoopProgressBar(fraction: item.fraction)
            Text(verbatim: [item.attemptText, item.phase].compactMap { $0 }.joined(separator: " · "))
                .font(.collieMono(10)).foregroundStyle(Color.collieMuted).lineLimit(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(item.tasks) { t in
                        HStack(spacing: 6) {
                            Text(verbatim: t.mark).font(.collieMono(11)).foregroundStyle(color(t.row.state)).frame(width: 14)
                            Text(verbatim: t.row.title).font(.collieUI(12))
                                .foregroundStyle(t.row.state == .running ? Color.collieText : Color.collieTextSecondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .accessibilityElement(children: .ignore).accessibilityLabel(t.row.accessibilityLabel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            if let error { Text(verbatim: error).font(.collieUI(11)).foregroundStyle(Color.collieDanger).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 6) {
                Button(tr("Adiar tarefa", "Defer task")) { act { try await LoopsModal.deferTask($0, terminal: $1, client: client) } }
                    .disabled(busy || item.owner == nil || item.currentId == nil)
                Button(tr("Parar", "Stop")) { act { _, t in try await LoopsModal.stop(terminal: t, client: client) } }
                    .disabled(busy || item.owner == nil)
                Spacer(minLength: 0)
                Button(tr("Histórico", "History"), action: onHistory)
            }
            .buttonStyle(CollieButtonStyle(.secondary)).controlSize(.small)
        }
        .padding(10).frame(width: LoopFloat.width, alignment: .leading)
        .background(Color.collieSurface, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.collieBorder, lineWidth: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel(item.accessibilityLabel)
    }

    /// Runs an action on the owner terminal (and the running task); the daemon's refusal shows under the tasks.
    private func act(_ run: @escaping @MainActor (String, String) async throws -> Void) {
        guard let owner = item.owner else { return }
        busy = true; error = nil
        let task = item.currentId ?? ""
        Task { @MainActor in
            do { try await run(task, owner) } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
            busy = false
        }
    }

    private func color(_ s: LoopSection.State) -> Color {
        switch s { case .done: .collieSecondary; case .running: .collieAccent; case .deferred: .collieAttention; case .open: .collieMuted }
    }
}
