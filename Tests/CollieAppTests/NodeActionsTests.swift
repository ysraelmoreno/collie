import Foundation
import Testing
import CollieProtocol
@testable import CollieApp

@Suite(.appPT) struct NodeActionsTests {
    func term(_ name: String, claude: Bool = false) -> NodeInfo { NodeInfo(id: UUID(), name: name, kind: .terminal(isClaude: claude)) }
    func panel(_ name: String, at p: PanelPlacement = .canvas, allowed: [PanelPlacement] = [.dockLeft, .dockRight, .dockBottom, .canvas],
               isolated: Bool = false) -> NodeInfo {
        NodeInfo(id: UUID(), name: name, kind: .panel(placement: p, allowed: allowed, isolatedStorage: isolated))
    }

    @Test func oneTerminalGetsItsWholeMenu() {
        #expect(NodeActions.available(for: [term("a")]) == [.fullscreen, .edit, .restart, .kill, .lot, .close])
        #expect(NodeActions.available(for: [term("a", claude: true)]).contains(.saveMemory))
    }

    @Test func oneCanvasPanelCanGoFullscreenAndMoveElsewhere() {
        #expect(NodeActions.available(for: [panel("p")]) == [.fullscreen, .move(.dockLeft), .move(.dockRight), .move(.dockBottom), .close])
        #expect(!NodeActions.available(for: [panel("p", at: .dockLeft)]).contains(.fullscreen))
    }

    @Test func manyTerminalsDropSingleItemActions() {
        let acts = NodeActions.available(for: [term("a"), term("b")])
        #expect(acts == [.restart, .kill, .lot, .close])
    }

    @Test func saveMemoryNeedsEveryTerminalToBeClaude() {
        #expect(NodeActions.available(for: [term("a", claude: true), term("b", claude: true)]).contains(.saveMemory))
        #expect(!NodeActions.available(for: [term("a", claude: true), term("b")]).contains(.saveMemory))
    }

    @Test func mixedSelectionKeepsOnlyWhatBothKindsDo() {
        #expect(NodeActions.available(for: [term("a"), panel("p")]) == [.close])
    }

    @Test func manyPanelsOfferOnlyPlacementsAllAllowAndSomeNeed() {
        let only = [PanelPlacement.canvas, .dockLeft]
        let acts = NodeActions.available(for: [panel("p", allowed: only), panel("q", at: .dockLeft, allowed: only)])
        #expect(acts == [.move(.dockLeft), .move(.canvas), .close])   // each is somewhere else than one of them
        let same = NodeActions.available(for: [panel("p", at: .canvas, allowed: only), panel("q", at: .canvas, allowed: only)])
        #expect(same == [.move(.dockLeft), .close])   // nobody needs to move to the canvas
    }

    @Test func nothingSelectedOffersNothing() {
        #expect(NodeActions.available(for: []).isEmpty)
    }

    @Test func onlyCloseAsksAndItSaysHowMany() {
        let items = [term("a"), term("b"), panel("p")]
        #expect(NodeActions.confirmation(for: .restart, items: items) == nil)
        #expect(NodeActions.confirmation(for: .kill, items: items) == nil)
        let c = NodeActions.confirmation(for: .close, items: items)
        #expect(c?.title == "Fechar 3 itens?")
        #expect(c?.detail == "2 terminais serão encerrados e 1 painel será fechado.")
        #expect(c?.button == "Fechar 3 itens")
    }

    @Test func oneItemKeepsTheOldWording() {
        #expect(NodeActions.confirmation(for: .close, items: [term("alfa")]) ==
                .init(title: "Fechar alfa?", detail: "O terminal será encerrado.", button: "Fechar nó"))
        #expect(NodeActions.confirmation(for: .close, items: [panel("web", isolated: true)])?.detail ==
                "O painel será fechado e os dados isolados dele serão apagados.")
    }

    @Test func isolatedPanelsAreMentionedOnce() {
        let c = NodeActions.confirmation(for: .close, items: [panel("p", isolated: true), panel("q", isolated: true)])
        #expect(c?.detail == "2 painéis serão fechados. Os dados isolados dos painéis serão apagados.")
    }
}
