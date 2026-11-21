import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func task(_ id: String, _ state: TaskState = .open, needs: [String]? = nil, scope: [String]? = nil) -> WorkTask {
    WorkTask(id: id, title: id.uppercased(), state: state, needs: needs, scope: scope)
}

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }
private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Term {
    let args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp")]
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func add(_ p: Paths, _ t: Term, _ args: [String: JSONValue]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: "work.task.add", args: args), timeoutSeconds: 60)
}

/// M3.1: the task graph (`needs`, `scope`) and the pure scheduler.
@Suite struct TaskSchedulerTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String, tasks: [WorkTask]
        var running: Set<String> = [], integrating: Set<String> = [], parallel = 3
        var approved: Set<String>?
        let ready: [String]
        var testDescription: String { name }
    }

    private static let five = ["a", "b", "c", "d", "e"].map { task($0, scope: ["\($0)/**"]) }

    static let rows: [Row] = [
        Row(name: "no needs, no scope: exclusive, only the first goes up", tasks: [task("a"), task("b"), task("c")], ready: ["a"]),
        Row(name: "an empty scope is no scope", tasks: [task("a", scope: []), task("b", scope: ["b/**"])], ready: ["a"]),
        Row(name: "disjoint scopes go up together", tasks: [task("a", scope: ["Sources/A/**"]), task("b", scope: ["Sources/B/**", "docs/b.md"])],
            ready: ["a", "b"]),
        Row(name: "overlapping scopes do not", tasks: [task("a", scope: ["a/**"]), task("b", scope: ["a/b/**"])], ready: ["a"]),
        Row(name: "the one after an overlap still goes up", tasks: [task("a", scope: ["a/**"]), task("b", scope: ["a/b/**"]), task("c", scope: ["c/**"])],
            ready: ["a", "c"]),
        Row(name: "needs satisfied", tasks: [task("a", .done), task("b", needs: ["a"])], ready: ["b"]),
        Row(name: "needs not satisfied", tasks: [task("a", scope: ["a/**"]), task("b", needs: ["a"], scope: ["b/**"])], ready: ["a"]),
        Row(name: "a need in progress is not satisfied", tasks: [task("a", .inProgress, scope: ["a/**"]), task("b", needs: ["a"], scope: ["b/**"])],
            running: ["a"], ready: []),
        Row(name: "a need still being integrated is not satisfied", tasks: [task("a", .done, scope: ["a/**"]), task("b", needs: ["a"], scope: ["b/**"])],
            integrating: ["a"], ready: []),
        Row(name: "one of two needs missing", tasks: [task("a", .done), task("b", scope: ["b/**"]), task("c", needs: ["a", "b"], scope: ["c/**"])],
            ready: ["b"]),
        Row(name: "a dependent of a deferred task waits, the independent one goes on",
            tasks: [task("a", .deferred), task("b", needs: ["a"]), task("c")], ready: ["c"]),
        Row(name: "a dependent of an abandoned task waits too",
            tasks: [task("a", .abandoned), task("b", needs: ["a"], scope: ["b/**"]), task("c", scope: ["c/**"])], ready: ["c"]),
        Row(name: "a need that does not exist is never satisfied", tasks: [task("a", needs: ["ghost"]), task("b")], ready: ["b"]),
        Row(name: "parallel 0", tasks: five, parallel: 0, ready: []),
        Row(name: "negative parallel", tasks: five, parallel: -2, ready: []),
        Row(name: "parallel 1", tasks: five, parallel: 1, ready: ["a"]),
        Row(name: "parallel 4", tasks: five, parallel: 4, ready: ["a", "b", "c", "d"]),
        Row(name: "parallel 9 is cut to 4", tasks: five, parallel: 9, ready: ["a", "b", "c", "d"]),
        Row(name: "the order of the tasks is kept", tasks: [five[2], five[0], five[1]], parallel: 2, ready: ["c", "a"]),
        Row(name: "the running ones take their slots", tasks: five, running: ["a", "c"], ready: ["b"]),
        Row(name: "all slots taken", tasks: five, running: ["a", "b", "c"], ready: []),
        Row(name: "more running than parallel", tasks: five, running: ["a", "b"], parallel: 1, ready: []),
        Row(name: "a running scope keeps an overlapping task out",
            tasks: [task("a", .inProgress, scope: ["x/**"]), task("b", scope: ["x/y.md"]), task("c", scope: ["z/**"])], running: ["a"], ready: ["c"]),
        Row(name: "an integrating task takes no slot, but its scope is taken",
            tasks: [task("a", .inProgress, scope: ["x/**"]), task("b", scope: ["x/**"]), task("c", scope: ["y/**"])], integrating: ["a"],
            parallel: 1, ready: ["c"]),
        Row(name: "an exclusive task waits for the lanes to drain, and nothing passes it",
            tasks: [task("a", .inProgress, scope: ["a/**"]), task("b"), task("c", scope: ["c/**"])], running: ["a"], ready: []),
        Row(name: "an exclusive task waits for an integration too",
            tasks: [task("a", .inProgress, scope: ["a/**"]), task("b")], integrating: ["a"], ready: []),
        Row(name: "a scoped task enters, the exclusive one after it does not", tasks: [task("a", scope: ["a/**"]), task("b"), task("c", scope: ["c/**"])],
            ready: ["a"]),
        Row(name: "an exclusive task running keeps everything out", tasks: [task("a", .inProgress), task("b", scope: ["b/**"])], running: ["a"], ready: []),
        Row(name: "a running id that is not a task keeps everything out", tasks: five, running: ["ghost"], ready: []),
        Row(name: "only the approved ones", tasks: five, approved: ["b", "d"], ready: ["b", "d"]),
        Row(name: "done, deferred and abandoned never come out",
            tasks: [task("a", .done, scope: ["a/**"]), task("b", .deferred, scope: ["b/**"]), task("c", .abandoned, scope: ["c/**"]), task("d", scope: ["d/**"])],
            ready: ["d"]),
    ]

    @Test(arguments: rows) func ready(_ r: Row) {
        let out = TaskScheduler.ready(tasks: r.tasks, running: r.running, integrating: r.integrating, parallel: r.parallel, approved: r.approved)
        #expect(out.map(\.id) == r.ready)
    }

    @Test func aDependentOfADeferredTaskIsBlockedWithTheReasonAndTheIndependentIsNot() {
        let tasks = [task("a", .deferred), task("b", needs: ["a"]), task("c"), task("d", needs: ["b"]), task("e", needs: ["x"]),
                     task("f", .abandoned), task("g", needs: ["c", "f"]), task("h", .done), task("i", needs: ["h"])]
        let blocked = TaskScheduler.blocked(tasks: tasks)
        #expect(blocked.map(\.task) == ["b", "d", "e", "g"])
        #expect(blocked[0].reason == "depende de «A» [a], que foi adiada")
        #expect(blocked[1].reason == "depende de «B» [b], que está bloqueada")
        #expect(blocked[2].reason.contains("'x'") && blocked[2].reason.contains("não existe"))
        #expect(blocked[3].reason == "depende de «F» [f], que foi abandonada")
        // a cycle read back from the file blocks its tasks and ends
        let loop = TaskScheduler.blocked(tasks: [task("a", needs: ["b"]), task("b", needs: ["a"]), task("c", needs: ["c"]), task("d")])
        #expect(loop.map(\.task) == ["a", "b", "c"])
        #expect(TaskScheduler.blocked(tasks: [task("a"), task("b", needs: ["a"])]).isEmpty)
    }

    // MARK: scopesOverlap

    struct Glob: Sendable, CustomTestStringConvertible {
        let a: String, b: String, overlap: Bool
        init(_ a: String, _ b: String, _ overlap: Bool) { self.a = a; self.b = b; self.overlap = overlap }
        var testDescription: String { "\(a) × \(b)" }
    }

    static let globs: [Glob] = [
        // **
        Glob("a/**", "a/b/**", true), Glob("a/**", "b/**", false), Glob("**", "a/b.swift", true), Glob("**/*.md", "Sources/**", true),
        Glob("**/*.md", "Sources/x.swift", false), Glob("a/**/z.md", "a/b/c/z.md", true), Glob("a/**/z.md", "a/z.md", true),
        Glob("a/**/z.md", "b/z.md", false), Glob("Sources/**/Tests/**", "Sources/App/**", true),
        // *
        Glob("a/*.swift", "a/x.swift", true), Glob("a/*.swift", "a/x.md", false), Glob("a/*.swift", "a/b/x.swift", false),
        Glob("a/*", "b/*", false), Glob("a/x*", "a/*y", true), Glob("a/x*.md", "a/y*.md", false), Glob("*/x.md", "docs/*", true),
        Glob("Sources/Collie*/**", "Sources/CollieApp/x.swift", true), Glob("Sources/Collie*/**", "Sources/Other/x.swift", false),
        // an exact file
        Glob("docs/x.md", "docs/x.md", true), Glob("docs/x.md", "docs/y.md", false), Glob("docs/x.md", "./docs//x.md", true),
        Glob("docs/x.md", "Docs/X.md", true),   // a case-insensitive volume does not tell them apart
        // a folder's prefix: a glob covers what is under it
        Glob("Sources/CollieApp", "Sources/CollieApp/Views/x.swift", true), Glob("Sources/CollieApp/", "Sources/CollieApp/**", true),
        Glob("Sources/CollieApp", "Sources/CollieAppKit/x.swift", false), Glob("Sources", "Sources/**", true), Glob("Sources", "Tests", false),
        // a last segment with an extension is a file: nothing is under it (a dot folder is still a folder)
        Glob(".github", ".github/workflows/ci.yml", true), Glob("docs/x.md", "docs/x.md/y", false),
        // in doubt, it overlaps
        Glob("a/[xy].md", "b/z.md", true), Glob("a/?.md", "b/z.md", true), Glob("a/{x,y}", "b", true), Glob("../a", "b", true),
        Glob("/a", "b", true), Glob("~/a", "b", true), Glob("", "b", true), Glob(".", "b", true), Glob("a\\b", "c", true),
    ]

    @Test(arguments: globs) func globsOverlap(_ g: Glob) {
        #expect(TaskScheduler.globsOverlap(g.a, g.b) == g.overlap)
        #expect(TaskScheduler.globsOverlap(g.b, g.a) == g.overlap)
    }

    @Test func scopesOverlapWhenAnyPairDoesAndWhenOneIsEmpty() {
        #expect(TaskScheduler.scopesOverlap(["a/**", "docs/x.md"], ["b/**", "docs/*.md"]))
        #expect(!TaskScheduler.scopesOverlap(["a/**", "docs/x.md"], ["b/**", "docs/y.md"]))
        #expect(TaskScheduler.scopesOverlap([], ["b/**"]) && TaskScheduler.scopesOverlap(["a/**"], []))
    }

    // MARK: the way in

    @Test func needsRefuseAnUnknownIdACycleAndTheTaskItself() throws {
        let tasks = [task("a", needs: ["b"]), task("b"), task("c", needs: ["a"])]
        #expect(TaskScheduler.needsRefusal(id: "new", needs: ["a", "c"], tasks: tasks) == nil)
        #expect(TaskScheduler.needsRefusal(id: "new", needs: [], tasks: tasks) == nil)
        let unknown = try #require(TaskScheduler.needsRefusal(id: "new", needs: ["a", "nope"], tasks: tasks))
        #expect(unknown.contains("'nope'") && unknown.contains("não existe") && unknown.contains("a, b, c"))
        #expect(TaskScheduler.needsRefusal(id: "new", needs: ["a"], tasks: [])?.contains("não existe") == true)
        #expect(TaskScheduler.needsRefusal(id: "new", needs: ["new"], tasks: tasks)?.contains("dela mesma") == true)
        #expect(TaskScheduler.needsRefusal(id: "new", needs: ["a", ""], tasks: tasks)?.contains("vazio") == true)
        // b needs c, c needs a, a needs b
        #expect(TaskScheduler.needsRefusal(id: "b", needs: ["c"], tasks: tasks) == "as dependências formam um ciclo: b → c → a → b")
        // a cycle already in the file, reached from the new task
        let broken = [task("a", needs: ["b"]), task("b", needs: ["a"])]
        #expect(TaskScheduler.needsRefusal(id: "new", needs: ["a"], tasks: broken)?.contains("ciclo") == true)
        // a diamond is no cycle
        let diamond = [task("a"), task("b", needs: ["a"]), task("c", needs: ["a"])]
        #expect(TaskScheduler.needsRefusal(id: "new", needs: ["b", "c"], tasks: diamond) == nil)
    }

    @Test func scopeRefusesWhatLeavesTheWorktreeAnEmptyGlobAndMoreThanTwenty() {
        for bad in [[""], [], ["a/**", ""], ["../x"], ["a/../../b"], ["/etc/hosts"], ["~/x"], ["a\u{07}b"]] {
            #expect(TaskScheduler.scopeRefusal(bad) != nil, "\(bad)")
        }
        #expect(TaskScheduler.scopeRefusal((1...21).map { "d\($0)/**" })?.contains("no máximo 20") == true)
        #expect(TaskScheduler.scopeRefusal((1...20).map { "d\($0)/**" }) == nil)
        #expect(TaskScheduler.scopeRefusal(["Sources/CollieApp/**", "docs/x.md", "a..b/c"]) == nil)
        #expect(TaskScheduler.list("a, b ,c") == ["a", "b", "c"] && TaskScheduler.list("a,,b") == ["a", "", "b"] && TaskScheduler.list(" ") == [""])
    }

    @Test func taskAddTakesNeedsAndScopeAndRefusesTheInvalidOnes() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A")
            // nothing is opened for a task that is refused
            let early = try await add(p, a, ["title": "x", "needs": "nope"])
            #expect(early.error?.code == .invalidArgs && early.error?.message.contains("não existe") == true, "\(early)")
            #expect(try await d.router.work.active(terminal: a.uuid) == nil)

            let one = try await add(p, a, ["title": "One", "scope": "Sources/CollieApp/**, docs/x.md"])
            #expect(one.ok, "\(one)")
            let first = try #require(try await d.router.work.active(terminal: a.uuid)?.tasks.first)
            #expect(first.scope == ["Sources/CollieApp/**", "docs/x.md"] && first.needs == nil)
            guard case .object(let o)? = one.result else { Issue.record("\(one)"); return }
            #expect(o["scope"] == .array([.string("Sources/CollieApp/**"), .string("docs/x.md")]))

            let two = try await add(p, a, ["title": "Two", "needs": .string(first.id)])
            #expect(two.ok, "\(two)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.last?.needs == [first.id])

            let bad: [[String: JSONValue]] = [
                ["needs": "nope"], ["needs": .string(first.id + ",nope")], ["needs": ""], ["needs": .string(first.id + ",")],
                ["scope": "../x"], ["scope": "/etc/**"], ["scope": "a/**,,b/**"], ["scope": " "],
                ["scope": .string((1...21).map { "d\($0)/**" }.joined(separator: ","))],
            ]
            for extra in bad {
                let r = try await add(p, a, extra.merging(["title": "x"]) { x, _ in x })
                #expect(r.error?.code == .invalidArgs, "\(extra): \(r)")
            }
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.count == 2)
        }
    }

    @Test func theCommandDeclaresNeedsAndScope() throws {
        let spec = try #require(Commands.spec("work.task.add"))
        #expect(spec.params.contains { $0.name == "needs" && $0.kind == .string } && spec.params.contains { $0.name == "scope" && $0.kind == .string })
        let parsed = try ArgvParser.parse(["work", "task", "add", "Build", "it", "--needs", "a,b", "--scope", "Sources/App/**", "--scope", "docs/x.md"])
        #expect(parsed.command == "work.task.add")
        #expect(parsed.args == ["title": "Build it", "needs": "a,b", "scope": "Sources/App/**,docs/x.md"])
    }

    // MARK: the file

    @Test func aTaskWrittenBeforeTheGraphDecodesAndAMalformedFieldDoesNotDropIt() throws {
        let dec = JSONDecoder()
        func decode(_ extra: String) throws -> WorkTask {
            try dec.decode(WorkTask.self, from: Data(#"{"id":"a","title":"A","state":"open","updatedAt":0\#(extra)}"#.utf8))
        }
        let old = try decode("")
        #expect(old.needs == nil && old.scope == nil && old.state == .open)
        let new = try decode(#","needs":["b"],"scope":["a/**","docs/x.md"]"#)
        #expect(new.needs == ["b"] && new.scope == ["a/**", "docs/x.md"])
        // of the wrong type: ignored (no scope: the task runs alone), the task survives
        let bad = try decode(#","needs":"b","scope":[1,2]"#)
        #expect(bad.id == "a" && bad.needs == nil && bad.scope == nil)
        #expect(try dec.decode(WorkTask.self, from: JSONEncoder().encode(new)) == new)
        // a task with neither writes neither
        #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("needs"))
    }
}
