import Testing
@testable import CollieProtocol

private func kanban(_ id: String = "kanban", version: String = "0.1.0", commands: [String] = ["add", "list"]) -> PluginSpec {
    PluginSpec(id: id, title: "Kanban", placements: [.canvas], defaultPlacement: .canvas,
               commands: commands.map { CommandSpec(name: "\(id).\($0)", summary: "s", timeoutSeconds: 30, outputFile: $0 == "export") },
               events: [], source: .external(version: version), stateKeys: ["board"])
}

/// `.serialized`: these set the process-wide external list (other suites tolerate extra external commands).
@Suite(.serialized) struct PluginRegistryTests {
    @Test func externalCommandsInCommandsAll() throws {
        defer { PluginRegistry.setExternal([]) }
        let v = PluginRegistry.catalogVersion
        PluginRegistry.setExternal([kanban(commands: ["add", "export"])])
        #expect(PluginRegistry.catalogVersion == v + 1)
        #expect(Commands.spec("kanban.add")?.params.map(\.name) == ["panel"])
        #expect(PluginRegistry.command("kanban.export")?.0.source == .external(version: "0.1.0"))
        #expect(Commands.outputFile.contains("kanban.export") && !Commands.outputFile.contains("kanban.add"))
        #expect(try ArgvParser.parse(["kanban", "add"]).command == "kanban.add")
        #expect(PluginRegistry.canvasPluginIds.contains("kanban"))
        PluginRegistry.setExternal([kanban(commands: ["add", "export"])])   // same list: same version
        #expect(PluginRegistry.catalogVersion == v + 1)
        // a built-in's id, a reserved word, a duplicate id, a name outside the id or taken: dropped
        PluginRegistry.setExternal([kanban("browser"), kanban("panel"), kanban(), kanban(version: "2"),
                                    PluginSpec(id: "x1", title: "", placements: [.canvas], defaultPlacement: .canvas,
                                               commands: [CommandSpec(name: "list", summary: "")], events: [], source: .external(version: "1")),
                                    PluginSpec(id: "nb", title: "", placements: [.canvas], defaultPlacement: .canvas, commands: [], events: [])])
        #expect(PluginRegistry.externalSpecs.map(\.id) == ["kanban"] && PluginRegistry.externalSpecs[0].source == .external(version: "0.1.0"))
        #expect(PluginRegistry.spec("browser")?.source == .builtIn)
    }

    @Test func removingExternalDropsCommands() {
        PluginRegistry.setExternal([kanban()])
        #expect(Commands.spec("kanban.list") != nil)
        PluginRegistry.setExternal([])
        #expect(Commands.spec("kanban.list") == nil && PluginRegistry.spec("kanban") == nil)
        #expect((try? ArgvParser.parse(["kanban", "list"])) == nil)
    }

    @Test func builtInsUnchanged() {
        defer { PluginRegistry.setExternal([]) }
        PluginRegistry.setExternal([kanban()])
        let ids = ["browser", "memory", "device", "design", "designsystems", "artifacts", "work"]
        #expect(PluginRegistry.builtIn.map(\.id) == ids)
        #expect(Array(PluginRegistry.all.prefix(7)) == PluginRegistry.builtIn && PluginRegistry.all.map(\.id) == ids + ["kanban"])
        #expect(PluginRegistry.builtIn.allSatisfy { $0.source == .builtIn })
        #expect(Commands.reservedPluginIds.isSuperset(of: ids + ["panel", "admin", "plugin", "artifact", "list"]) && !Commands.reservedPluginIds.contains("kanban"))
        #expect(Array(Commands.all.prefix(Commands.builtIn.count)) == Commands.builtIn)
    }

    @Test func outputFileFlagForBuiltIns() {
        #expect(Set(Commands.builtIn.filter(\.outputFile).map(\.name)) == ["design.screenshot", "design.export", "browser.screenshot", "device.screenshot"])
    }

    @Test func registryCommandsAppearInCommandsAndMCP() {
        #expect(Commands.spec("browser.navigate") != nil)
        let hit = MCPSchema.tools().first { if case .object(let o) = $0, o["name"] == .string("browser_navigate") { true } else { false } }
        guard case .object(let o)? = hit, case .object(let schema)? = o["inputSchema"], case .object(let props)? = schema["properties"] else {
            Issue.record("browser_navigate missing"); return
        }
        #expect(props["panel"] != nil && props["url"] != nil)
        let pluginNames = PluginRegistry.builtIn.flatMap(\.commands).map(\.name)
        #expect(Set(pluginNames).count == pluginNames.count)
        #expect(Commands.builtIn.count == Commands.core.count + pluginNames.count)
        let all = Commands.all
        #expect(Set(all.map(\.name)).count == all.count)
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
