# Collie — Agents that learn (design)

Date: 2026-10-24. Status: draft for the user's approval.

## Intent

Agents in Collie should get better over time without the user curating memory by hand: a correction the user makes once
is never needed again, a pitfall hit once is known to the next agent, and memory stays small, current and trustworthy.
Today memory grows only from proposals the user must approve (14-day expiry), it stores facts, not lessons, and the same
classes of mistake recur (this week: symlinks, check-then-use races, sandbox rule order — each reviewer re-found them).

## What the user decided

- **Automatic by default, manual when wanted.** Collie decides what to keep, merge, retire and inject — decisions
  included. The user sees a digest ("hoje: 6 aprendidos, 2 aposentados, 1 conflito resolvido assim") and can undo any
  item in one click. Only genuine ambiguity is surfaced as a pending item, and it never blocks anything. Full manual
  management stays: pin, edit, retire, restore, history.
- **The worst failure is stale memory:** a decision taken, then rebuked/corrected/removed, that agents keep following.
  Every design choice below serves "the newest correction wins and the old one stops being injected at once".
- **Intelligence source:** the user's own Claude, through a small low-cost model (Haiku) run by Collie headless,
  optimised for cost-benefit: batched, small inputs, deterministic work done without a model.
- **All seven items:** (1) lessons from corrections, (2) review findings → per-project pitfall checklist, (3) score
  memories by outcome, (4) fast review (automatic + digest + undo), (5) periodic consolidation, (6) recurring procedures
  → skills, (7) better relevance search.

## Goals

- A user correction in any Collie Claude terminal becomes an active rule within seconds of the curator finishing, with
  provenance (the quote, terminal, time), and every memory it contradicts is superseded and leaves injection.
- Pitfalls accumulate per project with a hit count; the top ones reach every implementer/reviewer at session start.
- Memories that help rank higher; memories followed by corrections or rework rank lower and eventually retire.
- The user's attention cost is a digest, not a queue.
- Memory stays small: duplicates merged, contradictions resolved, cold items archived — all reversible.
- Recurring how-tos become procedures an agent can follow (skills where Claude supports it).
- Relevance finds memories by meaning, not only by shared words, with no network beyond the curator.

## Non-goals (now)

- Codex/Cursor auto-injection (they have no hooks; unchanged: explicit `collie memory` commands).
- Learning from the full transcript (only Collie's work registry, the user's prompt, saved memories and review files).
- Cross-machine sync.
- Training or fine-tuning anything.

## Anti-goals (failure even if it "works")

- A corrected/removed decision keeps being injected anywhere (project, lot, global).
- The curator follows instructions found in memory text, prompts or review files (prompt injection).
- Memory or curator input crosses a lot boundary, or reaches another project.
- Silent token burn: cost the user didn't expect or can't see.
- Notification noise, or a review queue the user feels obliged to empty.
- Anything deleted for real: retire = superseded/archived, always restorable.
- Writes to the user's global Claude config or committed files in the user's repo that the user didn't ask for.

## Constraints

- macOS 15.6 today: Apple's on-device model (FoundationModels) is unavailable; must work without it (and may use it
  later on macOS 26 as a cheaper path for small jobs).
- Existing model (`CollieCore/Memory.swift`): kinds decision|map|pitfall, statuses active|superseded|archived|
  discarded|proposed, scopes project|paddock|global|lot, `supersedes`/`supersededBy`, `origin`, FTS5 index (cache, files
  are truth). Repo memories live in `<repo>/.collie/memory/` (may be committed by the user); global and lot stores in
  Collie's root. Keep the format backward compatible (old files decode).
- Isolation rules of 2M stay: an agent reads its lot, its project and global; lots grant no reach.
- 4S sandbox: agents can't write Collie data; the curator runs inside its own sandbox profile.
- Injection budgets stay (4096 B start, 2048 B per prompt); new content competes inside them.
- Hooks never block or slow an agent (5 s timeout, fail open): model work is always async.
- UI copy pt-BR, Collie vocabulary. No new dependencies.

## The how (decided)

### The curator
- The daemon runs `claude -p` with a small model (Haiku), JSON output, **no tools, no MCP, no user hooks/plugins/settings**
  loaded, an empty temp cwd, inside a dedicated sandbox profile (read what Claude needs to run and log in; write only its
  temp dir and Claude's own state). Collie's own hooks are not attached (no recursion).
- One job at a time, a queue, a per-job input cap (~12 000 chars) and timeout (60 s), a **daily job cap** (default 40,
  adjustable, 0 = off) and a running count of jobs/tokens shown in the Memory panel. When the cap is hit, or `claude` is
  missing/logged out, Collie falls back to the deterministic path and says "curador indisponível: <motivo>".
- Input is data, never instructions: the system prompt says so, the content is fenced and scrubbed of known secrets
  first, and the **output is a closed JSON schema of memory operations** (create, supersede, merge, retire, score note,
  ask-user) that the daemon validates and applies itself. The curator can't name a store, scope or id outside the job's
  input; anything else is dropped.
- Each job is scoped to one store family: one lot, or one project (+ global for corrections about how the user works).

### 1. Lessons from corrections
- `UserPromptSubmit` already carries the prompt. A cheap deterministic detector (pt/en: "não,", "na verdade", "pare de",
  "para de", "nunca", "sempre", "eu disse", "errado", "não era isso", "de novo", "já falei", "remove", "desfaz"…, plus the
  user answering an agent question with a refusal) flags a likely correction; nothing else is sent anywhere.
- A flagged prompt queues a curator job with: the prompt, the terminal's active work (tasks, last notes), and candidate
  memories (FTS on the prompt, same project/lot/global). The curator answers whether it is a lasting rule; if yes: rule,
  why, how to apply, scope (global when it is about how the user works — language, tests, permissions, process; project
  when it is about the code), and which candidate memories it contradicts.
- New kind **`feedback`**. It is written **active** (not proposed), with provenance: the quoted prompt (trimmed), terminal,
  time, curator. Contradicted memories become `superseded` with `supersededBy`, and leave injection immediately (the
  per-session "already injected" cache is cleared for them so a fresh feedback can be injected on the next prompt).
- The terminal that was corrected gets the new rule on its next prompt (inside the 2048 B budget, ahead of other hits).

### 2. Pitfall checklist per project
- Sources: `pitfall` memories (saved by agents or from abandoned tasks), corrections classified as pitfalls, and review
  files the project already has (`.superpowers/sdd/**/*review*.md` and similar, read by the daemon, never by the
  curator directly beyond the fenced excerpt).
- The curator clusters pitfalls into **classes** (e.g. "symlink follow on a checked path", "check-then-use race") and keeps
  one memory per class with a `hits` count and the latest examples; a new instance bumps the class instead of adding a
  duplicate.
- A project **checklist** = top classes by hits × recency, rendered as a short "Armadilhas deste projeto" block at session
  start for every terminal in the project (inside the 4096 B budget; pinned items still first) and via
  `collie memory checklist`.

### 3. Score by outcome
- The daemon records which memories were injected into which work.
- Signals: work closed by merge/land (+), a correction in the same work about the same subject (strong −, and the
  memory is a supersede candidate), the user editing/retiring a memory (−), the memory being read/used again (+, existing
  `reads`).
- Score multiplies the existing relevance score and feeds cleanup: low score + cold → archived (reversible).
- Scores live in Collie's root (not in the repo's memory files, so the user's repo doesn't churn), keyed by memory id.

### 4. Automatic review, digest, undo
- Proposals (work-close capture, Stop-hook saves) go through the curator instead of waiting for the user: it activates,
  merges into an existing memory, or drops them. Only a real ambiguity (two rules it can't order by recency/strength, or
  a change to a pinned memory) becomes a **"Precisa de você"** item; it never blocks.
- **Digest** in the Memory panel ("Hoje / Esta semana"): each automatic action with its reason and **Desfazer**. One macOS
  notification per day at most when there is something ("Collie aprendeu 6 coisas, 1 precisa de você"), off by default
  switchable in Preferences.
- The 14-day expiry stays only for "Precisa de você" items left untouched.
- Manual management unchanged and complete (the curator never overrides a pinned memory or an edit the user made; a
  user edit is the strongest signal).

### 5. Consolidation
- Daily (and after N new memories in a store): deterministic cleanup first (existing duplicates/cold/missing-path),
  then the curator over clusters of similar memories (same subject or high similarity) to merge, supersede (newest
  wins, reason recorded) and flag unresolved contradictions. Per store, within the daily cap.

### 6. Procedures → skills
- New kind **`procedure`**: a named how-to with steps, from (a) the user stating one ("sempre que X, faça Y"), (b) the
  curator noticing the same step sequence in ≥ 3 works of a project.
- Delivery: when the installed Claude supports loading a plugin/skills directory per invocation, Collie generates one
  per terminal from the active procedures of its project/lot/global (never in the user's global config or repo). Without
  that support, procedures appear in the index and `collie memory get` like any memory.

### 7. Relevance by meaning
- Hybrid ranking: existing FTS5/bm25 plus similarity from Apple's on-device sentence embeddings (NaturalLanguage
  framework, macOS 11+) where the language is supported, plus **aliases** (synonyms/keywords) the curator adds when it
  creates or merges a memory. No network for search.

## Escape routes / failure cases to close (builder: verify each)
1. Prompt injection into the curator from memory text, user prompts quoting web pages, or review files.
2. A feedback written to global from a lot member's prompt leaking lot content (global feedback must be about the user,
   not the lot's subject matter — the curator is told, the daemon strips lot ids/paths).
3. A superseded memory still reachable through the per-session injected cache, the checklist, the index or procedures.
4. Curator runaway: loops, retries, many terminals correcting at once — queue + caps.
5. The curator's `claude -p` loading the user's global hooks/MCP and recursing into Collie, or writing to `~/.claude`
   settings.

## What is left to the builder
- Exact correction patterns and the detector's precision/recall trade-off (start conservative; a missed correction is
  cheaper than a false rule).
- The curator prompt and JSON schema; Haiku model id; how to pass "no settings/hooks/MCP" with the installed Claude
  version (spike: `claude -p --help`).
- Whether the installed Claude supports per-invocation plugin/skills dirs (spike), and the skill file format.
- NaturalLanguage embedding language coverage for pt-BR (spike) and the hybrid weighting.
- Score formula and thresholds; consolidation trigger N.
- Migration: existing proposed memories go through the curator once (within the cap) on first run.

## Decisions after the builder check

**User's answer (2026-10-24):** automatic writes go **into the repo's `.collie/memory/`** as today (visible in
`git status`, the user commits when they want, shared with the team). This counts as the user's consent for those
writes; the anti-goal about committed files covers everything else (no other repo files, no global Claude config).

**Calls I made (the user can override):**
- **Retractions reach every terminal that received the old memory.** The daemon tracks, per terminal session, which
  memory ids it injected (start, prompt, checklist, post-compact). When a memory is superseded/retired, each live
  session that received it gets, on its next prompt, a short retraction ("Não vale mais: <título>. Use: <novo>") ahead of
  everything else in the 2048 B budget (truncated titles if many). New sessions never see it.
- **The user's correction beats the user's own older pin/edit.** The correction is the user too, and newer: the old
  memory is superseded (and unpinned) at once; the digest says so with Desfazer. "Precisa de você" is only for conflicts
  the curator can't order (no clear recency/strength), and those keep the *newer* one active meanwhile.
- **Fallback for corrections** (cap hit, `claude` missing or logged out): the flagged prompt is saved durably (survives
  daemon restarts) as a queued job and processed when the curator is available; the quote also becomes a `proposed`
  feedback visible in the panel. Nothing is lost; no unchecked rule turns active. The corrected agent already has the
  user's words in its context.
- **Lot corrections** go to the lot's store (or to global when about how the user works); never straight to the project
  — moving to the project is the existing `promote` (the curator may suggest it in the digest; the user or a promote
  rule acts). **Checklist in lots:** the project pitfall checklist is shown to lot terminals too (project → lot is
  already allowed: an agent reads its lot, its project and global); lot pitfalls never flow to the project except by
  promote.

## Calls I made in the first draft (the user can override)
- Curator = Haiku via `claude -p`, sandboxed, no tools; daily cap 40 jobs, visible usage; falls back to deterministic.
- Corrections → active `feedback` immediately; scope chosen by the curator (global = how the user works, project = code).
- Scores stored outside the repo; repo memory files only change when a memory's content/status changes.
- Daily notification off by default; digest always in the panel.
- Procedures delivered as skills only via a Collie-generated per-terminal directory, never the user's config or repo.
- Embeddings via Apple NaturalLanguage (free, on-device) instead of an embeddings API.
