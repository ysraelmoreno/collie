import Foundation
import Testing
import CollieClient
import CollieCore
import CollieProtocol
@testable import CollieApp

@MainActor private func actions() -> PaddockActions {
    PaddockActions(client: DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-factory-\(UUID())"))))
}
private func paddock(factory: Bool = false) -> Paddock {
    var p = Paddock(id: UUID(), name: "api", repoRoot: "/r", path: "/r/.collie/paddocks/api", branch: "collie/api", baseBranch: "main")
    p.factory = factory
    return p
}

/// A3: the Fábrica switch in the context panel, the paddock menu's item and the rail's badge, as models.
@MainActor @Suite(.appPT) struct ContextPanelFactoryTests {
    @Test func switchLabelFollowsThePaddock() {
        let off = FactorySwitch.make(paddock(), busy: false, refusal: nil, note: nil)
        #expect(!off.isOn && off.label == "Ligar fábrica" && off.enabled && off.refusal == nil && off.note.isEmpty)
        let on = FactorySwitch.make(paddock(factory: true), busy: false, refusal: nil, note: ["static 2/3 OK"])
        #expect(on.isOn && on.label == "Desligar fábrica" && on.note == ["static 2/3 OK"])
    }

    @Test func disabledWhileACallRuns() {
        #expect(!FactorySwitch.make(paddock(), busy: true, refusal: nil, note: nil).enabled)
    }

    /// The doctor's note shows only while on (a stale note of a paddock turned off elsewhere is not drawn).
    @Test func noteOnlyWhileOn() {
        #expect(FactorySwitch.make(paddock(), busy: false, refusal: nil, note: ["static 2/3 OK"]).note.isEmpty)
    }

    @Test func noteIsOneLinePerLayer() {
        let r = FactoryDoctor.Report(layers: [.init(layer: .static, score: 2, evidence: ["x"], nextAction: ["y"]),
                                              .init(layer: .judge, score: 0, evidence: [], nextAction: [])])
        #expect(PaddockActions.noteLines(r) == ["static 2/3 OK", "judge 0/3 FRACO"])
    }

    @Test func railBadgeOnlyOnAFactoryPaddock() {
        #expect(FactorySwitch.badge(paddock(factory: true)) == "cercado fábrica")
        #expect(FactorySwitch.badge(paddock()) == nil)
    }

    /// The daemon's refusal reaches the model whole, under the switch and not as an alert. Awaits the call's task: no clock.
    @Test func refusalReachesModelWhole() async {
        let a = actions(), p = paddock()
        let why = "cercado fábrica não ligado: o doctor deu judge 0/3 (mínimo 1); rode `collie factory doctor`"
        var sent: (String, Bool)?
        a.factoryCall = { name, on in sent = (name, on); throw ProtocolError(code: .invalidArgs, message: why) }
        await a.setFactory(p, true).value
        #expect(sent?.0 == "api" && sent?.1 == true)
        #expect(a.factoryRefusal[p.id] == why)
        #expect(a.message == nil && !a.busy)
        #expect(FactorySwitch.make(p, busy: a.busy, refusal: a.factoryRefusal[p.id], note: nil).refusal == why)
    }

    /// A later switch that the daemon takes clears the old refusal.
    @Test func acceptedSwitchClearsRefusal() async {
        let a = actions(), p = paddock()
        a.factoryRefusal[p.id] = "antiga"
        a.factoryCall = { _, _ in }
        await a.setFactory(p, true).value
        #expect(a.factoryRefusal[p.id] == nil && a.message == nil)
    }

    /// With no terminal in the paddock the daemon has no way in: the note says so instead of an error.
    @Test func noteWithoutTerminalSaysWhy() async {
        let a = actions(), p = paddock(factory: true)
        await a.loadFactoryNote(p)
        #expect(a.factoryNote[p.id] == ["Abra um terminal no cercado para ver a nota do doctor."])
    }
}
