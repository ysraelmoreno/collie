import Testing
@testable import CollieProtocol

/// DX backlog 6: per-command help, every missing required argument at once, and four-word commands.
@Suite struct CLIHelpTests {
    @Test func fourWordCommandParses() throws {
        #expect(try ArgvParser.parse(["admin", "remote", "pair", "begin"]).command == "admin.remote.pair.begin")
        #expect(try ArgvParser.parse(["admin", "remote", "on"]).args["action"] == .string("on"), "a positional, not a subcommand")
    }

    @Test func helpForACommand() throws {
        let h = try #require(ArgvParser.help(["summon", "--help"]))
        #expect(h.hasPrefix("usage: collie summon <name>"), "\(h)")
        #expect(h.contains("--preset <preset>") && h.contains("Spawn an agent leashed to you"), "\(h)")
        #expect(try #require(ArgvParser.help(["help", "memory", "save"])).hasPrefix("usage: collie memory save"))
        #expect(ArgvParser.help(["summon", "x"]) == nil)
        #expect(try #require(ArgvParser.help(["leash", "--help"])).contains("collie leash request <target>"), "a command that is also a group")
        #expect(ArgvParser.help(["ask", "B", "--", "--help"]) == nil, "after -- it is the prompt")
    }

    @Test func helpForAGroupListsItsCommands() throws {
        let h = try #require(ArgvParser.help(["memory", "--help"]))
        #expect(h.contains("collie memory save") && h.contains("collie memory search"), "\(h)")
    }

    @Test func everyMissingRequiredArgumentAtOnce() {
        do { _ = try ArgvParser.parse(["memory", "save", "body"]); Issue.record("parsed") } catch {
            #expect(error.message.hasPrefix("missing required: --kind, --subject, --title"), "\(error.message)")
            #expect(error.message.contains("usage: collie memory save"), "\(error.message)")
        }
    }
}
