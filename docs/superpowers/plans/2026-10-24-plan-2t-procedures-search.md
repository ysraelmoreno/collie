# Plan 2T — Procedures as Skills, Relevance by Meaning

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recurring how-tos become `procedure` memories (stated by the user, or noticed in ≥ 3 works of a project) that Claude terminals get as skills from a Collie-generated per-terminal plugin dir; memory search finds things by meaning (on-device sentence embeddings) and by curator-added aliases, not only by shared words.

**Architecture:** `procedure` is a new `MemoryKind`, created through 2R's curator ops. Delivery: `AgentLaunch.launchSpec` adds `--plugin-dir <root>/sandbox/<id>/plugin/collie-procedures` (a dir the terminal can already read, removed with the terminal by `SandboxLaunch.remove`), regenerated from the active procedures of the terminal's project/lot/global — never in the user's config or repo. Search: `MemoryIndex` gets a `vecs` table (cache, rebuilt with the index) filled by an injected `MemoryEmbedder` (live: `NLEmbedding.sentenceEmbedding`, pt/en), and an `aliases` FTS column; `search` blends bm25 and cosine.

**Tech Stack:** Swift 6.2, Swift Testing, NaturalLanguage (`NLEmbedding`, `NLLanguageRecognizer`, macOS 11+, already in the SDK: no new dependency), SQLite FTS5, 2R curator.

**Spec:** `docs/superpowers/specs/2026-10-24-agent-learning-design.md` (items 6 and 7; "What is left to the builder": plugin/skills spike, pt-BR embedding spike, hybrid weighting).

## Global Constraints

- NEVER run the full test suite (user decision): only the tests a task creates or changes, `swift test --filter <Suite or test>`.
- Tests never spend tokens and never run a real `claude` session: fake curator runner; `claude plugin validate` (tokenless) is allowed only in the Task 1 spike and in a test skipped when `claude` is absent.
- Temp roots and fake HOME; never the user's global Claude config, `~/.claude/skills`, `~/.claude/plugins`, or any repo file outside `.collie/memory/`.
- Pinned from `claude --help` (2.1.310): `--plugin-dir <path>` loads a plugin "for this session only" (repeatable); `claude plugin validate [--json] <path>` validates a plugin dir without a session.
- Embeddings: on-device only, no network for search. Languages: Portuguese and English (`NLLanguage.portuguese`/`.english`); any other or an unavailable model → bm25 + aliases only, never an error.
- Hybrid score: `m × (0.6 × b / bTop + 0.4 × max(cos, 0))`, where `b` is the raw bm25 (negated), `m` the existing multiplier (reads × recency, or 1.5 pinned) × 2S `ScoreStore.factor`; vector candidates need `cos ≥ 0.55`; `MemoryService.minRelativeScore` (0.25) applies to the blended score.
- Per-prompt budget stays 2048 B and the hook's 5 s timeout: a prompt's embedding uses its first 1 000 characters.
- UI copy pt-BR, Collie vocabulary. No new dependencies.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01PjAbEfJwb2ZH5ScKq3gEbN`

## Review Focus

1. A procedure is superseded while a Claude session that loaded it as a skill is live: its file is gone from the plugin dir and the session's next prompt carries "Não vale mais" (Task 4 `supersededProcedureRetracted`).
2. A procedure title like `../../.ssh/x` or with `---` in the body cannot write outside the plugin dir nor break the SKILL.md frontmatter (Task 4 `skillNamesAndFrontmatterSafe`).
3. The installed `claude` is missing or older (no `--plugin-dir`): terminals launch exactly as before, procedures appear in the index and `collie memory get` (Task 4 `noPluginSupportNoFlag`).
4. A Portuguese query "como rodo os testes?" finds a memory titled "Suíte: só swift test --filter" that shares no word with it (Task 5 `meaningMatchesPortuguese`, fake embedder; the probe test checks the real one).
5. A repo of 2 000 memories: a prompt's hybrid search stays under 300 ms on the store queue (Task 5 `hybridSearchFast`).

---

### Task 1: Spike gates — plugin dir and pt embeddings

**Files:**
- Create: `Tests/CollieDaemonKitTests/EmbeddingProbeTests.swift` (it writes a minimal plugin into a temp dir: `.claude-plugin/plugin.json`, `skills/rodar-testes/SKILL.md`)

**Interfaces:**
- Produces: the decisions Tasks 4 and 5 read, recorded in the commit body: (a) the plugin layout `claude plugin validate --json` accepts; (b) whether `NLEmbedding.sentenceEmbedding(for: .portuguese)` is non-nil on this Mac (the SDK header marks it `nullable`, macOS 11+; languages are not listed in headers).

- [ ] **Step 1:** The temp plugin: `plugin.json` = `{"name":"collie-procedures","version":"1.0.0","description":"Procedimentos aprendidos pelo Collie"}`; `SKILL.md` = frontmatter `name: rodar-testes`, `description: Quando for rodar testes neste projeto.`, then numbered steps.
- [ ] **Step 2: Gate A (tokenless):** `claude plugin validate --json <that temp dir>` → valid. If it reports a layout problem, fix the layout to what it accepts (that layout is what Task 4 renders). If `validate` or `--plugin-dir` is missing, Task 4 ships only `noPluginSupportNoFlag` (delivery stays index + `memory get`).
- [ ] **Step 3: Tests** in `EmbeddingProbeTests`: `pluginFixtureValidates` (runs `claude plugin validate --json`; `.enabled(if:)` `claude` is on PATH); `portugueseSentenceEmbeddingProbe` and `englishSentenceEmbeddingProbe` (non-nil, `dimension > 0`, cosine("rodar os testes", "executar a suíte de testes") > cosine("rodar os testes", "cor do botão")); `.enabled(if:)` the embedding exists, so a Mac without the asset skips instead of failing.
- [ ] **Step 4: Gate B:** run `swift test --filter EmbeddingProbeTests`. Portuguese skipped → Task 5 still ships (English + aliases), and the commit says pt is unavailable here.
- [ ] **Step 5: Commit** `test(memory): spike gates for skills dir and pt embeddings` (body: both outcomes).

### Task 2: `procedure` kind, stated by the user

**Files:**
- Modify: `Sources/CollieCore/Memory.swift` (`MemoryKind.procedure`), `Sources/CollieDaemonKit/Memory/CorrectionDetector.swift` (2R; add `isProcedure`), `Sources/CollieDaemonKit/Memory/MemoryLearning.swift` (the correction job also allows `create procedure`), `Sources/CollieDaemonKit/Memory/MemoryService.swift` (`renderContext` index line `- [procedimento] <título>`; `relevantLine` label `procedimento`), `Sources/CollieDaemonKit/MemoryCommands.swift` (`memory.save --kind procedure` allowed for agents; kind messages), `Sources/ColliePlugins/MemoryPanel.swift` (label, a "Procedimentos" section in Decisões)
- Test: `Tests/CollieDaemonKitTests/ProcedureTests.swift`

**Interfaces:**
- Consumes: 2R `CorrectionDetector`, `enqueueCorrection`, `CuratorNew`, `applyOps`.
- Produces: `CorrectionDetector.isProcedure(_ prompt: String) -> Bool` (pt/en: "sempre que … , (faça|rode|use|…)", "toda vez que", "whenever … ,"); a procedure record: `subject` = slug of its name, `title` = name, body `Quando: <gatilho>\n\n1. …` (≤ 12 steps, each ≤ 200 chars).

- [ ] **Step 1: Tests**
  - `detectsStatedProcedure` (`"sempre que mexer no sandbox, rode SandboxProfileTests e confira o perfil"`, `"toda vez que criar um plano, commite com os trailers"`, `"whenever you add a command, update the MCP schema"`) and `notAProcedure` (`"sempre que possível"`, `"sempre"` alone).
  - `statedProcedureCreated` (fake returns `create procedure` → active, `origin: "curador (<terminal>)"`, body starts `Quando:`).
  - `procedureInIndexAndGet` (session start index shows `[procedimento]`; `memory get` returns the steps; `memory list --kind procedure`).
  - `procedureOldFilesDecode` (2R files unchanged).
- [ ] **Step 2:** Run `swift test --filter ProcedureTests` → FAIL.
- [ ] **Step 3:** Implement (the stated-procedure prompt queues the same `correction` job; the instructions say a "sempre que X, faça Y" becomes a procedure).
- [ ] **Step 4:** Tests PASS.
- [ ] **Step 5: Commit** `feat(memory): procedure kind from what the user states`.

### Task 3: Procedures noticed in ≥ 3 works

**Files:**
- Create: `Sources/CollieDaemonKit/Memory/ProcedureDetector.swift`
- Modify: `Sources/CollieDaemonKit/Curator/Curator.swift` (`CuratorJobKind.procedure`), `Sources/CollieDaemonKit/Memory/MemoryLearning.swift`, `Sources/CollieDaemonKit/Memory/Consolidation.swift` (2S; the daily run calls the detector per project)
- Test: `Tests/CollieDaemonKitTests/ProcedureDetectorTests.swift`

**Interfaces:**
- Consumes: `WorkStore` closed works, `CommandRouter.closeCwd`, 2S `consolidate` loop.
- Produces: `enum ProcedureDetector { static let minWorks = 3, minSteps = 3; static func step(_ taskTitle: String) -> String; static func recurring(_ works: [[String]]) -> [[String]] }` — `step`: lowercased, digits and punctuation stripped, first 6 `MemoryService.significantTerms`; `recurring`: step sequences of length ≥ 3 occurring in order (not necessarily adjacent) in ≥ 3 works, longest first, none that is a subsequence of another kept one.

- [ ] **Step 1: Tests**
  - `findsSequenceInThreeWorks` (tasks "Escrever teste falhando", "Implementar", "Rodar filtro", "Commit" in 3 works with other tasks between → one sequence of 4).
  - `twoWorksNotEnough`, `subsequencesCollapsed`, `otherProjectsIgnored` (works of another repo never count).
  - `curatorNamesProcedure` (one `procedure` job with the sequence and the 3 works' titles; fake `create procedure` → active; `drop` → nothing, and the same sequence is not sent again: seen sequences in `<root>/learning/procedures.json`).
- [ ] **Step 2:** Run `swift test --filter ProcedureDetectorTests` → FAIL.
- [ ] **Step 3:** Implement. ponytail: works whose terminal is gone count only when `closeCwd` knows their cwd.
- [ ] **Step 4:** Tests PASS.
- [ ] **Step 5: Commit** `feat(memory): recurring work steps become procedures`.

### Task 4: Per-terminal skills dir (gated by Task 1)

**Files:**
- Create: `Sources/CollieDaemonKit/Memory/ProcedureSkills.swift`
- Modify: `Sources/CollieDaemonKit/AgentLaunch.swift` (`launchSpec(... pluginDir: URL? = nil)` → ` --plugin-dir <quoted>` for Claude only), `Sources/CollieDaemonKit/CommandRouter.swift` (render before launch; re-render live terminals of the store when a procedure changes), `Sources/CollieDaemonKit/Memory/MemoryService.swift` (`contextText` counts the delivered procedure ids as injected, so 2R retractions cover them)
- Test: `Tests/CollieDaemonKitTests/ProcedureSkillsTests.swift`, `Tests/CollieDaemonKitTests/AgentLaunchTests.swift`

**Interfaces:**
- Consumes: Task 1 layout, Task 2 records, 2R `MemoryService.retractions`.
- Produces: `enum ProcedureSkills { static func dir(_ terminal: UUID, root: URL) -> URL /* SandboxLaunch.dir(id)/plugin/collie-procedures */; static func render(_ procs: [MemoryRecord], into dir: URL) throws -> Set<UUID>; static var supported: Bool /* --plugin-dir in the installed claude's help, cached */ }`.

- [ ] **Step 1: Tests**
  - `rendersValidPlugin` (plugin.json + one `skills/<slug>/SKILL.md` per active procedure; `pluginFixtureValidates`-style check when `claude` exists).
  - `skillNamesAndFrontmatterSafe` (Review Focus 2: slug `[a-z0-9-]` ≤ 48 via `MemoryFile.fileName`'s rule; description one line ≤ 200 with no `---`; files 0600, dirs 0700; nothing written outside `dir`; a pre-existing symlink at `dir` is refused).
  - `claudeGetsPluginDir` (`AgentLaunchTests`: the `-lc` command contains `--plugin-dir '<dir>'`; Codex/Cursor/shell never).
  - `noPluginSupportNoFlag` (Review Focus 3).
  - `onlyReadableProcedures` (project + own lot + global; never another lot's).
  - `supersededProcedureRetracted` (Review Focus 1).
  - `removedWithTerminal` (`SandboxLaunch.remove` deletes it; free terminals too).
- [ ] **Step 2:** Run `swift test --filter "ProcedureSkillsTests|AgentLaunchTests"` → FAIL.
- [ ] **Step 3:** Implement; render even with zero procedures (an empty `skills/`), so the flag never points at nothing.
- [ ] **Step 4:** Tests PASS.
- [ ] **Step 5: Manual:** in a new Claude terminal of a project with a procedure, `/` lists `collie-procedures:<slug>`; nothing appears under `~/.claude`.
- [ ] **Step 6: Commit** `feat(memory): procedures delivered as per-terminal skills`.

### Task 5: Hybrid search with on-device embeddings

**Files:**
- Create: `Sources/CollieDaemonKit/Memory/MemoryEmbedder.swift`
- Modify: `Sources/CollieDaemonKit/Memory/MemoryIndex.swift` (`user_version` 2: `vecs(id TEXT PRIMARY KEY, lang TEXT NOT NULL, v BLOB NOT NULL)`; filled in `put`; `search(... vector:)` blends), `Sources/CollieDaemonKit/Memory/MemoryService.swift` (embed the prompt once per `relevant` call), `Sources/CollieDaemonKit/MemoryCommands.swift` (`memory.search` uses it), `Sources/CollieDaemonKit/Daemon.swift` (`DaemonConfig.embedder: any MemoryEmbedder = NLMemoryEmbedder()`)
- Test: `Tests/CollieDaemonKitTests/HybridSearchTests.swift`

**Interfaces:**
- Produces: `protocol MemoryEmbedder: Sendable { func embed(_ text: String) -> (lang: String, vector: [Float])? }`; `struct NLMemoryEmbedder: MemoryEmbedder` (`NLLanguageRecognizer` constrained to pt/en, `NLEmbedding.sentenceEmbedding(for:)` loaded once per language behind a lock); `MemoryIndex.init(dbFile:store:repoRoot:embedder:)`; `MemoryIndex.search(_ query: String, vector: (lang: String, vector: [Float])?, limit: Int, kinds:includeInactive:) -> [MemoryHit]`.

- [ ] **Step 1: Tests** (a fake embedder: words map to fixed concept vectors, e.g. teste/suíte/filter → one axis)
  - `meaningMatchesPortuguese` (Review Focus 4). `bm25StillWins` (an exact-word hit outranks a merely similar one).
  - `blendFormula` (fixture scores match the Global Constraints formula to 1e-9).
  - `otherLanguageFallsBack` (embedder returns nil → results identical to plain FTS).
  - `vectorsRebuiltWithIndex` (v1 db → v2: docs/fts/vecs rebuilt from files, `stats` kept).
  - `onlyVisibleByVector` (a vector-only hit still passes `MemoryService.visible`, `present`, and never comes from another lot's store).
  - `hybridSearchFast` (Review Focus 5; 2 000 records, fake embedder of dimension 512).
- [ ] **Step 2:** Run `swift test --filter HybridSearchTests` → FAIL.
- [ ] **Step 3:** Implement. Vector text = title + first 500 characters of body. ponytail: brute-force cosine over the store's `vecs`; an ANN index if a store passes ~20 000.
- [ ] **Step 4:** Tests PASS.
- [ ] **Step 5: Commit** `feat(memory): relevance by meaning with on-device embeddings`.

### Task 6: Curator aliases

**Files:**
- Modify: `Sources/CollieCore/Memory.swift` (`MemoryRecord.aliases: [String]`, frontmatter `aliases: ["a","b"]` as one JSON array, omitted when empty), `Sources/CollieDaemonKit/Memory/MemoryIndex.swift` (FTS column `aliases`; `user_version` 3 rebuilds docs/fts/vecs, keeps `stats`), `Sources/CollieDaemonKit/Curator/CuratorOps.swift` (`CuratorNew.aliases`, `merge(... aliases:)`; schema), `Sources/CollieDaemonKit/Memory/MemoryLearning.swift` (instructions ask for up to 8 aliases on create/merge)
- Test: `Tests/CollieCoreTests/MemoryRecordTests.swift`, `Tests/CollieDaemonKitTests/HybridSearchTests.swift`, `Tests/CollieDaemonKitTests/CuratorOpsTests.swift`

**Interfaces:**
- Consumes: 2R ops/applier, Task 5 index.
- Produces: `MemoryRecord.aliases` (≤ 8, each ≤ 40 characters, normalized like `subject`).

- [ ] **Step 1: Tests**
  - `aliasesRoundTrip`, `noAliasesFileUnchanged` (an old file rewrites byte-identical).
  - `aliasMatches` (alias "suíte" makes "suíte" find a memory whose text never says it).
  - `aliasesBounded` (op with 12 aliases of 60 chars → 8, each 40; an alias with `"`/newline normalized away).
  - `mergeUnionsAliases` (merge keeps the union, ≤ 8, newest first).
- [ ] **Step 2:** Run `swift test --filter "HybridSearchTests|MemoryRecordTests|CuratorOpsTests"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Tests PASS.
- [ ] **Step 5: Commit** `feat(memory): curator aliases widen what search finds`.
