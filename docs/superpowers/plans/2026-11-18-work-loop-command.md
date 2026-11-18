# `/collie:loop` and the loop in the work panel (slice 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner starts a loop by typing `/collie:loop <request>` in a Shepherd terminal, and watches and stops it in the work panel.

**Architecture:** The command is a static Markdown file in a per-terminal plugin named `collie`, written by the daemon under Collie's data and passed to the agent with `--plugin-dir` (the route `ProcedureSkills` already uses). It only teaches the agent the procedure; the daemon's rules from slice 1 (`work.run` refusals, the owner's card) stay the only enforcement. The panel reads `Work.loop`, which `work.status` already returns, and calls `work.stop`.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI (`ColliePlugins`), `CollieDaemonKit`.

**Spec:** `docs/superpowers/specs/2026-11-17-work-run-design.md` (sections "How the owner starts a loop", "A loop is a work being run", "Left to the builder", and the 2026-11-18 updates at the top).

## What was checked before writing this (2026-11-18)

- **Claude Code 2.1.327:** a plugin `{"name":"collie"}` with `commands/loop.md` passes `claude plugin validate`, and
  `claude --plugin-dir <dir> -p "/collie:loop zebra"` ran the command with `$ARGUMENTS` = `zebra`. `--plugin-dir` is
  repeatable (`--help`).
- **Cursor (`cursor-agent` 2026.11.17):** the owner typed `/colli` in a TUI running a probe plugin named `collieprobe`:
  the menu listed `/collie:loop` with the description of the file `commands/collie:loop.md`. So a plugin's commands are
  listed, and **not** namespaced by the plugin: the file's own name is the command (**outcome B**). Listed only: the
  command was not run (Task 3's by-hand step runs it). Print mode (`-p`) returned nothing in 70 s and `collie ask`
  refuses to send a slash command, so only a person in the TUI can check.
- **The panel** already decodes whole `Work` values (`work.status --all`), so `w.loop`, `task.tries`, `task.lastFailure`
  and `task.check` reach it today; the store's `onChange` already emits `work.changed` on every loop update.
- **The approval** of tasks, checks and limits is already an app card (slice 1). The command's "show the list and wait"
  step is the conversation before it; the card is what binds.

## Global Constraints

- The command's name is `/collie:loop` (owner's decision). No other spelling is offered where the agent supports it.
- Nothing is written to `~/.claude`, `~/.cursor` or the repo. Plugin files live under Collie's root, dirs 0700, files 0600.
- The command's text is a compile-time constant: no agent, user, task or memory text is ever interpolated into it.
- The command teaches; it grants nothing. No daemon rule is relaxed because the command was used.
- A terminal always launches: a plugin that can't be rendered, or a `claude` without `--plugin-dir`, launches as before.
- Hook subcommand names (`AgentLaunch.hookSubcommands`) do not change.
- Tests: only the suites named in each task, `swift test --disable-sandbox --filter <Suite>`, in an isolated worktree with
  its own build dir. Never the full suite. No push, no `bundle-app`, no install or restart of the app.
- One commit per task, explicit `git add <paths>`, `git diff <file>` before adding a file other agents also touch.
- Owner-facing copy in Portuguese; the command's text in English (as the orientation), ending in "Answer in the owner's language."

## Review Focus

1. **A `claude` that can't take the plugin** (no `--plugin-dir`, or the render fails on a symlinked dir): the terminal
   launches exactly as before, with no flag pointing at nothing. Tests in Task 2.
2. **Relaunch after a sandbox grant** (`resume: true`): the command dir is rendered again and both `--plugin-dir` flags
   come before `--continue`. Test in Task 2.
3. **A loop that is no longer running** (stopped by a daemon restart, or finished): the panel shows how it ended and
   offers no stop action. Test in Task 4.
4. **Stop on a loop that just ended, or whose terminal is gone:** the daemon's refusal reaches the panel as a Portuguese
   sentence, not a raw English error. Test in Task 4.
5. **`/collie:loop` typed where a loop can't start** (not a Shepherd, the pasture, a shared folder): the command's first
   step makes the agent say so and stop; `work.run` refuses anyway (slice 1's tests). Test of the text in Task 2.

---

### Task 1: Gate: can a Cursor plugin carry the command?

Not code. **Done on 2026-11-18 except for the record: outcome B** (see "What was checked"). Steps 1 and 3 are done (the
probe is gone); what is left is Step 2's write-up in the report and the spec, and its commit. Task 3 exists and writes
`commands/collie:loop.md`.

**Files:**
- Modify: `docs/superpowers/spikes/2026-10-22-cursor/REPORT.md` (new section "§9 Plugin commands")
- Modify: `docs/superpowers/specs/2026-11-17-work-run-design.md` (one line under the 2026-11-18 updates)

- [ ] **Step 1: Probe.** A probe plugin is at `.collie/loop-probe/collie` (untracked): `commands/loop.md` answers
  `PINEAPPLE-42`, `commands/collie:loop.md` answers `MANGO-77`. Terminal `cur-probe` runs `cursor-agent` with it. The
  owner types `/` there and reports which names the menu lists, then runs each one that is listed.

- [ ] **Step 2: Record the outcome**, one of:
  - **A** the TUI lists `/collie:loop` for `commands/loop.md` (namespaced by the plugin's name): Task 3 writes `commands/loop.md`.
  - **B** it lists `/loop` and `/collie:loop` only for the file `collie:loop.md`: Task 3 writes `commands/collie:loop.md` only.
  - **C** neither is listed, or a listed one does not run: Task 3 is dropped. Cursor Shepherds start a loop in plain
    language (their orientation's `Loop:` line already teaches it); the spec says so.

- [ ] **Step 3: Clean up and commit.** `collie dismiss cur-probe`; delete `.collie/loop-probe`.

```bash
git add docs/superpowers/spikes/2026-10-22-cursor/REPORT.md docs/superpowers/specs/2026-11-17-work-run-design.md
git commit -m "docs(spike): whether a Cursor plugin can carry /collie:loop"
```

---

### Task 2: The command, and Claude terminals get it

**Files:**
- Create: `Sources/CollieDaemonKit/Work/LoopCommand.swift`
- Modify: `Sources/CollieDaemonKit/AgentLaunch.swift:102-138` (`pluginDir: URL?` becomes `pluginDirs: [URL]`)
- Modify: `Sources/CollieDaemonKit/CommandRouter.swift:934-938,1028-1050` (collect both dirs, pass them on)
- Test: `Tests/CollieDaemonKitTests/LoopCommandTests.swift` (new)
- Test: `Tests/CollieDaemonKitTests/AgentLaunchTests.swift:58,62` (the two call sites, plus one new test)

**Interfaces:**
- Consumes: `SandboxLaunch.dir(_:root:)`, `AgentLaunch.isClaude(_:)`, `config.claudePluginDir`, `ProcedureSkills.render`'s
  write pattern (build beside, swap in, refuse symlinks).
- Produces:

```swift
/// `/collie:loop`: a static command in a per-terminal plugin named `collie`
/// (`<root>/sandbox/<terminal>/plugin/collie`, beside `collie-procedures`; removed with the terminal).
enum LoopCommand {
    static let plugin = "collie", name = "loop"
    /// The procedure, no frontmatter. A constant: nothing is interpolated.
    static let body: String
    /// `commands/loop.md`. `arguments` true (Claude): the first line carries `$ARGUMENTS`;
    /// false (an agent that appends what follows the command): "The owner's request follows this command."
    static func markdown(arguments: Bool) -> String
    static func dir(_ terminal: UUID, root: URL) -> URL
    /// `.claude-plugin/plugin.json` and `commands/loop.md`, built beside `dir` and swapped in. Refuses a symlink at
    /// `dir`, `plugin/` or the terminal's dir. Dirs 0700, files 0600.
    static func render(into dir: URL) throws
}
extension CommandRouter {
    /// nil: not Claude, no `--plugin-dir` in the installed claude, or the render failed (logged; it launches as before).
    func loopCommandDir(_ rec: TerminalRecord, user: [String: String]) async -> URL?
}
// AgentLaunch.launchSpec(…, pluginDirs: [URL] = [])   // Claude only; one `--plugin-dir` each, in order
```

The exact copy of `body` (frontmatter `description: Run a list of tasks unattended in a Collie loop (collie work run)`,
`argument-hint: <what to build>`):

```text
A loop runs each task with a fresh agent and nobody to answer questions. Only the task's check decides whether it is done. Do this, in order:

1. Only a Shepherd inside a paddock can start a loop (it resets that worktree between attempts). If you are not one, tell the owner to run this from a Shepherd terminal in a paddock, and stop.
2. Break the request into small tasks, in the order they must run. For each one write a spec file in the project (what to build, the acceptance criteria) and choose a check: a shell command, run in the paddock's worktree, that exits 0 only when the result is really there. A check that only proves the code builds, or that the task's own new tests pass, is weak: say so when you cannot do better.
3. Show the owner, in chat: every task, its spec file, its check word for word, and the limits you propose (--max attempts in all, required, 1 to 30; --tries per task, default 3; --timeout per turn; --budget for everything). Wait for the answer. Register and run nothing before it.
4. Once the owner agrees: collie work task add "<title>" --spec <file> --check '<command>' for each task, then collie work run --max <n>. Every open task of the work needs a check: defer or drop the ones that are not part of the loop.
5. The owner now gets a card in the Collie app with the same tasks, checks and limits. Only their Permitir starts the loop: tell them to look at it. Do not edit the paddock's worktree while the loop runs.
6. A line "[collie] Laço de … terminou" reaches you when it ends. Then run collie work status and report what passed, what was deferred and why. Never land or push.

To stop a loop: collie work stop. Answer in the owner's language.
```

With `arguments: true` the body is preceded by `The owner asked for an unattended loop: $ARGUMENTS` and a blank line.

- [ ] **Step 1: Write the failing tests** in `LoopCommandTests.swift`:

```swift
@Test func rendersAPluginNamedCollieWithTheLoopCommand() throws {
    let root = try tempDir(), dir = LoopCommand.dir(UUID(), root: root)
    try LoopCommand.render(into: dir)
    #expect(dir.lastPathComponent == "collie" && dir.deletingLastPathComponent().lastPathComponent == "plugin")
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: String]
    #expect(manifest?["name"] == "collie")
    let md = try String(contentsOf: dir.appendingPathComponent("commands/loop.md"), encoding: .utf8)
    #expect(md == LoopCommand.markdown(arguments: true))
    #expect(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("commands/loop.md").path)[.posixPermissions] as? Int == 0o600)
    try LoopCommand.render(into: dir)   // a second render swaps it in, no leftover beside it
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path) == ["collie"])
}

@Test func theTextIsStaticAndTeachesTheRules() {
    let md = LoopCommand.markdown(arguments: true)
    #expect(md.hasPrefix("---\ndescription: "))
    #expect(md.components(separatedBy: "$ARGUMENTS").count == 2)          // once
    #expect(!LoopCommand.markdown(arguments: false).contains("$ARGUMENTS"))
    #expect(!md.contains("`"))                                              // no inline shell (`!`cmd``) can hide in it
    for must in ["Only a Shepherd inside a paddock", "Wait for the answer", "collie work run --max", "Permitir", "Never land or push"] {
        #expect(md.contains(must))
    }
}

@Test func refusesASymlinkedDir() throws {
    let root = try tempDir(), dir = LoopCommand.dir(UUID(), root: root), elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.deletingLastPathComponent().deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: dir.deletingLastPathComponent(), withDestinationURL: elsewhere)
    #expect(throws: (any Error).self) { try LoopCommand.render(into: dir) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
}
```

  And, following the daemon-level tests in `ProcedureSkillsTests.swift:165-230` (same harness, `claudePluginDir` fixed):

```swift
@Test func aClaudeTerminalLaunchesWithBothPlugins()          // argv holds --plugin-dir …/plugin/collie-procedures and …/plugin/collie
@Test func withoutPluginDirSupportNothingIsRenderedOrPassed() // claudePluginDir = false: no flag, no plugin/collie dir
@Test func aShellOrCodexTerminalGetsNoCommand()               // no plugin/collie dir
@Test func theCommandDirGoesWithTheTerminal()                 // after dismiss the dir is gone
@Test func aRelaunchRendersItAgainBeforeContinue()            // resume: argv … --plugin-dir A --plugin-dir B --continue
@Test func aFailedRenderStillLaunches()                       // plugin/ pre-made as a symlink: the terminal runs, no collie flag
```

  In `AgentLaunchTests`: the two existing calls pass `pluginDirs: [plugin]`; add
  `twoPluginDirsEachGetAFlagInOrder` asserting the argument ends with
  `--plugin-dir '<a>' --plugin-dir '<b>'` (and `--continue` after them with `resume: true`).

- [ ] **Step 2: Run them, expect failure**

Run: `swift test --disable-sandbox --filter LoopCommandTests` → FAIL: `cannot find 'LoopCommand' in scope`.

- [ ] **Step 3: Implement `LoopCommand`** as in Interfaces. The swap and symlink checks are `ProcedureSkills.render`'s; share them only if it costs less code than the copy.

- [ ] **Step 4: `pluginDirs` in `AgentLaunch.launchSpec`** and both router sites: `[await skillsDir(rec, user: user), await loopCommandDir(rec, user: user)].compactMap { $0 }`, rendered after `memory.endSession`, as `skillsDir` is today.

- [ ] **Step 5: Run the suites, expect PASS**

Run: `swift test --disable-sandbox --filter "LoopCommandTests|AgentLaunchTests|ProcedureSkillsTests"`

- [ ] **Step 6: Check it by hand once** (no token spent beyond one short turn): render into a temp dir, then
  `claude plugin validate <dir>` passes and `claude --plugin-dir <dir> -p "/collie:loop teste"` answers with the
  procedure's step 1 (run outside a Collie terminal it is not a Shepherd: it must say so and stop).

- [ ] **Step 7: Commit**

```bash
git add Sources/CollieDaemonKit/Work/LoopCommand.swift Sources/CollieDaemonKit/AgentLaunch.swift \
  Sources/CollieDaemonKit/CommandRouter.swift Tests/CollieDaemonKitTests/LoopCommandTests.swift \
  Tests/CollieDaemonKitTests/AgentLaunchTests.swift
git commit -m "feat(work): /collie:loop for Claude terminals"
```

---

### Task 3: Cursor terminals get it (only if Task 1 ended in A or B)

**Files:**
- Modify: `Sources/CollieDaemonKit/AgentLaunch.swift:50-60` (`cursorPlugin`)
- Test: `Tests/CollieDaemonKitTests/AgentLaunchTests.swift`

**Interfaces:**
- Consumes: `LoopCommand.markdown(arguments: false)`, Task 1's outcome.
- Produces: `cursorPlugin` also writes `commands/<file>` (0600), where `<file>` is `loop.md` (outcome A) or
  `collie:loop.md` (outcome B), as `static let cursorCommandFile` on `LoopCommand` with a comment naming the report section.

- [ ] **Step 1: Failing test** `cursorPluginCarriesTheLoopCommand`: after `launchSpec` for a `.cursor` record (and for a
  custom `cursor-agent` command), `<cursorPluginDir>/commands/<LoopCommand.cursorCommandFile>` equals
  `LoopCommand.markdown(arguments: false)`, mode 0600; `hooks/hooks.json` still holds only `sessionStart`.
- [ ] **Step 2: Run** `swift test --disable-sandbox --filter AgentLaunchTests` → FAIL (no such file).
- [ ] **Step 3: Write the file in `cursorPlugin`.** `write` there takes a JSON object; add a text twin with the same
  directory creation and mode.
- [ ] **Step 4: Run** the same filter → PASS.
- [ ] **Step 5: By hand:** summon a Cursor Shepherd in a paddock, type `/collie:loop teste`: it starts the procedure.
- [ ] **Step 6: Commit** `feat(work): /collie:loop for Cursor terminals`.

---

### Task 4: The loop in the work panel

**Files:**
- Modify: `Sources/ColliePlugins/WorkPanel.swift` (model: near `:65-78` and `:205-220`; view: `workRow` `:389`, `details` `:431`)
- Modify: `Sources/CollieDaemonKit/WorkCommands.swift:303-313` (`work.list` gains `loop`)
- Test: `Tests/ColliePluginsTests/WorkPanelTests.swift`, `Tests/CollieDaemonKitTests/WorkLoopCommandTests.swift`

**Interfaces:**
- Consumes: `Work.loop: WorkLoopState?`, `WorkTask.check/tries/lastFailure`, `work.stop` (`terminal` arg from the app),
  `WorkStatusText.loopLine(_:)` (daemon side).
- Produces:

```swift
// WorkPanelModel
public struct LoopBadge: Equatable, Sendable { public let text: String; public let running: Bool }
/// nil: a sequential work. Running: "em laço: <task title> (tentativa 2/3) · 4/10 no total"
/// (the "· n/max" part only when `max` is set); else "laço parado (4 tentativas)" / "laço terminou (4 tentativas)".
public func loopBadge(_ w: Work) -> LoopBadge?
/// `work.stop` on the work's terminal; a refusal goes to `error` in Portuguese (`describe`).
public func stopLoop(_ terminal: String) async
/// One line under a task that a loop ran: "2 tentativas · <lastFailure>" (nil when it has neither).
public static func attemptLine(_ t: WorkTask) -> String?
```

  `work.list` entries gain `"loop": <WorkStatusText.loopLine(w)>` when the work has one.

- [ ] **Step 1: Failing tests** in `WorkPanelTests` (the `Fake` already records calls):

```swift
@Test func loopBadgeFollowsTheLoopState() async {
    let (m, _) = make()
    var w = Work(title: "Piso", terminalId: UUID(), tasks: [WorkTask(id: "a1", title: "Piso de relevância", state: .inProgress)])
    #expect(m.loopBadge(w) == nil)
    w.loop = WorkLoopState(state: .running, task: "a1", attempt: 2, tries: 3, max: 10, used: 4)
    #expect(m.loopBadge(w) == .init(text: "em laço: Piso de relevância (tentativa 2/3) · 4/10 no total", running: true))
    w.loop?.max = nil
    #expect(m.loopBadge(w)?.text == "em laço: Piso de relevância (tentativa 2/3)")
    w.loop?.state = .stopped
    #expect(m.loopBadge(w) == .init(text: "laço parado (4 tentativas)", running: false))
    w.loop?.state = .finished
    #expect(m.loopBadge(w) == .init(text: "laço terminou (4 tentativas)", running: false))
}

@Test func stopLoopCallsWorkStopOnTheTerminal() async {
    let (m, f) = make()
    await m.stopLoop("Collie Main")
    #expect(await f.all("work.stop") == [["terminal": .string("Collie Main")]])
}

@Test func aRefusedStopReadsInPortuguese() async {
    let (m, f) = make()
    await f.set(failure: ProtocolError(code: .invalidArgs, message: "no loop is running on 'Collie Main's work"))
    await m.stopLoop("Collie Main")
    #expect(m.error == "Nenhum laço está rodando neste trabalho.")
}

@Test func attemptLineShowsTriesAndTheLastFailure() {
    #expect(WorkPanelModel.attemptLine(WorkTask(id: "a", title: "t")) == nil)
    #expect(WorkPanelModel.attemptLine(WorkTask(id: "a", title: "t", tries: 2, lastFailure: "check failed")) == "2 tentativas · check failed")
    #expect(WorkPanelModel.attemptLine(WorkTask(id: "a", title: "t", tries: 1)) == "1 tentativa")
}
```

  In `WorkLoopCommandTests`: `workListCarriesTheLoopLine`: a work with `loop.state == .stopped`, `used == 2` lists
  `"loop": "laço parado (2 tentativas)"`; a sequential work has no `loop` key.

- [ ] **Step 2: Run** `swift test --disable-sandbox --filter "WorkPanelTests|WorkLoopCommandTests"` → FAIL (`loopBadge` not found).

- [ ] **Step 3: Model.** The three members above. The Portuguese sentence for the refused stop goes where `describe`
  maps the other daemon messages (`WorkPanel.swift:257`).

- [ ] **Step 4: View.**
  - `workRow`: under the terminal line, when `loopBadge(w)` is not nil, a `CollieTag(badge.text, tone: badge.running ? .accent : .secondary)`.
  - The row's menu: `Button("Parar laço")` only while `badge.running` and the work has a terminal name, calling
    `stopLoop`; its help: "Para depois do veredito da tentativa atual".
  - `details`: under each task, `attemptLine` in `.collieUI(11)`, secondary colour; and, when the task has a check and
    the work has a loop, the check in `.collieMono(11)`, one line, `.textSelection(.enabled)`.
  - A loop's attempts are jobs (`JobKind.loop`): the existing Jobs list already shows the running one. No change.

- [ ] **Step 5: `work.list`** gains the key.

- [ ] **Step 6: Run** the same filter → PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/ColliePlugins/WorkPanel.swift Sources/CollieDaemonKit/WorkCommands.swift \
  Tests/ColliePluginsTests/WorkPanelTests.swift Tests/CollieDaemonKitTests/WorkLoopCommandTests.swift
git commit -m "feat(work-panel): the loop's state and a stop action"
```

---

### Task 5: Orientation and docs

**Files:**
- Modify: `Sources/CollieDaemonKit/CollieOrientation.swift:117-121` (the `Loop:` line)
- Modify: `docs/referencia.md:798-827`, `docs/superpowers/specs/2026-11-17-work-run-design.md` (2026-11-18 updates)
- Test: `Tests/CollieDaemonKitTests/CollieOrientationTests.swift`

- [ ] **Step 1: Failing test** `theLoopLineNamesTheCommandForClaude`: a Claude Shepherd in a paddock gets
  `- Loop (owner: /collie:loop <request>): work task add --spec --check; collie work run, work stop only after the owner approved the task list and the checks.`
  and the whole text stays within the 1500 cap; an agent with no command (Codex always; Cursor if Task 1 ended in C)
  keeps today's line unchanged.
- [ ] **Step 2: Run** `swift test --disable-sandbox --filter CollieOrientationTests` → FAIL.
- [ ] **Step 3: Change the line.** If the Claude Shepherd's text would pass the cap in a form that is not already the
  tight one, keep today's line there too (the command is still in the `/` menu) and make the test say so.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Docs.** `docs/referencia.md`: how the owner starts a loop (`/collie:loop <pedido>` in a Shepherd terminal
  in a paddock, which agents have it), and the panel (the badge, "Parar laço", attempts and last failure per task). The
  spec: a 2026-11-18 update line saying slice 2 is built, how the command reaches each agent, and what "Left to the
  builder" turned into.
- [ ] **Step 6: Commit** `docs(work): /collie:loop and the loop in the work panel`.

---

## Not in this plan

- A loop still waiting for the owner's card is not shown in the panel's work row (the state lives in the router, not in
  `Work`); the card itself is what the owner sees.
- Codex gets no command (no per-terminal plugin route). Its Shepherds start a loop in plain language.
- No model-invoked skill: `/collie:loop` runs only when the owner types it. An agent may still offer it.
