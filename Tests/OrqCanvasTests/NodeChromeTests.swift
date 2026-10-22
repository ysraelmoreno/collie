import Testing
import OrqCore
import OrqCanvas

@Test func nodeStatusTextPerState() {
    #expect(NodeStatus(badge: nil, exitCode: nil) == .idle)
    #expect(NodeStatus(badge: .idle, exitCode: nil).text == nil)
    #expect(NodeStatus(badge: .working, exitCode: nil).text == "trabalhando")
    #expect(NodeStatus(badge: .attention, exitCode: nil).text == "espera você")
    #expect(NodeStatus(badge: .stopped, exitCode: nil).text == "encerrado")
    #expect(NodeStatus(badge: .working, exitCode: 2).text == "encerrado (código 2)")   // the exit frame wins
}

@Test func cordStylePerKind() {
    #expect(CordStyle(toPanel: false, selected: false) == CordStyle(width: 2, dash: [], toPanel: false))
    #expect(CordStyle(toPanel: true, selected: false) == CordStyle(width: 2, dash: [2, 6], toPanel: true))
    #expect(CordStyle(toPanel: true, selected: true).width == 3)
    #expect(CordStyle(toPanel: false, selected: true).width == 3)
}
