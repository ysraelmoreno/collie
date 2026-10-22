import Foundation
import CollieCore

/// What one Claude Code hook tells the registry. `jobEnded(id:)` names a job id or alias; `"agent:<agent_id>"` = the
/// subagent whose alias is that agent id (SubagentStop); `""` = the oldest running background subagent (SubagentStop without agent_id).
/// `taskChanged(_, hasState: false)`: the tool gave no status (the task's `state` is then only the default for a new one).
public enum WorkEvent: Equatable, Sendable {
    case tasks([WorkTask]), taskChanged(WorkTask, hasState: Bool), jobStarted(WorkJob), jobEnded(id: String, result: String?), compacted, sessionEnded
}

/// Pure parser of hook stdin JSON. Never throws: anything unexpected yields `[]`.
public enum WorkHookParser {
    public static let maxBytes = 64 * 1024
    static let maxResult = 280, maxLabel = 80

    public static func events(hook: String, json: Data, now: Date) -> [WorkEvent] {
        switch hook {
        case "precompact": return [.compacted]
        case "session-end": return [.sessionEnded]
        case "subagent-stop":
            // a sync subagent's stop names an agent no job carries (its job starts in the PostToolUse after): the applier ignores it
            let root = json.count <= maxBytes ? (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] : nil
            let agent = (root?["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return [.jobEnded(id: agent.map { "agent:" + $0 } ?? "", result: nil)]
        case "tool": break
        default: return []
        }
        guard !json.isEmpty, json.count <= maxBytes,
              let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let tool = root["tool_name"] as? String else { return [] }
        let input = root["tool_input"] as? [String: Any] ?? [:]
        let response = root["tool_response"]
        let useId = root["tool_use_id"] as? String ?? ""
        switch tool {
        case "TodoWrite": return todoWrite(input, now)
        case "TaskCreate", "TaskUpdate": return singleTask(input, response, now)
        case "Agent": return subagent(input, response, useId, now)
        case "Task": // legacy subagent launch vs task-list tool: by input fields
            if input["prompt"] != nil || input["subagent_type"] != nil { return subagent(input, response, useId, now) }
            return singleTask(input, response, now)
        case "Bash":
            guard input["run_in_background"] as? Bool == true, let cmd = input["command"] as? String else { return [] }
            let id = firstString(response, ["backgroundTaskId", "background_task_id", "shell_id", "shellId", "bash_id", "task_id"]) ?? useId
            guard !id.isEmpty else { return [] }
            return [.jobStarted(WorkJob(id: id, kind: .shell, label: clip(cmd, maxLabel), startedAt: now))]
        case "TaskOutput", "BashOutput", "TaskStop", "KillShell":
            guard let id = ["task_id", "shell_id", "bash_id"].lazy.compactMap({ input[$0] as? String }).first else { return [] }
            let stop = tool == "TaskStop" || tool == "KillShell"
            let ended = stop ? stopped(response) : ["completed", "failed", "killed", "stopped", "exited"].contains(structuredStatus(response))
            return ended ? [.jobEnded(id: id, result: nil)] : []
        default: return []
        }
    }

    private static func todoWrite(_ input: [String: Any], _ now: Date) -> [WorkEvent] {
        guard let todos = input["todos"] as? [[String: Any]] else { return [] }
        var seen: [String: Int] = [:]
        return [.tasks(todos.compactMap { t in
            guard let c = t["content"] as? String, !c.isEmpty else { return nil }
            var id = (t["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stableId(c)
            seen[id, default: 0] += 1
            if let n = seen[id], n > 1 { id += "-\(n)" }
            return WorkTask(id: id, title: c, state: state(t["status"] as? String), updatedAt: now)
        })]
    }

    /// TaskCreate/TaskUpdate. `title` is "" when an update carries no subject: the applier keeps the stored title.
    private static func singleTask(_ input: [String: Any], _ response: Any?, _ now: Date) -> [WorkEvent] {
        let subject = (input["subject"] as? String) ?? ""
        let given = firstString(input, ["taskId", "id"]) ?? firstString((response as? [String: Any])?["task"], ["id", "taskId"])
            ?? firstString(response, ["taskId", "id"]) ?? textId(flat(response))
        guard let id = given ?? (subject.isEmpty ? nil : stableId(subject)) else { return [] }
        guard !subject.isEmpty || input["status"] != nil else { return [] }
        let status = input["status"] as? String
        let st: TaskState = status == "deleted" ? .abandoned : state(status)
        return [.taskChanged(WorkTask(id: id, title: subject, state: st, updatedAt: now), hasState: status != nil)]
    }

    private static func subagent(_ input: [String: Any], _ response: Any?, _ useId: String, _ now: Date) -> [WorkEvent] {
        guard !useId.isEmpty else { return [] }
        let label = (input["description"] as? String) ?? (input["prompt"] as? String) ?? "subagent"
        let background = input["run_in_background"] as? Bool == true
        var out: [WorkEvent] = [.jobStarted(WorkJob(id: useId, kind: .subagent, label: clip(label, maxLabel), startedAt: now,
                                                    alias: background ? agentId(response) : nil))]
        if !background {
            let text = responseText(response)
            out.append(.jobEnded(id: useId, result: text.isEmpty ? nil : clip(text, maxResult)))
        }
        return out
    }

    /// Old list -> new list, as the tasks to store. Order follows the new list, then what vanished.
    public static func diff(old: [WorkTask], new: [WorkTask], now: Date) -> [WorkTask] {
        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var out: [WorkTask] = []
        for n in new {
            guard var t = oldById[n.id] else { out.append(WorkTask(id: n.id, title: n.title, state: n.state, updatedAt: now)); continue }
            t.title = n.title
            // a command's deferral/abandon sticks until the agent moves the task on
            let pinned = (t.state == .deferred || t.state == .abandoned) && t.reason != nil && n.state == .open
            if !pinned && t.state != n.state { t.state = n.state; t.reason = nil; t.updatedAt = now }
            out.append(t)
        }
        let kept = Set(new.map(\.id))
        for var t in old where !kept.contains(t.id) {
            if t.state != .done && t.state != .abandoned && t.state != .deferred { t.state = .abandoned; t.reason = nil; t.updatedAt = now }
            out.append(t)
        }
        return out
    }

    // MARK: helpers

    /// A background launch's agent id: `agentId`/`agent_id` at the top or one level down, else `agentId: <id>` in the text.
    private static func agentId(_ r: Any?) -> String? {
        let keys = ["agentId", "agent_id"]
        if let s = firstString(r, keys) { return s }
        if let d = r as? [String: Any], let s = d.values.lazy.compactMap({ firstString($0, keys) }).first { return s }
        let text = responseText(r).isEmpty ? flat(r) : responseText(r)
        guard let m = text.range(of: #"agent_?[iI]d"?\s*[:=]\s*"?[A-Za-z0-9_-]+"#, options: .regularExpression) else { return nil }
        return String(text[m]).split(whereSeparator: { ":= \"".contains($0) }).last.map(String.init)
    }

    /// `tool_response.task.status`, else top-level `status`, lowercased; "" when absent. Never reads output text.
    private static func structuredStatus(_ r: Any?) -> String {
        guard let d = r as? [String: Any] else { return "" }
        return ((d["task"] as? [String: Any])?["status"] as? String ?? d["status"] as? String ?? "").lowercased()
    }

    /// TaskStop/KillShell success: `success: true` or a killed/stopped status; else the text (string or dict `message`) must say killed/stopped/terminated without a negation.
    private static func stopped(_ r: Any?) -> Bool {
        var text = r as? String
        if let d = r as? [String: Any] {
            if let ok = d["success"] as? Bool { return ok }
            if ["killed", "stopped", "terminated"].contains(structuredStatus(d)) { return true }
            text = d["message"] as? String
        }
        guard let t = text?.lowercased() else { return false }
        let no = ["not found", "no shell", "no task", "not ", "fail", "could not", "unable"]
        return ["killed", "stopped", "terminated"].contains { t.contains($0) } && !no.contains { t.contains($0) }
    }

    private static func state(_ s: String?) -> TaskState {
        switch s { case "in_progress": .inProgress; case "completed": .done; case "deleted": .abandoned; default: .open }
    }

    /// FNV-1a: stable across runs (Hasher is seeded per process).
    static func stableId(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "t" + String(h, radix: 16)
    }

    private static func clip(_ s: String, _ n: Int) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(n)) }

    private static func firstString(_ v: Any?, _ keys: [String]) -> String? {
        guard let d = v as? [String: Any] else { return nil }
        for k in keys {
            if let s = d[k] as? String, !s.isEmpty { return s }
            if let n = d[k] as? Int { return String(n) }
        }
        return nil
    }

    /// "Task #7 created successfully" -> "7".
    private static func textId(_ s: String) -> String? {
        guard let r = s.range(of: #"#(\d+)"#, options: .regularExpression) else { return nil }
        return String(s[r].dropFirst())
    }

    /// The response as text: a string, or JSON serialized.
    private static func flat(_ v: Any?) -> String {
        if let s = v as? String { return s }
        guard let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    private static func responseText(_ v: Any?) -> String {
        if let s = v as? String { return s }
        guard let d = v as? [String: Any] else { return "" }
        if let parts = d["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return firstString(d, ["content", "result", "output", "text"]) ?? ""
    }
}
