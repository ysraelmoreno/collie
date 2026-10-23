# Plan 2M — Shared Workspace Memory: Lots, Board, Auto-Capture, Post-Compact Recall

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents of one effort (designer, developers, testers) share memory and a board quickly, efforts running side by side in the same workspace don't leak into each other, learnings are captured at session/work end without relying on the agent remembering, and a compacted session gets its work state back.

**Architecture:**
- New workspace entity **Lot** (`lote`, a group of terminals on one effort; herding vocabulary): `id`, `name`, `goal`, optional `paddockId`, members (terminal ids, each terminal in at most one lot). Lots scope memory; **leashes stay the only permission** — a lot never grants reach to terminals or panels.
- Memory gains scope `.lot` (`lotId`). Project memories stay in the repo store (`.collie/memory`, versionable, shared knowledge); lot memories live in the workspace store next to the work registry (`<root>/…/lots/<lot-id>/memory`, same `MemoryStore` + index), since a lot is a workspace thing and may span repos.
- Injection policy: own lot + project; other lots never auto-injected, reachable by explicit search (`--lot <name>` / `--all`), labeled.
- **Board** per lot: goal, members, handoffs, questions, status lines; new posts addressed to a terminal are injected on its next prompt (the `UserPromptSubmit` path `memory.hookRelevant` already runs).
- **Auto-capture** at the ends that exist today: Claude `Stop` hook (can ask the agent to continue once), `work done`, `PreCompact`/`SessionEnd` (deterministic candidates from the work registry). Captured items enter as `proposed` (not injected) until approved in "Revisar", except what the agent itself saves.
- **Post-compact recall**: `SessionStart` with source `compact` re-injects work status + lot board digest along with memory.

**Tech Stack:** Swift 6.2, existing MemoryStore/MemoryIndex (SQLite FTS5), WorkStore, hooks (Claude/Codex), SwiftUI.

**Spec:** user 2026-10-23: "Pode fazer de A a D" (A auto-capture, B scalable injection, C shared board, D post-compact recall); "a memória pertence ao workspace… designer, testers, developers precisam conseguir recuperar o trabalho compartilhado"; question about work A (context X, 5 terminals) and work B (context Y, 2 terminals) in one workspace sharing memory → isolation by lot.

## Global Constraints

- Leashes remain the only permission. Lot membership affects only which memory/board is injected and the default search scope.
- Memory is never secret-bearing: no tokens, design edit links, or env values in captured text (strip `COLLIE_TOKEN`-like values, URLs with `edit`/`token` query keys).
- Nothing is deleted automatically: proposals expire to `discarded` (restorable) after 14 days unreviewed; purge stays explicit.
- No network. Local model (FoundationModels) only where available; everything works without it (deterministic text).
- Session-start injection ≤ 4096 bytes, per-prompt injection ≤ 2048 bytes (as today); board digest shares those budgets.
- Existing memories (no `lotId`) are project scope; old files decode unchanged.
- Codex/Cursor get the same injection; only Claude gets the Stop-hook ask (others: deterministic capture only).
- UI copy pt-BR ("Lote", "Quadro", "Propostas"); CLI/code English (`lot`, `board`).

## Review Focus

1. Lot A and lot B in the same pasture (no paddock): a B agent's session start and prompts never show A's lot memories or board; `collie memory search` without flags returns B + project only.
2. Agent saves "use Tailwind" in lot A; a later project decision with the same subject saved from lot B must not supersede A's lot memory (supersession keys are per scope+lot).
3. Stop-hook ask fires at most once per work chunk (new commits/done tasks since the last capture), never in a loop, never for a session that saved a memory itself.
4. Compaction mid-task: after compact, the agent's first prompt context contains its active work's open tasks and the lot's latest handoff to it.
5. Terminal moved from lot A to lot B mid-session: next prompt injects from B; already-injected ids reset.

---

### Task 1: Lots

**Files:** Create `Sources/CollieCore/Lot.swift`; modify `Sources/CollieCore/Workspace.swift` (`lots: [Lot]`, decode default `[]`), `Sources/CollieProtocol/Commands.swift`, create `Sources/CollieDaemonKit/LotCommands.swift`, modify `Herds/HerdApplier.swift` (applying a herd creates a lot with its members), `ShepherdCommands.swift` (`summon` puts the new terminal in the Shepherd's lot). Test: `Tests/CollieDaemonKitTests/LotCommandsTests.swift`, `Tests/CollieCoreTests/WorkspaceTests.swift`.

**Interfaces:** `public struct Lot: Codable, Sendable, Equatable, Identifiable { id: UUID; name: String; goal: String; paddockId: UUID?; members: [UUID]; createdAt: Date }`. `Workspace.lot(of terminal: UUID) -> Lot?`. Commands `lot.create --name N [--goal G] [--paddock P] [--members a,b]`, `lot.join|leave --terminal T --lot L`, `lot.list`, `lot.get [--lot L]` (default: caller's). Create/join/leave: admin or a Shepherd for terminals it reaches; a terminal may `leave` itself. Removing a terminal removes it from its lot; an empty lot stays (memories remain) until the user deletes it in the app.

- [ ] **Step 1: Tests** `decodesWithoutLots`, `createAndJoin`, `terminalInOneLotOnly` (join B moves it out of A), `shepherdJoinsReachedOnly`, `herdApplyCreatesLot`, `summonInheritsLot`, `lotGrantsNoReach` (a member of the Shepherd's lot that isn't leashed is still not `collie ask`-able).
- [ ] **Step 2:** Implement + emit workspace change. App: lot chip on the node title bar, "Lote" picker in the new-terminal sheet and node menu, a lot list in the sidebar (name, goal, members; delete only empty-of-terminals lots, with confirmation).
- [ ] **Step 3:** `swift test` → PASS. Commit `feat(lots): group terminals by effort`.

### Task 2: Lot-scoped memory + injection policy (B)

**Files:** Modify `Sources/CollieCore/Memory.swift` (`MemoryScope.lot`, `lotId: UUID?`, `MemoryStatus.proposed`), `Memory/MemoryService.swift` (lot stores, `readable`, `context`, `relevant`), `MemoryCommands.swift` (save default scope, search flags, review approve/discard proposals), `Memory/MemoryCleanup.swift` (proposal expiry). Test: `Tests/CollieDaemonKitTests/MemoryLotTests.swift`.

**Interfaces:** `memory.save [--scope lot|project|paddock|global]` (default: `lot` when the caller is in a lot, else `project`); `memory.search Q [--lot L | --all]` (default: caller's lot + project + global; results carry `lot` name); `memory.promote --id I` (lot → project, keeps a `supersedes` link). Supersession key = (scope, lotId, subject).

- Session start (`memory.hookContext`): pinned project + pinned lot memories in full; then a one-line-per-memory **index** of the rest of the lot's (titles only, newest first) until 4096 bytes; project non-pinned only via per-prompt relevance.
- Per prompt (`memory.hookRelevant`): BM25 over lot + project + global, lot hits boosted ×1.5; `proposed` never injected.

- [ ] **Step 1: Tests** `saveDefaultsToCallersLot`, `otherLotNeverInjected` (Review Focus 1), `searchDefaultScope`, `searchAllLabelsLot`, `supersedeIsPerLot` (Review Focus 2), `promoteMovesToProject`, `proposedNotInjected`, `contextPinnedThenIndex`, `contextFits4096With500Memories`, `lotChangeResetsInjected` (Review Focus 5), `proposalExpiresTo14Days`.
- [ ] **Step 2:** Implement. Lot store path beside the work registry's dir, 0700/0600 like it.
- [ ] **Step 3:** Tests PASS. Commit `feat(memory): lot scope, proposals, index-first injection`.

### Task 3: Lot board (C)

**Files:** Create `Sources/CollieDaemonKit/Lots/LotBoard.swift` (append-only JSONL per lot, newest 500 kept, older archived like `ChatLog`), modify `LotCommands.swift`, `MemoryCommands.swift` (`hookRelevant` prepends unseen posts addressed to the caller), CLI/MCP specs, app "Quadro" tab in the lot view. Test: `Tests/CollieDaemonKitTests/LotBoardTests.swift`.

**Interfaces:** `lot.post --kind handoff|question|status|answer --text T [--to terminal] [--ref memory-id|artifact-id|work-id]` (members of the lot, its Shepherds, admin); `lot.board [--lot L] [--since id] [--kind K]` → posts newest first. Handoff = "what I did, where it is, what you need next": the designer → interface → tester chain posts handoffs instead of pasting context into `ask`.

- [ ] **Step 1: Tests** `postAndReadBoard`, `nonMemberCannotPost` (another lot's member → `notFound`, no leak), `handoffInjectedOnceToRecipient`, `statusNotInjected` (status posts only shown on `lot.board`), `boardCapArchives`, `injectionWithinBudget` (posts + memories ≤ 2048 bytes; posts first, newest first).
- [ ] **Step 2:** Implement. Orientation line for lot members: `- Lot "<name>" (<goal>): collie lot board / collie lot post --kind handoff --to <name> "<what, where, next>"; save lot decisions with collie memory save.` (fits the 1300 limit test).
- [ ] **Step 3:** Tests PASS. Commit `feat(lots): shared board with handoffs`.

### Task 4: Auto-capture (A)

**Files:** Modify `Sources/collie/HookCommands.swift` (`claude-stop` may answer `{"decision":"block","reason":…}`), `Sources/CollieDaemonKit/Work/WorkHookParser.swift` / `WorkCommands.swift` (capture triggers), create `Sources/CollieDaemonKit/Memory/MemoryCapture.swift`. Test: `Tests/CollieDaemonKitTests/MemoryCaptureTests.swift`.

**Interfaces:** `MemoryCapture.candidates(work: Work, since: Date) -> [MemoryRecord]` (deterministic: `Done:` notes, deferred/dropped task reasons → pitfall/decision proposals with `origin: "captura (<terminal>)"`, status `proposed`, scope = the terminal's lot or project; commit subjects only as body context, never as their own memory). `memory.captureState(terminal)`: last capture time, whether the session saved anything.

- [ ] **Step 1: Tests** `candidatesFromDoneNotes`, `noCandidatesWithoutNewWork`, `stopAsksOncePerChunk` (Review Focus 3: second Stop with no new work → no block), `stopSkipsWhenAgentSaved`, `stopAskTextNamesCommands` (reason: "Antes de encerrar: registre decisões e armadilhas deste trabalho com collie memory save --scope lot (ou responda 'nada a registrar')."), `workDoneCreatesProposals`, `precompactCreatesProposals`, `capturedTextScrubbed` (token/edit-link stripped), `localModelOptional` (unavailable → deterministic text).
- [ ] **Step 2:** Implement. Claude: Stop → block once per chunk. Codex/Cursor: proposals only (work done / session end). With FoundationModels available, rewrite each proposal's title/body (same sanitizing as `WorkAssistant`).
- [ ] **Step 3:** App "Revisar" shows proposals with Aprovar (→ active) / Editar / Descartar, grouped by lot; approve-all per lot.
- [ ] **Step 4:** Tests PASS. Commit `feat(memory): capture proposals at work and session end`.

### Task 5: Post-compact recall (D)

**Files:** Modify `Sources/collie/HookCommands.swift` (pass `SessionStart` `source`), `MemoryCommands.swift` (`memory.hookContext` with `source: compact`), `Work/WorkStatusText.swift`. Test: `Tests/CollieDaemonKitTests/MemoryContextTests.swift`.

**Interfaces:** `memory.hookContext --source startup|resume|compact|clear`. On `compact` (and `resume`): orientation + memory context + `WorkStatusText` of the caller's active work (open tasks, last 3 notes) + the lot board's latest handoff to the caller and last 3 status posts, within 4096 bytes (work status first, then board, then memory index).

- [ ] **Step 1: Tests** `compactInjectsWorkStatus` (Review Focus 4), `compactInjectsLatestHandoff`, `startupUnchanged`, `compactFitsBudget`.
- [ ] **Step 2:** Implement; Codex has no compact source — nothing changes there.
- [ ] **Step 3:** Tests PASS. README: one section "Memória e lotes" (scopes, board, proposals, what is injected when). Commit `feat(memory): restore work state after compaction`.
