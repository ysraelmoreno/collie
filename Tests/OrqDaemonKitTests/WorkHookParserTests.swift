import Testing
import Foundation
import OrqCore
@testable import OrqDaemonKit

@Suite struct WorkHookParserTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)
    private func fx(_ n: String) -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-hooks/\(n).json")
        return (try? Data(contentsOf: url)) ?? Data()
    }
    private func tool(_ n: String, at d: Date? = nil) -> [WorkEvent] { WorkHookParser.events(hook: "tool", json: fx(n), now: d ?? now) }
    private func tasks(_ n: String, at d: Date? = nil) -> [WorkTask] {
        guard case .tasks(let t)? = tool(n, at: d).first else { return [] }
        return t
    }

    @Test func todoListDiff() {
        let a = tasks("todowrite-1"), b = tasks("todowrite-2", at: later)
        #expect(a.map(\.state) == [.inProgress, .open, .open])
        #expect(a[0].id == "t91774a950e1e8b3" && a[0].id == WorkHookParser.stableId("Write parser") && a[0].id == tasks("todowrite-1")[0].id)
        let r = WorkHookParser.diff(old: WorkHookParser.diff(old: [], new: a, now: now), new: b, now: later)
        let by = Dictionary(uniqueKeysWithValues: r.map { ($0.title, $0) })
        #expect(r.count == 3)
        #expect(by["Write parser"]?.state == .done && by["Write parser"]?.updatedAt == later)
        #expect(by["Write tests"]?.state == .inProgress)
        #expect(by["Update docs"]?.state == .abandoned && by["Update docs"]?.reason == nil)
        // unchanged keeps its date; a commanded deferral is not reopened by a pending list
        let deferred = WorkTask(id: "x", title: "X", state: .deferred, reason: "later", updatedAt: now)
        let kept = WorkHookParser.diff(old: [deferred], new: [WorkTask(id: "x", title: "X", state: .open)], now: later)
        #expect(kept == [deferred])
    }

    @Test func duplicateTodoContentGetsUniqueIds() {
        let j = #"{"tool_name":"TodoWrite","tool_use_id":"u","tool_input":{"todos":[{"content":"A","status":"pending"},{"content":"A","status":"pending"},{"content":"A","status":"done"}]}}"#
        guard case .tasks(let t)? = WorkHookParser.events(hook: "tool", json: Data(j.utf8), now: now).first else { Issue.record("none"); return }
        let h = WorkHookParser.stableId("A")
        #expect(t.map(\.id) == [h, h + "-2", h + "-3"])
    }

    @Test func singleTaskTools() {
        guard case .taskChanged(let c, let cs)? = tool("taskcreate").first, case .taskChanged(let u, let us)? = tool("taskupdate").first else { Issue.record("no events"); return }
        #expect(c.id == "7" && c.title == "Add retry logic" && c.state == .open)
        #expect(u.id == "7" && u.state == .inProgress && u.title == "")
        #expect(!cs && us)   // TaskCreate carries no status: it never resets a stored task's state
        let rename = #"{"tool_name":"TaskUpdate","tool_use_id":"u","tool_input":{"taskId":"7","subject":"New"},"tool_response":"ok"}"#
        guard case .taskChanged(_, let rs)? = WorkHookParser.events(hook: "tool", json: Data(rename.utf8), now: now).first else { Issue.record("no rename"); return }
        #expect(!rs)
        // legacy `Task` with task fields is a task, with prompt a subagent
        let legacy = #"{"tool_name":"Task","tool_use_id":"u","tool_input":{"subject":"S","taskId":"3","status":"completed"},"tool_response":"ok"}"#
        #expect(WorkHookParser.events(hook: "tool", json: Data(legacy.utf8), now: now).first == .taskChanged(WorkTask(id: "3", title: "S", state: .done, updatedAt: now), hasState: true))
        let list = #"{"tool_name":"TaskList","tool_use_id":"u","tool_input":{},"tool_response":"x"}"#
        #expect(WorkHookParser.events(hook: "tool", json: Data(list.utf8), now: now).isEmpty)
    }

    @Test func subagentSyncAndBackground() {
        let sync = tool("agent")
        #expect(sync == [.jobStarted(WorkJob(id: "toolu_05", kind: .subagent, label: "Find call sites", startedAt: now)),
                         .jobEnded(id: "toolu_05", result: "Found 3 callers of foo in Sources.")])
        #expect(tool("agent-background") == [.jobStarted(WorkJob(id: "toolu_06", kind: .subagent, label: "Run audit", startedAt: now, alias: "a1b2c3"))])
        // the agent id also comes nested or as text
        func alias(_ resp: String) -> String? {
            let j = #"{"tool_name":"Agent","tool_use_id":"u","tool_input":{"prompt":"p","run_in_background":true},"tool_response":\#(resp)}"#
            guard case .jobStarted(let job)? = WorkHookParser.events(hook: "tool", json: Data(j.utf8), now: now).first else { return "none" }
            return job.alias
        }
        #expect(alias(#"{"task":{"agent_id":"n1"}}"#) == "n1")
        #expect(alias(#""Async agent launched. agentId: t-2 (use TaskOutput)""#) == "t-2")
        #expect(alias(#"{"content":[{"type":"text","text":"Launched.\nagentId: c3"}]}"#) == "c3")
        #expect(alias(#"{"status":"async_launched"}"#) == nil)
        let legacy = #"{"tool_name":"Task","tool_use_id":"u","tool_input":{"description":"d","prompt":"p","subagent_type":"x"},"tool_response":"done"}"#
        #expect(WorkHookParser.events(hook: "tool", json: Data(legacy.utf8), now: now).count == 2)
        let long = #"{"tool_name":"Agent","tool_use_id":"u","tool_input":{"description":"\#(String(repeating: "d", count: 200))","prompt":"p"},"tool_response":"\#(String(repeating: "r", count: 900))"}"#
        let ev = WorkHookParser.events(hook: "tool", json: Data(long.utf8), now: now)
        guard case .jobStarted(let j) = ev[0], case .jobEnded(_, let r?) = ev[1] else { Issue.record("shape"); return }
        #expect(j.label.count == 80 && r.count == 280)
        #expect(WorkHookParser.events(hook: "subagent-stop", json: fx("subagent-stop"), now: now) == [.jobEnded(id: "agent:a1b2c3", result: nil)])
        #expect(WorkHookParser.events(hook: "subagent-stop", json: fx("subagent-stop-noid"), now: now) == [.jobEnded(id: "", result: nil)])
        #expect(WorkHookParser.events(hook: "precompact", json: fx("precompact"), now: now) == [.compacted])
        #expect(WorkHookParser.events(hook: "session-end", json: Data(), now: now) == [.sessionEnded])
    }

    @Test func backgroundShellLifecycle() {
        #expect(tool("bash-background") == [.jobStarted(WorkJob(id: "bash_1", kind: .shell, label: "npm run dev", startedAt: now))])
        #expect(tool("bashoutput-done") == [.jobEnded(id: "bash_1", result: nil)])
        func ev(_ s: String) -> [WorkEvent] { WorkHookParser.events(hook: "tool", json: Data(s.utf8), now: now) }
        #expect(ev(#"{"tool_name":"BashOutput","tool_use_id":"u","tool_input":{"bash_id":"b"},"tool_response":{"status":"running"}}"#).isEmpty)
        #expect(ev(#"{"tool_name":"TaskOutput","tool_use_id":"u","tool_input":{"task_id":"b"},"tool_response":{"task":{"status":"running","output":"... status: completed ..."}}}"#).isEmpty)
        #expect(ev(#"{"tool_name":"TaskOutput","tool_use_id":"u","tool_input":{"task_id":"b"},"tool_response":{"retrieval_status":"completed"}}"#).isEmpty)
        #expect(ev(#"{"tool_name":"TaskStop","tool_use_id":"u","tool_input":{"task_id":"b"},"tool_response":{"success":true}}"#) == [.jobEnded(id: "b", result: nil)])
        #expect(ev(#"{"tool_name":"KillShell","tool_use_id":"u","tool_input":{"shell_id":"b"},"tool_response":"No shell found with ID b"}"#).isEmpty)
        #expect(ev(#"{"tool_name":"KillShell","tool_use_id":"u","tool_input":{"shell_id":"b"},"tool_response":{"message":"Successfully killed shell","shell_id":"b"}}"#) == [.jobEnded(id: "b", result: nil)])
        #expect(ev(#"{"tool_name":"TaskStop","tool_use_id":"u","tool_input":{"task_id":"x"},"tool_response":{"message":"Successfully stopped task: x","task_id":"x","task_type":"local_bash"}}"#) == [.jobEnded(id: "x", result: nil)])
        #expect(ev(#"{"tool_name":"TaskStop","tool_use_id":"u","tool_input":{"task_id":"x"},"tool_response":{"message":"Failed to stop task x"}}"#).isEmpty)
        #expect(ev(#"{"tool_name":"KillShell","tool_use_id":"u","tool_input":{"shell_id":"b"},"tool_response":"process not stopped"}"#).isEmpty)
        #expect(ev(#"{"tool_name":"KillShell","tool_use_id":"u","tool_input":{"shell_id":"b"},"tool_response":"Successfully killed shell: b"}"#) == [.jobEnded(id: "b", result: nil)])
        #expect(ev(#"{"tool_name":"Bash","tool_use_id":"u","tool_input":{"command":"ls"},"tool_response":{}}"#).isEmpty)
        let fallback = ev(#"{"tool_name":"Bash","tool_use_id":"tu","tool_input":{"command":"sleep 9","run_in_background":true},"tool_response":"started"}"#)
        #expect(fallback.count == 1 && { if case .jobStarted(let j) = fallback[0] { j.id == "tu" } else { false } }())
    }

    @Test func unknownPayloadsIgnored() {
        #expect(tool("unknown-tool").isEmpty)
        for d in [Data(), Data("{}".utf8), Data((0..<64).map { UInt8(($0 &* 37 &+ 11) & 0xff) }), Data("[1]".utf8),
                  Data(repeating: 0x20, count: 70 * 1024)] {
            #expect(WorkHookParser.events(hook: "tool", json: d, now: now).isEmpty)
        }
        let big = Data((#"{"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"a","status":"pending"}]},"pad":""#
            + String(repeating: "x", count: 70 * 1024) + #""}"#).utf8)
        #expect(WorkHookParser.events(hook: "tool", json: big, now: now).isEmpty)
        #expect(WorkHookParser.events(hook: "nope", json: fx("agent"), now: now).isEmpty)
    }
}
