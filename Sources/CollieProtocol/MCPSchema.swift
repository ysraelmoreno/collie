public enum MCPSchema {
    /// B1: params of an MCP tool that are the owner's alone ("never by MCP"): left out of the schema, and a call that
    /// passes one anyway is refused (`refusal`) before it reaches the daemon.
    public static let ownerOnlyParams: [String: Set<String>] = ["paddock.create": ["factory"]]

    /// Why an MCP call of `command` with `args` is refused here; nil: it goes on to the daemon.
    public static func refusal(command: String, args: [String: JSONValue]) -> String? {
        guard let bad = ownerOnlyParams[command]?.first(where: { args[$0] != nil }) else { return nil }
        return "'\(bad)' of '\(command)' is the owner's alone (the app or the owner's CLI), never by MCP"
    }

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
            for p in c.params where !(ownerOnlyParams[c.name]?.contains(p.name) ?? false) {
                let type = p.kind == .int ? "integer" : p.kind == .flag ? "boolean" : p.kind == .list ? "array" : "string"
                var prop: [String: JSONValue] = ["type": .string(type), "description": .string(ext.map { String(("[plug-in \($0)] " + p.help).prefix(200)) } ?? p.help)]
                if p.kind == .list { prop["items"] = .object(["type": .string("string")]) }
                props[p.name] = .object(prop)
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
