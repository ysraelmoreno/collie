public enum MCPSchema {
    /// `maestro`: also list the Maestro-only tools (the daemon still decides who may call them).
    /// `plugins`: plug-in ids whose panel-bound commands to list (nil = all); core, `floor.*`, `memory.*`, `panel.*`
    /// and panel-free plug-in commands always.
    public static func tools(maestro: Bool = false, plugins: Set<String>? = nil) -> [JSONValue] {
        let hidden = Set(PluginRegistry.all.filter { p in plugins.map { !$0.contains(p.id) } ?? false }
            .flatMap { $0.commands.filter { !$0.panelFree }.map(\.name) })
        return Commands.all.filter { $0.exposedToMCP && (maestro || !$0.maestroOnly) && !hidden.contains($0.name) }.map { c in
            var props: [String: JSONValue] = [:]
            for p in c.params {
                let type = p.kind == .int ? "integer" : p.kind == .flag ? "boolean" : "string"
                props[p.name] = .object(["type": .string(type), "description": .string(p.help)])
            }
            return .object([
                "name": .string(c.mcpName),
                "description": .string(c.name.hasPrefix("design.") && !c.panelFree ? "Collie Design panel corded to you: " + c.summary : c.summary),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(props),
                    "required": .array(c.params.filter(\.required).map { .string($0.name) }),
                ]),
            ])
        }
    }
}
