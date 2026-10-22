import Testing
@testable import CollieProtocol

@Suite struct PluginRegistryTests {
    @Test func registryCommandsAppearInCommandsAndMCP() {
        #expect(Commands.spec("browser.navigate") != nil)
        let hit = MCPSchema.tools().first { if case .object(let o) = $0, o["name"] == .string("browser_navigate") { true } else { false } }
        guard case .object(let o)? = hit, case .object(let schema)? = o["inputSchema"], case .object(let props)? = schema["properties"] else {
            Issue.record("browser_navigate missing"); return
        }
        #expect(props["panel"] != nil && props["url"] != nil)
        let pluginNames = PluginRegistry.all.flatMap(\.commands).map(\.name)
        #expect(Set(pluginNames).count == pluginNames.count)
        #expect(Commands.all.count == Commands.core.count + pluginNames.count)
        #expect(Set(Commands.all.map(\.name)).count == Commands.all.count)
        #expect(PluginRegistry.command("browser.wait")?.1.timeoutSeconds == 120)
        #expect(PluginRegistry.spec("browser")?.defaultPlacement == .dockRight)
        #expect(PluginRegistry.command("artifact.list")?.0.id == "artifacts" && PluginRegistry.command("artifact.reexport")?.1.timeoutSeconds == 120)
    }

    @Test func everyPluginCommandHasPanelParam() {
        for p in PluginRegistry.all {
            for c in p.commands {
                // its first segment is a CLI group word: `collie <group> <sub>...` reaches it
                let words = c.name.split(separator: ".").map(String.init)
                #expect((try? ArgvParser.parse(words + c.params.filter { $0.required && $0.kind != .flag }.flatMap { $0.positional ? ["1"] : ["--\($0.name)", "1"] }))?.command == c.name, "\(c.name)")
                let panel = c.params.filter { $0.name == "panel" }
                #expect(panel.count == 1 && panel[0].kind == .string && !panel[0].required, "\(c.name)")
            }
        }
    }
}
