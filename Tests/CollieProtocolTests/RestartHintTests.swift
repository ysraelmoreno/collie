import Testing
import CollieProtocol

/// A newer app/CLI against an older daemon (spec §4, compatibility contract): a command the daemon lacks says to
/// restart the service, never a bare "Unknown command".
@Suite struct RestartHintTests {
    @Test func wrapsUnknownCommand() {
        // the router's message, and ArgvParser's form (what an older daemon's plug-in path could answer)
        let r = RestartHint.wrap(ProtocolError(code: .invalidArgs, message: "Unknown command 'app.update.status'"))
        #expect(r == ProtocolError(code: .invalidArgs, message: "app.update.status: reinicie o serviço para usar isto"))
        let p = RestartHint.wrap(ProtocolError(code: .invalidArgs, message: "unknown command: lot.board"))
        #expect(p == ProtocolError(code: .invalidArgs, message: "lot.board: reinicie o serviço para usar isto"))
        #expect(RestartHint.text == "reinicie o serviço para usar isto")
    }
    @Test func keepsOtherErrors() {
        for e in [ProtocolError(code: .invalidArgs, message: "sandbox must be sandboxed or free"),
                  ProtocolError(code: .notFound, message: "Terminal 'x' not found"),
                  // a plug-in engine's own error, relayed: not a missing daemon command
                  ProtocolError(code: .internal, message: "figcraft: unknown command `bad.x`"),
                  ProtocolError(code: .unauthorized, message: "Unknown command 'x' is not this")] {
            #expect(RestartHint.wrap(e) == e)
        }
    }
}
