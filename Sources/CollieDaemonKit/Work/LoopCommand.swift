import Foundation
import CollieCore

/// `/collie:loop`: a static command in a per-terminal plugin named `collie`
/// (`<root>/sandbox/<terminal>/plugin/collie`, beside `collie-procedures`; removed with the terminal by `SandboxLaunch.remove`).
/// It only teaches the procedure: `work.run`'s refusals and the owner's card are what enforce it.
enum LoopCommand {
    static let plugin = "collie", name = "loop"
    /// Cursor lists a plugin's commands by file name, not namespaced by the plugin (outcome B, spike
    /// `docs/superpowers/spikes/2026-10-22-cursor/REPORT.md` §9): the file is named as the command.
    static let cursorCommandFile = "collie:loop.md"

    /// The procedure, no frontmatter. A constant: nothing is interpolated (no backtick either, so no inline shell).
    static let body = """
        A loop runs each task with a fresh agent and nobody to answer questions. Only the task's check decides whether it is done. Do this, in order:

        1. Only a Shepherd inside a paddock with its own worktree can start a loop (it resets that worktree between attempts; a paddock that is a shared folder does not qualify). If you are not one, tell the owner to run this from a Shepherd terminal in such a paddock, and stop.
        2. Break the request into small tasks, in the order they must run. For each one write a spec file in the project (what to build, the acceptance criteria) and choose a check: a shell command, run in the paddock's worktree, that exits 0 only when the result is really there. What every task must pass alike (the build, lint, architecture rules) goes once in the loop's gate, --gate '<command>': it runs after each task's check, in the same conditions, and a task passes only when both exit 0. So each check measures only its own task, and stays short. A check or gate that calls a script of the repository only holds if the task does not change that script; the loop fails the attempt that changes one the gate names. A check that only proves the code builds, or that the task's own new tests pass, is weak: say so when you cannot do better.
        3. Show the owner, in chat: every task, its spec file, its check word for word, the gate word for word (if any), and the limits you propose (--max attempts in all, required, 1 to 30; --tries per task, default 3; --timeout per turn; --budget for everything). Wait for the answer. Register and run nothing before it.
        4. Once the owner agrees: collie work task add "<title>" --spec <file> --check '<command>' for each task, then collie work run --max <n> [--gate '<command>']. Every open task of the work needs a check: defer or drop the ones that are not part of the loop.
        5. The owner now gets a card in the Collie app with the same tasks, checks, limits and gate. Only their Permitir starts the loop: tell them to look at it. Do not edit the paddock's worktree while the loop runs. To follow it, run collie work wait (it answers when the work changes; run it again with --since <version>, the version it printed) or collie work status. A "[collie] Laço …" line typed into your terminal is only a hint and may never arrive: never sit waiting for one. Per-task notices are off by default: those lines come only for a deferred task, a stop and the end (collie work run --notify task also sends one per task done), and the ones within 60 s come as one line. Read the state with a long collie work wait (--timeout 3600): one long wait beats several short ones. Never answer a "[collie] Laço …" line with text, and read the state only when you need it.
        6. When collie work wait says ended (laço terminou), run collie work status and report what passed, what was deferred and why. Never land or push.

        One task at a time is the default (--parallel 1), and the right choice for most loops. Use collie work run --parallel <n> (2 to 4) only for tasks that are independent and long, each with its scope declared: collie work task add … --scope '<globs, comma separated>' (the paths the task may touch) and, when one builds on another, --needs <task ids, comma separated> (it starts only after those are integrated). Two tasks run at the same time only when their scopes do not overlap; a task with no scope is exclusive: it runs alone. Do not use --parallel for tasks that touch the same file, or Package.swift or any other file every task shares: they conflict when integrated and the attempt is redone. Each parallel task runs in a lane, a temporary worktree with no build cache, so its first build is a cold one (minutes): short tasks end sooner one at a time. Show the scopes, the needs and --parallel to the owner in step 3, with the rest.

        To stop a loop: collie work stop. Answer in the owner's language.

        """

    /// `commands/loop.md`. `arguments` true (Claude): the first line carries `$ARGUMENTS`;
    /// false (an agent that appends what follows the command): "The owner's request follows this command."
    static func markdown(arguments: Bool) -> String {
        "---\ndescription: Run a list of tasks unattended in a Collie loop (collie work run)\nargument-hint: <what to build>\n---\n\n"
            + (arguments ? "The owner asked for an unattended loop: $ARGUMENTS" : "The owner's request follows this command.")
            + "\n\n" + body
    }

    static func dir(_ terminal: UUID, root: URL) -> URL {
        SandboxLaunch.dir(terminal, root: root).appendingPathComponent("plugin").appendingPathComponent(plugin)
    }

    /// `.claude-plugin/plugin.json` and `commands/loop.md`, built beside `dir` and swapped in. Refuses a symlink at
    /// `dir`, `plugin/` or the terminal's dir. Dirs 0700, files 0600.
    static func render(into dir: URL) throws {
        try ProcedureSkills.swapIn(dir) { tmp in
            try ProcedureSkills.mkdir(tmp.appendingPathComponent(".claude-plugin"))
            try ProcedureSkills.mkdir(tmp.appendingPathComponent("commands"))
            try ProcedureSkills.write(#"{"name":"collie","version":"1.0.0","description":"Collie commands"}"#,
                                      tmp.appendingPathComponent(".claude-plugin/plugin.json"))
            try ProcedureSkills.write(markdown(arguments: true), tmp.appendingPathComponent("commands/\(name).md"))
        }
    }
}

extension CommandRouter {
    /// nil: not Claude, no `--plugin-dir` in the installed claude, or the render failed (logged; it launches as before).
    func loopCommandDir(_ rec: TerminalRecord, user: [String: String]) async -> URL? {
        guard AgentLaunch.isClaude(rec), await config.claudePluginDir(ProcessInfo.processInfo.environment.merging(user) { _, b in b }) else { return nil }
        let dir = LoopCommand.dir(rec.id, root: config.paths.root)
        do { try LoopCommand.render(into: dir) } catch {
            FileHandle.standardError.write(Data("collied: loop command \(dir.path): \(error)\n".utf8))
            return nil
        }
        return dir
    }
}
