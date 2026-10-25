public enum MCPSchema {
    /// `shepherd`: also list the Shepherd-only tools (the daemon still decides who may call them).
    /// `plugins`: plug-in ids whose panel-bound commands to list (nil = all); core, `paddock.*`, `memory.*`, `panel.*`
    /// and panel-free plug-in commands always.
    public static func tools(shepherd: Bool = false, plugins: Set<String>? = nil) -> [JSONValue] {
        let all = PluginRegistry.all   // one snapshot: an install between two reads can't mix catalogs
        let hidden = Set(all.filter { p in plugins.map { !$0.contains(p.id) } ?? false }
            .flatMap { $0.commands.filter { !$0.panelFree }.map(\.name) })
        // external tools: author text, marked as such and kept short
        let external = Dictionary(all.filter { $0.source != .builtIn }.flatMap { p in p.commands.map { ($0.name, p.id) } }, uniquingKeysWith: { a, _ in a })
        return (Commands.core + all.flatMap(\.commands)).filter { $0.exposedToMCP && (shepherd || !$0.shepherdOnly) && !hidden.contains($0.name) }.map { c in
            let ext = external[c.name]
            var props: [String: JSONValue] = [:]
            for p in c.params {
                let type = p.kind == .int ? "integer" : p.kind == .flag ? "boolean" : "string"
                props[p.name] = .object(["type": .string(type), "description": .string(ext.map { String(("[plug-in \($0)] " + p.help).prefix(200)) } ?? p.help)])
            }
            let summary = ext.map { String(("[plug-in \($0)] " + c.summary).prefix(200)) }
                ?? (c.name.hasPrefix("design.") && !c.panelFree ? "Collie Design panel leashed to you: " + c.summary : c.summary)
            return .object([
                "name": .string(c.mcpName),
                "description": .string(summary),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(props),
                    "required": .array(c.params.filter(\.required).map { .string($0.name) }),
                ]),
            ])
        }
    }
}
