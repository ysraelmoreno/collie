import Testing
import Foundation
import SwiftUI
import CollieCanvas
import ColliePlugins
import CollieCore
import CollieClient
import CollieProtocol
@testable import CollieApp

private let pad = UUID()

private func work(_ state: WorkLoopState.State? = .running) -> Work {
    var w = Work(title: "T", terminalId: UUID(), paddockId: pad, tasks: [WorkTask(id: "a", title: "A", state: .inProgress, tries: 1)])
    if let state { w.loop = WorkLoopState(state: state, task: "a", attempt: 1, tries: 3) }
    return w
}

@MainActor private final class Box { var ids: [String] = []; var tabs: [LoopsTab] = [] }

@MainActor private func context() -> ShellContext {
    let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-reach-\(UUID())")))
    return ShellContext(client: client, canvas: CanvasState(), paddocks: PaddockActions(client: client), usage: UsageFeed(),
                        usageOpen: .constant(false), newTerminal: {}, openPanel: {}, fit: {}, openPalette: {},
                        herds: HerdsModel(call: { _, _ in .null }, nodeName: { _ in nil }), openHerds: { _ in })
}

/// M9.1 (B1, B2, B7, B8).
@MainActor @Suite(.appPT) struct HistoryReachTests {
    /// B1: with no loop, the modal opens on Histórico.
    @Test func noLoopOpensOnHistory() {
        #expect(LoopsModal.initialTab(.history, running: nil) == .history)
        #expect(LoopsModal.initialTab(.running, running: nil) == .history)
    }

    /// B2: a failing hook leaves the fixed notice in the modal and keeps it open; the next try clears it; success closes.
    @Test func hookFailureStaysAndDoesNotClose() async {
        var fail = true
        // the real opener, with a daemon that refuses `artifact.add` while `fail` holds
        let opener = HistoryOpener(fetch: { WorkArchive(id: $0) },
                                   add: { _, _, _ in if fail { throw ProtocolError(code: .internal, message: "/secret/path gone") }; return "art" },
                                   open: { _ in UUID() }, isOpen: { _ in false }, focus: { _ in })
        let id = UUID().uuidString.lowercased()
        var ctx = context()
        ctx.onOpenHistory = { await opener.show($0) }
        ctx.historyNotice = { opener.message }
        var load = LoopsModal.Load()
        #expect(!load.canvas(await LoopsModal.openInCanvas(id, ctx: ctx)))
        #expect(load.error == HistoryOpener.failure)          // fixed text, never the protocol's message
        fail = false
        #expect(load.canvas(await LoopsModal.openInCanvas(id, ctx: ctx)))
        #expect(load.error == nil)
    }

    /// B7: repeated notes or reasons keep distinct ids (the view uses the offset).
    @Test func duplicateNotesDoNotCollide() {
        let d = LoopsModal.Detail(WorkArchive(id: "x", tasks: [.init(id: "t", title: "T", state: "done", failure: "igual", evidenceNote: "igual")],
                                              notes: ["[loop] mesma", "[loop] mesma"]))
        #expect(Set(Array(d.notes.enumerated()).map(\.offset)).count == d.notes.count)
        #expect(Set(Array(d.tasks[0].why.enumerated()).map(\.offset)).count == 2)
        #expect(Set(d.notes).count == 1)   // what `id: \.self` would have collided on
    }

    /// B8: clicks on A then B, A answering last: B is shown.
    @Test func outOfOrderAnswerIsDropped() {
        var load = LoopsModal.Load()
        load.begin("a"); load.begin("b")
        load.end("b", LoopsModal.Detail(WorkArchive(id: "b")))
        load.end("a", LoopsModal.Detail(WorkArchive(id: "a")))
        #expect(load.detail?.id == "b" && load.loading == nil)
        // a late failure of A does not show an error either
        load.begin("c"); load.end("a", nil)
        #expect(load.error == nil && load.loading == "c")
        load.end("c", nil)
        #expect(load.error == HistoryOpener.failure && load.detail?.id == "b")
    }
}
