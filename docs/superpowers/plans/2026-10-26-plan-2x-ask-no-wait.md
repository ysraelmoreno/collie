# Plan 2X — `ask --no-wait`: the Shepherd Keeps Working, the Reply Comes Back as a Message

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent can ask another agent without blocking: `collie ask <name> "<prompt>" --no-wait` returns at once with an ask id; when the target's turn ends, the reply is typed into the asker's terminal as a new message (and kept for `collie ask result <id>`).

**Architecture:** Today `ask` (`Commands.swift:45`, `CommandRouter.swift:308`) holds the call until the target's turn ends (default 1800 s), so a Claude Shepherd sits on "Calling collie…" and can't answer the user meanwhile (user screenshot 2026-10-26). With `--no-wait` the router validates as today, starts the same `AskCoordinator.ask` in a detached task, and returns `{askId, target}`. On completion the result goes into a small in-memory `AskInbox` and is delivered with the existing `AskCoordinator.inject` (same FIFO, readiness and approval guards), typed only when the asker is quiet. Blocking `ask` is unchanged.

**Tech Stack:** Swift 6.2, existing `AskCoordinator`.

**Spec:** user request 2026-10-26 ("o ideal seria escutar justamente esse processo de id … evitar espera").

## Global Constraints

- Leash rules unchanged: same `ConnectionGraph.resolve`, running check and deadlock check as blocking `ask` at send time.
- A no-wait ask is not a wait edge: the asker isn't blocked, so `reaches` ignores it (the target may ask the asker back, blocking, without a deadlock error).
- Delivery is typed only into `claude` and `codex` terminals. `shell`/`custom` askers never get text typed (a shell would run it); they read with `collie ask result`.
- Delivery waits until the asker is quiet (same rule as the user's work-chat ask, `afterQuiet`) and never types into a pending approval prompt (`guardsApproval`, as `inject` already does).
- Delivered text ≤ 3000 chars of the reply; longer → cut with a final line pointing to `collie ask result <id>`. Full output kept in the inbox.
- Inbox: memory only, 20 newest per asker, readable only by the asker (another terminal → `notFound`). Daemon restart loses pending no-wait asks and the inbox (ponytail: add persistence if users hit it).
- Agent-facing text in English (as orientation); no secrets in the delivered text beyond what blocking `ask` already returns.

## Review Focus

1. Shepherd sends 3 no-wait asks to 3 agents, then keeps chatting with the user: no "Calling collie…" longer than the send; each reply arrives as its own message after the Shepherd's current turn ends, never typed mid-turn.
2. Target busy with a queued blocking ask from someone else: the no-wait ask queues behind it (same FIFO); the reply still arrives.
3. Target times out / exits / is removed: the asker gets one failure message `[collie] Ask <id> to <name> failed: <message>`; `ask result <id>` shows the error.
4. Asker closed before the reply: nothing typed anywhere, no crash; result dropped with the asker.
5. Asker is waiting on its own blocking ask when a no-wait reply is due: delivery waits in the asker's queue; no deadlock error, no interleaving.

---

### Task 1: No-wait ask, inbox, delivery

**Files:**
- Create: `Sources/CollieDaemonKit/AskInbox.swift`
- Modify: `Sources/CollieDaemonKit/AskCoordinator.swift` (`Waiter.detached`; `reaches` skips detached waiters; `ask(…, detached: Bool = false)`; `inject(…, afterQuiet: Bool = false)` passing it to the waiter)
- Modify: `Sources/CollieDaemonKit/CommandRouter.swift:308` (`ask` with `noWait`; new `ask.result`)
- Modify: `Sources/CollieProtocol/Commands.swift:45` (`ParamSpec("no-wait", .flag, help: "Return at once with an ask id; the reply is typed into your terminal when you are idle")`; summary "Send a prompt to an agent; wait for its reply, or --no-wait"; new `CommandSpec(name: "ask.result", params: [ParamSpec("id", .string, positional: true, help: "Ask id (omit to list your recent asks)")], timeoutSeconds: 10)`)
- Test: `Tests/CollieDaemonKitTests/AskTests.swift`, `Tests/CollieDaemonKitTests/RouterTests.swift`

**Interfaces:**
- Produces: `actor AskInbox` with `func open(id: String, from: UUID, target: String)`, `func close(id: String, _ r: Result<AskResult, ProtocolError>)`, `func get(id: String, from: UUID) -> Entry?`, `func recent(from: UUID) -> [Entry]`, `func drop(terminal: UUID)`; `struct Entry { id, target, status: pending|done|failed, output: String?, error: String? }`; `static func message(_ e: Entry) -> String` (the delivered text).
- Ask id: 8 lowercase hex chars (first 8 of a UUID), unique per inbox.
- Delivered text: `[collie] Reply from <name> (ask <id>):\n<output>`; failure `[collie] Ask <id> to <name> failed: <message>`; cut suffix `\n[cut — full reply: collie ask result <id>]`.

- [ ] **Step 1: Tests** (`AskTests`, fake terminals as the existing ask tests)
  - `noWaitReturnsImmediately`: router `ask --no-wait` on a target mid-turn → reply within 100 ms with `askId`, `target`.
  - `noWaitDeliversReplyToAsker`: target's `turn.completed("done")` → the asker's PTY receives `[collie] Reply from B (ask <id>):\ndone` once, after the asker is quiet.
  - `noWaitNotTypedMidTurn`: asker printing continuously → nothing typed until quiet.
  - `noWaitNotDeadlockEdge`: A no-wait asks B; B blocking-asks A → accepted (no `.deadlock`).
  - `noWaitFailureDelivered`: target timeout (`--timeout 1`) → asker gets the failure line; `ask.result` shows `failed`.
  - `noWaitShellAskerNotTyped`: asker preset `shell` → nothing written to its PTY; `ask.result <id>` → `done` with output.
  - `longReplyCut`: 5000-char reply → typed text ≤ 3000 chars of output + cut line; `ask.result` returns all 5000.
  - `resultOnlyForAsker`: another terminal `ask.result <id>` → `notFound`.
  - `inboxKeepsTwenty`; `askerRemovedDropsInbox` (Review Focus 4: no write, no crash).
  - `blockingAskUnchanged`: existing ask tests pass untouched.
- [ ] **Step 2:** `swift test --filter AskTests` → new ones FAIL.
- [ ] **Step 3:** Implement. Router: after the same checks, `let id = await inbox.open(…)`; `Task { let r = await Result { try await asks.ask(from:to:…, detached: true) }; await inbox.close(id, r); if preset is claude|codex { try? await asks.inject(to: tid, prompt: AskInbox.message(entry), afterQuiet: true) } }`. Hook `inbox.drop` where the terminal is removed (next to `asks.detach`).
- [ ] **Step 4:** `swift test --filter AskTests` and `--filter RouterTests` → PASS.
- [ ] **Step 5: Commit** `feat(ask): --no-wait returns an ask id; reply typed back when idle`.

### Task 2: Agents use it

**Files:**
- Modify: `Sources/CollieDaemonKit/CollieOrientation.swift:44` (Shepherd/leash line: `collie ask <name> "<prompt>" --no-wait (reply comes back as a message; collie ask result <id>)`; keep blocking `ask` mentioned as "wait for the reply")
- Test: `Tests/CollieDaemonKitTests/CollieOrientationTests.swift` (worst case still ≤ 1300)

- [ ] **Step 1:** Test `shepherdHintMentionsNoWait`; existing length test PASS.
- [ ] **Step 2:** Implement; `swift test --filter CollieOrientationTests` → PASS.
- [ ] **Step 3: Manual (Review Focus 1):** restart daemon + Shepherd; ask the Shepherd to delegate to two agents with `--no-wait` and then chat with it: no long "Calling collie…"; replies arrive as messages after its turn. MCP tool `ask` shows the `no-wait` param after `tools/list_changed`.
- [ ] **Step 4: Commit** `feat(orientation): Shepherds delegate with ask --no-wait`.
