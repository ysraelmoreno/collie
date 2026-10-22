public enum ArgvParser {
    public static func parse(_ argv: [String]) throws(ProtocolError) -> (command: String, args: [String: JSONValue]) {
        guard var name = argv.first else { throw bad("missing command") }
        var rest = Array(argv.dropFirst())
        // a group word: the first segment of some command (`artifact` for the `artifacts` plugin's `artifact.*`)
        if ["admin", "floor", "panel", "memory"].contains(name) || Commands.all.contains(where: { $0.name.hasPrefix(name + ".") }) {
            guard let sub = rest.first else { throw bad("missing \(name) subcommand") }
            name = "\(name).\(sub)"; rest.removeFirst()
            // a third word (`design system list`)
            if Commands.spec(name) == nil, let sub = rest.first, Commands.spec("\(name).\(sub)") != nil { name += ".\(sub)"; rest.removeFirst() }
        }
        guard let spec = Commands.spec(name) else { throw bad("unknown command: \(name)") }

        var args: [String: JSONValue] = [:]
        var words: [String] = []
        var i = 0
        while i < rest.count {
            let t = rest[i]; i += 1
            if t == "--" { words.append(contentsOf: rest[i...]); break }
            guard t.hasPrefix("--"), t.count > 2 else { words.append(t); continue }
            let key = String(t.dropFirst(2))
            guard let p = spec.params.first(where: { $0.name == key && $0.kind != .rest }) else { throw bad("unknown flag --\(key)") }
            if p.kind == .flag { args[key] = .bool(true); continue }
            guard i < rest.count else { throw bad("--\(key) needs a value") }
            let v = rest[i]; i += 1
            if p.kind == .int {
                guard let n = Int(v) else { throw bad("--\(key) must be an integer, got \(v)") }
                args[key] = .number(Double(n))
            } else { args[key] = .string(v) }
        }

        var pos = words[...]
        for p in spec.params where p.positional {
            if p.kind == .rest {
                if !pos.isEmpty { args[p.name] = .string(pos.joined(separator: " ")); pos = [] }
            } else if let w = pos.popFirst() { args[p.name] = .string(w) }
        }
        if !pos.isEmpty { throw bad("unexpected argument: \(pos.joined(separator: " "))") }
        for p in spec.params where p.required && args[p.name] == nil { throw bad("missing required: \(p.name)") }
        return (name, args)
    }

    private static func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
}
