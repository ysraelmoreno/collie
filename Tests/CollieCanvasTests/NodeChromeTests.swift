import Testing
import CollieCore
import CollieCanvas

@Test func nodeStatusTextPerState() {
    #expect(NodeStatus(badge: nil, exitCode: nil) == .idle)
    #expect(NodeStatus(badge: .idle, exitCode: nil).text == nil)
    #expect(NodeStatus(badge: .working, exitCode: nil).text == "trabalhando")
    #expect(NodeStatus(badge: .attention, exitCode: nil).text == "espera você")
    #expect(NodeStatus(badge: .stopped, exitCode: nil).text == "encerrado")
    #expect(NodeStatus(badge: .working, exitCode: 2).text == "encerrado (código 2)")   // the exit frame wins
}

@Test func leashStylePerKind() {
    #expect(LeashStyle(toPanel: false, selected: false) == LeashStyle(width: 2, dash: [], toPanel: false))
    #expect(LeashStyle(toPanel: true, selected: false) == LeashStyle(width: 2, dash: [2, 6], toPanel: true))
    #expect(LeashStyle(toPanel: true, selected: true).width == 3)
    #expect(LeashStyle(toPanel: false, selected: true).width == 3)
}
