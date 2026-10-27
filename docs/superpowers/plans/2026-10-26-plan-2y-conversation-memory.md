# Plan 2Y — Conversation Memory: the Curator Reads What Was Said and Saves It

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At the end of a task or an important conversation, the curator reads the new part of the Claude conversation and saves what it learned (decisions, pitfalls, the user's preferences) as **active** memory, deduplicated against what is already stored.

**Architecture:** Today capture (`Memory/MemoryCapture.swift`) only reads work-registry signals (done tasks, work-branch commits, `Done:`/decision notes). Real data on 2026-10-26: 9 works, all with 0 tasks and 0 commits, none ever captured or proposed — so nothing is saved, and the conversation itself is never read. Add one curator job kind, `conversation`: input = the scrubbed new chunk of the terminal's Claude transcript (`transcript_path` from the hook payloads) plus the nearest existing memories; output = up to 5 items, each new or a duplicate of an existing id. New items are written `status: .active` into the terminal's lot (else project, else global). A per-transcript byte mark makes each chunk read once.

**Tech Stack:** Swift 6.2, existing `Curator`/`CuratorRunner` (`claude -p`, haiku, no tools, own Seatbelt), `RepoMemory`, `LotBoards.scrub`.

**Spec:** user request 2026-10-26 ("sempre no final de tarefa, conversas importantes, um agente analise a conversa e adicione na memória"); decision: **memória ativa** (not proposals).

## Global Constraints

- Triggers (any): (a) a Claude terminal idle 10 min after a Stop, when the chunk has ≥ 3 user messages; (b) `precompact`; (c) `session-end`; (d) the work closed (`work done` / merge); (e) `collie memory capture` (agent or admin; also a "Salvar na memória" item in the node menu). (a)–(d) never block a hook: detached.
- Transcript path trust: the path comes from an agent-controlled payload. Accept only a regular `.jsonl` file whose real path is under `<config>/projects/` (`CLAUDE_CONFIG_DIR` from the terminal's env, else `~/.claude`, as `AgentLaunch.hasClaudeConversation`); open with `O_NOFOLLOW`; anything else → skip, log one line. Never read any other file.
- Chunk: only user text and assistant text from the bytes after the mark (no tool inputs/outputs, no thinking, no system reminders, no `<pasted_content>` bodies beyond 500 chars); scrubbed with `LotBoards.scrub(_, secrets: auth.secrets())`; cut to the newest `Curator.inputMax`. A chunk under 3 user messages is skipped except for triggers (b)–(e).
- Mark: `<root>/memory/capture-marks.json` `{ "<real transcript path>": <byte offset> }`, written after the memories are on disk (a failed run re-reads the chunk next time). A transcript shorter than its mark (rewritten) → mark reset to 0.
- Cost: counts against the curator's daily cap with the non-correction share (`Curator.limit`); cap reached → job waits, as other kinds. No new cap.
- Output limits: ≤ 5 items a chunk, title ≤ `MemoryCapture.maxTitle`, body ≤ `MemoryCapture.maxBody`, kinds `decision | pitfall | feedback` only, each re-scrubbed. Origin `"conversa (<terminal>)"`.
- `feedback` (the user's preferences) is a user's kind (`MemoryLearning.usersKind`): saved active only when the chunk shows the user saying it (the model returns the quoted user line; the daemon checks it occurs in the chunk's user text) — else dropped.
- Dedup: candidates = the 8 nearest records (same search as `enqueueProposals`) from the target store family; an item marked `duplicateOf: <id>` that matches a candidate id is not written. Unknown id → treated as new.
- Codex and shell terminals: out of scope (no transcript path); unchanged.
- The existing Stop ask ("registre decisões…") stays as is.

## Review Focus

1. A sandboxed agent's hook sends `transcript_path` = a symlink in `~/.claude/projects/x/` to `~/.ssh/id_ed25519`, or `/etc/passwd`: nothing read, nothing sent to the model.
2. A long session compacts 3 times and then ends: each chunk read once; no memory written twice (mark + dedup).
3. A chunk that contains the admin token, a FigCraft edit link or an `API_KEY=…` line: none reaches the model input or a saved memory.
4. Daily cap reached: capture waits, marks unchanged; next day the chunk is still captured.
5. Quick Q&A turn (1–2 user messages) then idle: no model call.

---

### Task 1: Transcript chunk (pure)

**Files:**
- Create: `Sources/CollieDaemonKit/Memory/TranscriptChunk.swift`
- Test: `Tests/CollieDaemonKitTests/TranscriptChunkTests.swift`

**Interfaces:**
- Produces: `enum TranscriptChunk { static func allowed(_ path: String, projectsDir: URL) -> URL?` (real path if allowed); `static func read(_ url: URL, from offset: UInt64, secrets: Set<String>, maxScalars: Int) -> (text: String, userMessages: Int, end: UInt64)?` }.
- Text format: one block per message, `Usuário: …` / `Agente: …`, blank line between.

- [ ] **Step 1: Tests** `allowsJsonlUnderProjects`, `refusesOutside` (`/etc/passwd`, `~/x.jsonl`), `refusesSymlinkOut`, `refusesNonJsonl`, `readsOnlyAfterOffset`, `keepsUserAndAssistantTextOnly` (fixture with tool_use, tool_result, thinking, system-reminder → absent), `countsUserMessages` (tool_result user entries not counted), `scrubsSecrets`, `truncatedToNewest`, `shorterThanOffsetResets` (returns from 0), `partialLastLineIgnored` (`end` stops before it).
- [ ] **Step 2:** `swift test --filter TranscriptChunkTests` → FAIL.
- [ ] **Step 3:** Implement (stream line by line; a malformed line is skipped).
- [ ] **Step 4:** Same filter → PASS.
- [ ] **Step 5: Commit** `feat(memory): read a Claude transcript chunk safely`.

### Task 2: `conversation` curator job → active memories

**Files:**
- Modify: `Sources/CollieDaemonKit/Curator/Curator.swift` (`CuratorJobKind.conversation`, placed before `consolidate`)
- Create: `Sources/CollieDaemonKit/Memory/ConversationCapture.swift` (prompt, JSON Schema, `apply`; marks file)
- Modify: `Sources/CollieDaemonKit/Memory/MemoryLearning.swift` (the job handler dispatch, next to `proposals`)
- Test: `Tests/CollieDaemonKitTests/ConversationCaptureTests.swift` (fake runner)

**Interfaces:**
- Consumes: Task 1.
- Produces: `extension CommandRouter { func captureConversation(_ tid: UUID, transcript: String, force: Bool) async }` (reads chunk, enqueues the job; `force` skips the ≥ 3 rule); `ConversationCapture.Output { items: [{kind, title, body, userQuote?, duplicateOf?}] }`; `static func apply(_ o: Output, chunk: String, candidates: [UUID], secrets:) -> [MemoryRecord]` (pure: limits, kinds, feedback quote check, dedup, scrub, `status: .active`, origin).
- Prompt (pt-BR to the model, fenced input as the other jobs): extract only durable facts useful to a future agent on this project — decisions and why, pitfalls hit, user preferences stated by the user; skip task narration, status, anything temporary; return `[]` if nothing.

- [ ] **Step 1: Tests**
  - `applyWritesActive` (2 items → 2 records `.active`, origin `conversa (dev)`).
  - `applyCapsAtFive`, `applyDropsUnknownKind`, `applyDropsFeedbackWithoutQuote`, `applyKeepsFeedbackWithQuoteInChunk`, `applySkipsDuplicateOfCandidate`, `applyUnknownDuplicateIsNew`, `applyScrubs`.
  - `captureSkipsShortChunk` (2 user messages, `force: false` → runner never called).
  - `captureMarksAfterWrite` (runner ok → mark = chunk end; runner fails → mark unchanged).
  - `captureCapReachedWaits` (Review Focus 4).
  - `capturedTwiceWritesOnce` (same transcript, two triggers → one run).
  - `secretNeverInRunnerInput` (Review Focus 3: the fake runner records its input).
- [ ] **Step 2:** `swift test --filter ConversationCaptureTests` → FAIL.
- [ ] **Step 3:** Implement; store choice as `captureProposals` (lot, else repo for cwd, else global; global → scope `.global`). One job per terminal at a time (reuse the `capturing` pattern).
- [ ] **Step 4:** Same filter → PASS.
- [ ] **Step 5: Commit** `feat(memory): curator saves what a conversation taught as active memory`.

### Task 3: Triggers

**Files:**
- Modify: `Sources/CollieDaemonKit/MemoryHookClient.swift` (`stopOutput`: pass `transcript` = the payload's `transcript_path`)
- Modify: `Sources/CollieDaemonKit/CommandRouter.swift:321` (`turn.completed`: remember `transcript` per terminal; restart that terminal's 10-min idle timer → `captureConversation(force: false)`)
- Modify: `Sources/CollieDaemonKit/WorkCommands.swift:25` (precompact/session-end → also `captureConversation(force: true)` with the payload's `transcript_path`); work close (`work done`, merge in `workTurnEnded`) → `force: true` with the remembered path
- Modify: `Sources/CollieProtocol/Commands.swift` (`memory.capture`: "Save what this conversation taught to memory now"; terminals: own transcript only; admin: `--terminal <name>`), `Sources/CollieApp/TerminalNodeView.swift` (node menu "Salvar na memória", Claude terminals only)
- Test: `Tests/CollieDaemonKitTests/ConversationCaptureTests.swift` (router level, fake clock)

- [ ] **Step 1: Tests** `idleTenMinutesTriggers`, `newTurnResetsIdle`, `precompactTriggersForced`, `sessionEndTriggersForced`, `workDoneTriggersForced`, `memoryCaptureCommandForced`, `codexTerminalNeverTriggers`, `badTranscriptPathIgnored` (Review Focus 1), `quickTurnNoModelCall` (Review Focus 5).
- [ ] **Step 2:** Run → FAIL; implement; → PASS.
- [ ] **Step 3: Manual:** restart daemon + a Claude terminal; talk 3+ messages deciding something ("vamos usar X porque Y"); wait 10 min (or `collie memory capture`) → the decision appears active in the Memória panel with origin "conversa (…)"; a new terminal on the same project gets it injected. Repeat with `/compact`: no duplicate.
- [ ] **Step 4:** README memory section: one paragraph (what is read, when, where it goes, the cap). Commit `feat(memory): capture conversations at idle, compaction, session end and work done`.
