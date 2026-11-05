public enum ArgvParser {
    public static func parse(_ argv: [String]) throws(ProtocolError) -> (command: String, args: [String: JSONValue]) {
        guard var name = argv.first else { throw bad("missing command") }
        var rest = Array(argv.dropFirst())
        // a group word: the first segment of some command (`artifact` for the `artifacts` plugin's `artifact.*`)
        // a command that is also a group (`ask`, `ask result`): grouped only when the next word names a subcommand
        // ponytail: so `collie ask result …` can't reach an agent named "result"
        let next = rest.first.map { "\(name).\($0)" }
        if ["admin", "paddock", "panel", "memory"].contains(name) || Commands.all.contains(where: { $0.name.hasPrefix(name + ".") }),
           Commands.spec(name) == nil || next.flatMap(Commands.spec) != nil {
            guard let sub = rest.first else { throw bad("missing \(name) subcommand") }
            name = "\(name).\(sub)"; rest.removeFirst()
            // more words while they name a deeper command (`design system list`, `admin remote pair begin`)
            while let sub = rest.first, Commands.all.contains(where: { $0.name == "\(name).\(sub)" || $0.name.hasPrefix("\(name).\(sub).") }) {
                name += ".\(sub)"; rest.removeFirst()
            }
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
            guard let p = spec.params.first(where: { $0.name == key && $0.kind != .rest && $0.kind != .list }) else { throw bad("unknown flag --\(key)") }
            if p.kind == .flag { args[key] = .bool(true); continue }
            guard i < rest.count else { throw bad("--\(key) needs a value") }
            let v = rest[i]; i += 1
            if p.kind == .int {
                guard let n = Int(v) else { throw bad("--\(key) must be an integer, got \(v)") }
                args[key] = .number(Double(n))
            } else if p.repeatable, case .string(let prev)? = args[key] { args[key] = .string(prev + "," + v)
            } else { args[key] = .string(v) }
        }

        var pos = words[...]
        for p in spec.params where p.positional {
            if p.kind == .rest {
                if !pos.isEmpty { args[p.name] = .string(pos.joined(separator: " ")); pos = [] }
            } else if p.kind == .list {
                if !pos.isEmpty { args[p.name] = .array(pos.map { .string($0) }); pos = [] }
            } else if let w = pos.popFirst() { args[p.name] = .string(w) }
        }
        if !pos.isEmpty { throw bad("unexpected argument: \(pos.joined(separator: " "))") }
        let missing = spec.params.filter { $0.required && args[$0.name] == nil }
        if !missing.isEmpty {
            throw bad("missing required: " + missing.map { $0.positional ? "<\($0.name)>" : "--\($0.name)" }.joined(separator: ", ") + "\n" + usageLine(spec))
        }
        return (name, args)
    }

    /// `collie <command…> --help` (or `-h`, or `collie help <command…>`): the command's usage, or a group's commands.
    /// nil: not a help request (after `--` everything is an argument), or no such command (the full list then).
    public static func help(_ argv: [String]) -> String? {
        var words = Array(argv[..<(argv.firstIndex(of: "--") ?? argv.count)])
        if words.first == "help" { words.removeFirst() } else {
            guard let i = words.firstIndex(where: { $0 == "--help" || $0 == "-h" }) else { return nil }
            words.remove(at: i)
        }
        var name = ""
        for w in words where !w.hasPrefix("-") {
            let n = name.isEmpty ? w : "\(name).\(w)"
            guard Commands.all.contains(where: { $0.name == n || $0.name.hasPrefix(n + ".") }) else { break }
            name = n
        }
        let group = Commands.all.filter { $0.name.hasPrefix(name + ".") && !name.isEmpty }
        let list = group.map { "  " + usageLine($0).dropFirst("usage: ".count) + "\t" + $0.summary }.joined(separator: "\n") + "\n"
        if let s = Commands.spec(name) {
            var out = usageLine(s) + "\n\n" + s.summary + "\n"
            for p in s.params {
                out += "  " + (p.positional ? "<\(p.name)>" : "--\(p.name)") + (p.help.isEmpty ? "" : "\t\(p.help)") + "\n"
            }
            return group.isEmpty ? out : out + "\nalso:\n" + list   // `ask` and `ask result`
        }
        return group.isEmpty ? nil : list
    }

    /// `usage: collie memory save --kind <kind> --subject <subject> --title <title> [<body>…]`
    static func usageLine(_ s: CommandSpec) -> String {
        let words = s.params.map { p -> String in
            let w = switch (p.positional, p.kind) {
            case (true, .rest), (true, .list): "<\(p.name)>…"
            case (true, _): "<\(p.name)>"
            case (false, .flag): "--\(p.name)"
            default: "--\(p.name) <\(p.name)>"
            }
            return p.required ? w : "[\(w)]"
        }
        return (["usage: collie " + s.name.replacingOccurrences(of: ".", with: " ")] + words).joined(separator: " ")
    }

    private static func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
}
