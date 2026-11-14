# Memory lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Project memories earn trust by use, agents flag wrong or stale ones, deterministic checks and the curator re-check contested ones, and lifetime and long-term promotion follow usage, with no human review in the loop.

**Architecture:** A daemon-side `LifecycleStore` (outside the repo, like `ScoreStore`) holds tier, useful uses, flags and per-session injected ids. Pure rule functions turn that state into tiers and archive plans. `memory.flag` is the agent's judgement channel; two new curator job kinds re-check contested memories and gate promotion; injection shows ids and tags; the consolidation pass applies it all.

**Tech Stack:** Swift (CollieCore, CollieProtocol, CollieDaemonKit), SwiftPM tests, on-device curator (existing `Curator`).

**Spec:** `docs/superpowers/specs/2026-11-13-memory-lifecycle-design.md` (read it first; this plan only decides what the spec leaves to the task split).

## Global Constraints

- Scope: `scope == .project`, `status == .active`, not `pinned`, not `reviewed`. Global, lot, paddock, pinned and reviewed memories are never tiered and never auto-archived by this feature.
- Lifecycle state lives in `<root>/learning/lifecycle.json` (0600, atomic write, fsync, like `ScoreStore`), never in `.md` frontmatter. A forged frontmatter changes nothing.
- Numbers (constants in one `LifecycleRules` enum): provisional TTL 21 days from `max(tierSince, last useful use)`; earned = ≥ 2 useful uses on ≥ 2 distinct days and ≥ 2 distinct sessions, never contested; longTerm = earned + ≥ 8 useful uses over ≥ 4 distinct days spanning ≥ 14 days, not contested in 30 days, plus a `verifyPromotion` verdict `valid`; ≤ 12 longTerm per project; ≤ 3 longTerm injected in full at session start, ≤ 600 B; flag penalty `-0.3`; ≤ 20 flags per session; cooldown 14 days after a `valid` verdict; ≤ 3 promotion gates a day.
- "Session" = the memory event log session id (`sessions[terminal]` in `MemoryService`). A use whose next prompt never arrives is dropped, not counted.
- Flags never archive without a curator `invalid` verdict, except when no curator is available and a deterministic claim check also failed. After 14 days still contested: digest "Precisa de você".
- Tags in injected text: `(provisória)` on provisional only, `(contestada)` on contested; the old `(não revisada, <origem>)` is removed. Short id = first 8 hex of the UUID, on full-body lines only (prompt, pushed rules, checklist, pinned, longTerm), never on title-only index lines.
- Injected memory text and flag reasons are data: reasons go through `LotBoards.scrub`, cap 200 characters, and reach the curator only inside the existing nonce-delimited input.
- Tests: only changed or created tests via `--filter`, never the full suite. `.build/Collie-Main` does not compile: commit, then verify in a detached worktree (`git worktree add --detach <tmp> HEAD`, `swift test --scratch-path <tmp>/.build --filter <Suite>`, `git worktree remove <tmp>`). Do not install or restart the app.
- Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. No push. Add only your own hunks.

## Review Focus

- A `.md` whose frontmatter claims a tier or `pinned`/`reviewed` it does not have: nothing changes (Task 1 test).
- Daemon restart between injection and `--wrong`: the flag is still accepted (Task 1 persists `injectedBySession`; Task 5 test).
- A pinned or user-reviewed memory flagged twice: never archived, goes to "Precisa de você" (Task 7 test).
- Migration of the existing 188 memories archives nothing on its first run (Task 7 test).
- No model available, or daily cap reached: contested memories stay tagged, nothing is silenced (Task 6 test).
- Ambiguous or too-short id prefix, an id not injected to the caller, the 21st flag in a session: refused with `invalidArgs` (Task 5 tests).

---

### Task 1: LifecycleStore

**Files:**
- Create: `Sources/CollieDaemonKit/Memory/LifecycleStore.swift`
- Test: `Tests/CollieDaemonKitTests/LifecycleStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum LifecycleTier: String, Codable, Sendable { case provisional, earned, longTerm }`
  - `enum FlagVerdict: String, Codable, Sendable { case useful, wrong, outdated }`
  - `struct LifecycleFlag: Codable, Sendable, Equatable { var verdict: FlagVerdict; var session: String; var day: String; var reason: String }`
  - `struct UseKey: Codable, Sendable, Hashable { var day: String; var session: String }` (`day` = `yyyy-MM-dd`, UTC)
  - `struct LifecycleEntry: Codable, Sendable, Equatable { var tier: LifecycleTier = .provisional; var usefulUses: Set<UseKey> = []; var flags: [LifecycleFlag] = []; var contestedNow = false; var lastContestedAt: Date?; var recheckedAt: Date?; var tierSince: Date }`
  - `actor LifecycleStore` with `init(file: URL)`, `func entry(_ id: UUID) -> LifecycleEntry?`, `func all() -> [UUID: LifecycleEntry]`, `func update(_ id: UUID, now: Date, _ change: (inout LifecycleEntry) -> Void)` (creates a provisional entry with `tierSince = now` when absent), `func noteInjected(session: String, ids: [UUID], now: Date)`, `func injected(session: String) -> Set<UUID>`, `func setPending(session: String, ids: [UUID])`, `func takePending(session: String) -> [UUID]`, `func prune(knownIds: Set<UUID>, now: Date)`.

- [ ] **Step 1: Write the failing tests** in `LifecycleStoreTests`: `roundTripsFileWith0600`, `unreadableFileStartsEmptyNeverCrashes`, `updateCreatesProvisionalWithTierSinceNow`, `injectedSurvivesReopeningTheFile` (write, new `LifecycleStore(file:)`, `injected(session:)` still has the ids), `injectedDroppedSevenDaysAfterLastEvent`, `takePendingClearsIt`, `pruneDropsIdsMissingFor30DaysKeepsRecent` (an id unknown at day 0 survives, unknown for 31 days is dropped).
- [ ] **Step 2: Run** `swift test --filter LifecycleStoreTests` in the detached worktree. Expected: FAIL, type not defined.
- [ ] **Step 3: Implement** `LifecycleStore.swift`. Follow `ScoreStore` for load/mutate/atomic 0600 write; `missingSince` per id is kept in the same file for `prune`.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): lifecycle store outside the repo`.

### Task 2: LifecycleRules (pure)

**Files:**
- Create: `Sources/CollieDaemonKit/Memory/LifecycleRules.swift`
- Modify: `Sources/CollieDaemonKit/Memory/MemoryCleanup.swift` (add `case archiveUnused` to `CleanupItem.Action`; `apply` archives it like `archiveCold`)
- Test: `Tests/CollieDaemonKitTests/LifecycleRulesTests.swift`

**Interfaces:**
- Consumes: `LifecycleEntry`, `LifecycleTier` (Task 1), `MemoryRecord` (CollieCore).
- Produces:
  - `enum LifecycleRules` with the constants of Global Constraints as `static let`.
  - `static func eligible(_ r: MemoryRecord) -> Bool` (project, active, not pinned, not reviewed).
  - `static func tier(for e: LifecycleEntry, now: Date) -> LifecycleTier` (never returns `longTerm` by itself: it returns `.earned` for a longTerm candidate; promotion needs the curator gate. A stored `.longTerm` that is `contestedNow` returns `.earned`).
  - `static func promotionCandidate(_ e: LifecycleEntry, now: Date) -> Bool`.
  - `static func unusedPlan(records: [MemoryRecord], entries: [UUID: LifecycleEntry], now: Date) -> [CleanupItem]` (provisional past TTL → `archiveUnused`, reason in Portuguese like the existing ones, e.g. `"provisória sem uso há 21 dias"`).

- [ ] **Step 1: Write the failing tests**: `earnedNeedsTwoDaysAndTwoSessions` (2 uses same day → still provisional; 2 days but same session → provisional), `contestedNeverEarns`, `promotionNeedsEightUsesFourDaysFourteenDaySpan`, `contestedInLast30DaysBlocksPromotion`, `ttlCountsFromLastUsefulUseNotCreation`, `ineligibleRecordsNeverInPlan` (pinned, reviewed, lot, global, paddock), `plannedItemApplyArchivesAndStaysReversible` (apply then `memory.restore` path from `MemoryCleanupTests` pattern).
- [ ] **Step 2: Run** `--filter LifecycleRulesTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the enum as pure functions; extend `MemoryCleanup.Action` and `apply`.
- [ ] **Step 4: Run** `--filter LifecycleRulesTests` and `--filter MemoryCleanupTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): tier and lifetime rules`.

### Task 3: Claim checks

**Files:**
- Create: `Sources/CollieDaemonKit/Memory/ClaimChecks.swift`
- Test: `Tests/CollieDaemonKitTests/ClaimChecksTests.swift`

**Interfaces:**
- Produces:
  - `protocol GitFacts: Sendable { func branch(_ name: String) async -> BranchState; func commitExists(_ sha: String) async -> Bool; func pathExists(_ rel: String) -> Bool }` with `enum BranchState { case open, merged, missing }`.
  - `struct GitFactsLive: GitFacts` over the repo root, reusing the daemon's existing git runner (`GitRunner`, see floor manager); bounded timeout.
  - `struct ClaimFailure: Equatable, Sendable { var kind: Kind; var detail: String }` (`Kind`: `pathMissing`, `branchMerged`, `branchMissing`, `commitMissing`).
  - `enum ClaimChecks { static func check(_ r: MemoryRecord, facts: any GitFacts) async -> [ClaimFailure] }`.

- [ ] **Step 1: Write the failing tests** with a fake `GitFacts` and one live test on a temp git repo (`GitFactsLive`): `mergedBranchWithNegatedBodyFails` (body "não foi mergeado … fix/x", branch `fix/x` merged → `branchMerged`), `mergedBranchWithoutNegationPasses`, `negationWordsPtAndEn` ("não mergead", "não foi mergead", "pendente", "ainda não", "not merged", "pending"), `unknownShaFails` (≥ 7 hex that is not a commit), `shortHexWordNotASha` (e.g. "deadbeef" inside prose that is not in the repo only counts when 7–40 hex and looks like a SHA; a 6-char hex never counts), `missingPathFails`, `noClaimsNoFailures`.
- [ ] **Step 2: Run** `--filter ClaimChecksTests`. Expected: FAIL.
- [ ] **Step 3: Implement** extraction by regex (branch `\b(feat|fix|spike|docs|chore)/[A-Za-z0-9._/-]+`, SHA `\b[0-9a-f]{7,40}\b`) and the negation list from the spec.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): deterministic claim checks against git and disk`.

### Task 4: Injection shows ids and tags, tracks pending uses

**Files:**
- Modify: `Sources/CollieDaemonKit/Memory/MemoryService.swift` (`mark`, `relevantLine`, `renderContext`, `checklistParts`, `hits(for:…)`, `relevant(for:…)`, `context(for:…)`, `relevantHeader`/header text; new `lifecycle: LifecycleStore` property next to `scores`)
- Modify: `Sources/CollieDaemonKit/MemoryHookClient.swift` only if the hook path needs the prompt for resolution (it already sends `prompt`).
- Test: `Tests/CollieDaemonKitTests/LifecycleInjectionTests.swift` (new), keep `MemoryContextTests` and `MemoryHookTests` passing.

**Interfaces:**
- Consumes: `LifecycleStore`, `LifecycleRules`, `CorrectionDetector.isCorrection(_:lastTurn:)`.
- Produces: injected full-body lines of the form `- [<id8>] <title>… (provisória)` (tag only when tier is provisional; `(contestada)` when `contestedNow`); `MemoryService.resolvePending(session: String, prompt: String, lastTurn: String?, now: Date) async` called at the start of `relevant(for:…)` before searching: for each id from `takePending`, if the prompt is not a correction, add `UseKey(day, session)` to its entry; if it is a correction, drop them. After a prompt-relevance injection: `lifecycle.setPending(session:ids:)` and `lifecycle.noteInjected(session:ids:now:)` (all full-body injections call `noteInjected`).

- [ ] **Step 1: Write the failing tests** in `LifecycleInjectionTests`: `promptLineHasShortIdAndProvisionalTag`, `earnedLineHasNoTag`, `contestedLineTagged`, `indexLinesHaveNoId`, `headerExplainsFlagCommand`, `nextPromptWithoutCorrectionCountsOneUsePerDaySession`, `nextPromptWithCorrectionDropsUse`, `noNextPromptDropsUse` (end the session, nothing counted), `reviewedAndPinnedHaveNoTagsAndNoEntries`. Update the existing tests that asserted `(não revisada, …)` to the new tags.
- [ ] **Step 2: Run** `--filter LifecycleInjectionTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the changes listed. `mark(_:)` becomes tier-aware: it needs the entry, so callers pass a precomputed `[UUID: LifecycleEntry]` snapshot taken once per injection.
- [ ] **Step 4: Run** `--filter LifecycleInjectionTests`, `--filter MemoryContextTests`, `--filter MemoryHookTests`, `--filter MemoryRetractionTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): ids and tier tags in injected memories, pending uses`.

### Task 5: `memory.flag`

**Files:**
- Modify: `Sources/CollieProtocol/Commands.swift` (new `CommandSpec(name: "memory.flag", …)` near `memory.pin`; terminal token allowed, not admin-only), `Sources/CollieDaemonKit/MemoryCommands.swift` (handler beside `memory.pin`), `Sources/CollieDaemonKit/Memory/MemoryCapture.swift` (`stopReason`, `stopReasonNoLot`)
- Test: `Tests/CollieDaemonKitTests/MemoryFlagTests.swift`; update `MemoryCaptureTests` for the new Stop text.

**Interfaces:**
- Consumes: `LifecycleStore.injected(session:)`, `ScoreStore.penalize(_:_: reason:)`, `LotBoards.scrub`.
- Produces: command `memory.flag` with args `id: string` (full UUID or unambiguous prefix of ≥ 4 hex among the caller's injected ids), `verdict: "useful"|"wrong"|"outdated"`, `reason: string?`. CLI `collie memory flag <id> --useful|--wrong|--outdated ["motivo"]`; MCP `memory_flag` (both come from the command table). Result `{id, contested: Bool, queued: Bool}`. Stop reason gains: " e marque as memórias injetadas que estavam erradas ou velhas (collie memory flag)".
- Effects: `useful` → add `UseKey` immediately. `wrong`/`outdated` → append `LifecycleFlag` (scrubbed reason ≤ 200), `penalize(id, -0.3)`, `contestedNow = true`, `lastContestedAt = now`, enqueue a `verifyContested` job (Task 6; until then a stub `enqueueVerify` that Task 6 fills). Pinned or reviewed target: record the flag, do not penalize, and mark for the digest "Precisa de você".

- [ ] **Step 1: Write the failing tests**: `flagWrongContestsPenalizesAndQueues`, `flagUsefulCountsImmediately`, `notInjectedIdIsInvalidArgs`, `ambiguousPrefixIsInvalidArgsAskingForMore`, `twentyFirstFlagInASessionRefused`, `flagStillAcceptedAfterDaemonRestart` (reopen `LifecycleStore` from the same file), `reasonScrubbedAndCapped` (token-like text and 500 chars), `pinnedTargetNotPenalized`, `adminAndTerminalTokensAllowed`, `stopReasonMentionsFlag`.
- [ ] **Step 2: Run** `--filter MemoryFlagTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the spec entry and handler; update `MemoryCapture.stopReason`/`stopReasonNoLot` and the affected capture tests.
- [ ] **Step 4: Run** `--filter MemoryFlagTests`, `--filter MemoryCaptureTests`, `--filter MemoryCommandTests`, `--filter CollieProtocolTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): memory.flag, the agent's judgement of injected memories`.

### Task 6: Curator verify jobs

**Files:**
- Modify: `Sources/CollieDaemonKit/Curator/Curator.swift` (`CuratorJobKind` gets `verifyContested` and `verifyPromotion` inserted right after `correction`, so `priority` gives corrections, then contested re-checks, then promotion, then the rest; `Curator.limit` unchanged), `Sources/CollieDaemonKit/Curator/CuratorRunner.swift` (run the new kinds), `Sources/CollieDaemonKit/Curator/CuratorOps.swift` (reuse `retire`/`score`; add nothing unless needed)
- Create: `Sources/CollieDaemonKit/Memory/MemoryVerify.swift`
- Test: `Tests/CollieDaemonKitTests/VerifyJobTests.swift`

**Interfaces:**
- Consumes: `ClaimChecks` (Task 3), `LifecycleStore` (Task 1), `CuratorRunner` call seam used by `CuratorRunnerTests`.
- Produces: `MemoryVerify.payload(memory:flags:facts:) -> JSONValue`, `MemoryVerify.input(_:nonce:) -> String` (same nonce-delimited style as `Consolidation.input`), and `func applyVerdict(_ id: UUID, kind: CuratorJobKind, ops: [CuratorOp]) async` on `MemoryService`:
  - `verifyContested`: no `retire` op = `valid` → clear flags, `contestedNow = false`, `recheckedAt = now` (14-day cooldown: a new flag inside it queues no job and only tags); `retire` = `invalid` → archive, reversible.
  - `verifyPromotion`: no `retire` op = `valid` → `tier = .longTerm` if the project has < 12 and the entry is still a candidate; `retire` → stay earned and set `recheckedAt` (retry no sooner than 14 days).
  - Dedupe key per memory id and kind; promotion jobs capped at 3 per day.
  - No model or cap reached: job stays queued; with no model and a failed claim check, archive per Global Constraints; otherwise nothing changes.

- [ ] **Step 1: Write the failing tests** with a fake curator call: `validVerdictClearsFlagsAndStartsCooldown`, `invalidVerdictArchivesReversibly`, `promotionValidSetsLongTerm`, `promotionRespectsTwelveCap`, `promotionJobsCappedThreePerDay`, `noModelLeavesContestedTaggedNothingSilenced`, `noModelWithFailedClaimCheckArchives`, `capReachedKeepsJobQueued`, `priorityOrderCorrectionThenContestedThenPromotion`, `flagInsideCooldownQueuesNothing`.
- [ ] **Step 2: Run** `--filter VerifyJobTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the job kinds, payload, runner branch and verdict application. Replace the Task 5 `enqueueVerify` stub.
- [ ] **Step 4: Run** `--filter VerifyJobTests`, `--filter CuratorRunnerTests`, `--filter CuratorQueueTests`, `--filter CuratorOpsTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(curator): verify jobs for contested memories and promotion`.

### Task 7: Lifecycle pass, proposals, long-term injection, migration

**Files:**
- Modify: `Sources/CollieDaemonKit/Memory/Consolidation.swift` (`consolidate(_ store:now:)` runs the lifecycle pass), `Sources/CollieDaemonKit/Memory/MemoryService.swift` (session-start context takes up to 3 longTerm in full, ≤ 600 B, before the checklist), `Sources/CollieDaemonKit/Memory/MemoryCleanup.swift` (earned/longTerm exemptions: longTerm skips `archiveCold`)
- Create: `Sources/CollieDaemonKit/Memory/LifecyclePass.swift`
- Test: `Tests/CollieDaemonKitTests/LifecyclePassTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces: `func lifecyclePass(_ store: RepoMemory, now: Date) async` that: (1) migrates: a record with no entry gets a provisional entry with `tierSince = now` (first run); (2) recomputes tiers with `LifecycleRules.tier`; (3) queues `verifyPromotion` for candidates; (4) runs `ClaimChecks` and contests failures; (5) applies `unusedPlan`; (6) turns `proposed` work-capture records that pass claim checks into `active` provisional (clock starts now); (7) prunes entries (`prune`); (8) leaves pinned/reviewed to the digest ("Precisa de você" after 14 days contested).

- [ ] **Step 1: Write the failing tests**: `firstRunMigratesAllAsProvisionalAndArchivesNothing` (188-record fixture with old `createdAt`), `unusedProvisionalArchivedAfterTtl`, `usefulUseExtendsLife`, `proposalWithPassingChecksBecomesProvisionalActive`, `proposalWithFailingClaimStaysProposed`, `pinnedAndReviewedNeverArchivedByFlagsOrChecks`, `longTermSkipsColdArchive`, `longTermInjectedInFullAtStartMaxThreeAnd600Bytes`, `forgedFrontmatterTierIgnored`, `contestedFourteenDaysGoesToDigest`.
- [ ] **Step 2: Run** `--filter LifecyclePassTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the pass and the start-of-session injection of long-term memories.
- [ ] **Step 4: Run** `--filter LifecyclePassTests`, `--filter MemoryCleanupTests`, `--filter MemoryContextTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): lifecycle pass, long-term injection, migration`.

### Task 8: Observability and docs

**Files:**
- Modify: `Sources/CollieDaemonKit/Memory/MemoryObservability.swift` (stats), `Sources/CollieDaemonKit/Memory/MemoryDigest.swift` (promotions and archives with `memory.undo`), `Sources/CollieDaemonKit/Memory/MemoryEvents.swift` (event types `flagged`, `promoted`, `demoted`, `verified` if the log needs them), `README.md` (section "Memória e lotes": provisional/earned/longTerm, `collie memory flag`, tags)
- Test: additions to `Tests/CollieDaemonKitTests/MemoryObservabilityTests.swift` and `MemoryDigestTests.swift`

**Interfaces:**
- Produces: `memory.stats` fields `lifecycle: {provisional, earned, longTerm, contestedOpen, promotions, demotions, flags: {useful, wrong, outdated}, verify: {valid, invalid, deferred}, provisionalArchived}`; digest lines for each promotion and unused archive, undoable with `memory.undo`.

- [ ] **Step 1: Write the failing tests**: `statsCountsTiersAndFlags`, `statsVerifyResults`, `digestListsPromotionAndUndoRestoresIt`, `eventsNeverCarryMemoryText` (existing privacy rule: ids, kinds and counts only).
- [ ] **Step 2: Run** `--filter MemoryObservabilityTests` and `--filter MemoryDigestTests`. Expected: FAIL on the new tests.
- [ ] **Step 3: Implement** stats, digest and events; update the README section.
- [ ] **Step 4: Run** the same filters plus `--filter MemoryEventLogTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): lifecycle stats, digest and docs`.

---

## Desvios registrados na execução (2026-11-14)

- **Teste:** worktree destacada fixa em `.build/ml-wt` com cache em `.build/memory-lifecycle` (`swift test --disable-sandbox --scratch-path ../memory-lifecycle --filter …`), reaproveitada entre tarefas em vez de criar/remover a cada vez; `--disable-sandbox` é necessário (macros dentro do sandbox do Collie).
- **T2:** "nunca contestada" para ganhar `earned` = `contestedNow` ou flag wrong/outdated em aberto; `lastContestedAt` só barra a promoção (30 d), para que uma memória absolvida pelo curador volte a ganhar uso. Um `longTerm` guardado e não contestado continua `longTerm`.
- **T3:** `pathMissing` olha só `record.path` (como `archiveMissingPath`), não caminhos no corpo. SHA candidato precisa de dígito e letra e não pode encostar em `-`. Commit checado com `git rev-parse --verify --quiet <sha>^{commit}` (não `cat-file -e`), prefixo ambíguo vira "existe" via `--disambiguate`. Erro, timeout ou pasta que não é repo nunca geram falha. No máximo 8 SHAs e 8 branches por memória.
- **T4:** formato da linha mantém o tipo: `- [<tipo> <id8>] título: corpo (provisória)`; ambos os rótulos viram `(provisória, contestada)`. `resolvePending(for terminal:correction:now:)` recebe a correção já detectada no hook (em vez de prompt/lastTurn). `endSession` virou async. A dica de flag não entra no `rulesHeader`.
- **T5:** `memory.flag` não é admin-only; quem chama sem sessão de terminal recebe `invalidArgs`. Prefixo ≥ 4 hex. A CLI aceita `--verdict` ou `--useful/--wrong/--outdated`. `useful` não conta no limite de 20. Flag repetida da mesma sessão na mesma memória é idempotente. Memória fixada ou revisada recebe a flag e fica contestada, sem penalidade e sem job.
- **T6:** o handler dos jobs fica em `Memory/MemoryLearning.swift` (o plano citava `CuratorRunner.swift`). O fallback sem modelo também vale quando o limite diário foi atingido (o parágrafo "Re-check (C)" do spec permite). Flag dentro do cooldown de 14 d não muda estado nenhum. Feedback, procedimento e memória não elegível nunca vão para o curador. Dentro do bloco do curador, as entradas viram uma linha só e os fatos vêm antes do corpo.
- **T7:** a demoção de um `longTerm` contestado não é gravada (o tier efetivo vem de `tier(for:)`); o teto de 12 conta o `longTerm` gravado. Entradas guardam a chave do store, e o prune só olha o próprio store. Na primeira execução, nada que acabou de ser criado é checado contra o repo. Cada passada contesta no máximo 10 memórias, e um texto já julgado pelo curador não é contestado de novo. A contestação por checagem é gravada com `update`, não com `addFlag`. Propostas com 14 dias ou mais, fora do conjunto do curador e de pedidos abertos, viram ativas.
- **T8:** as linhas de arquivo por falta de uso usam `at = max(now, Date())`. Desfazer um arquivo por falta de uso reinicia `tierSince`; desfazer uma promoção só rebaixa se a memória ainda for `longTerm`. `verify.deferred` conta tentativas, não memórias.
- **Revisão final (b63f022, 84ecc3a):**
  - Memória contestada fica isenta do arquivamento por score baixo e por frieza. Um veredito válido devolve exatamente a penalidade aplicada, e quando o usuário mantém a memória o score é zerado.
  - Novo `gatedAt` só para o portão de promoção; `recheckedAt` passa a ser só do re-check de contestada.
  - Novo `userKept` em resolve, restore e undo, inclusive de grupos.
  - SHA que é prefixo de id de memória é ignorado.
  - O tier fica preso ao texto (`textHash`), não ao store, porque cercado e pasto compartilham ids. `store` serve só ao prune.
  - Membros de lote recebem o bloco longTerm.
  - Arquivo corrompido vira `.corrupt`.
  - Promoção desfeita não volta sozinha.
  - Feedback e procedimento não recebem `(provisória)`.
