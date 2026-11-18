# Memory lifecycle: earned trust, agent judgement, usage-based lifetime — design

Date: 2026-11-13. Status: draft for approval.

## Intent and why

188 active memories, 180 (96%) never reviewed by the user, 0 pinned. Every one is injected tagged `(não revisada, <origem>)`, so the tag is noise and the user is a bottleneck nobody can staff. Nothing checks a memory against the repo either: one active memory still says `fix/prompt-delivery` is "não mergeada" although it is on `main`. Lifetime is time-only (60 days cold, decay with a 30-day half-life), so a memory used every day and one never used age the same way.

The owner wants the user out of the loop: the working agent judges whether an injected memory fits the work, usage decides how long a memory lives, and a memory used a lot is promoted to long-term. Project scope only.

## Goals

- A memory earns trust by being used without objection; it does not wait for a human.
- The agent that has the context says when an injected memory is wrong or stale (cheap, optional, fail-safe).
- Deterministic checks against git and disk catch the stale ones nobody flags.
- The curator model re-checks only contested memories and gates every promotion to long-term.
- Lifetime follows usage: unused memories go away sooner, used ones last, heavily used ones become long-term.
- Everything is reversible and visible in the digest and `memory.stats`.

## Non-goals

- Global, lot and paddock scopes: no automatic promotion (user decision). They keep today's rules.
- Cursor and Codex: they get no injected ids, so they cannot flag. Separate work.
- Changing search, vectors, or the pitfall checklist ranking (related, separate spec).
- A new review UI. `memory.review`, pin and restore keep working as the user's override.
- Deleting files. Archive only (`memory.purge` unchanged).

## Anti-goals

- A single agent, or a planted memory, silencing or crowning a memory on its own word.
- A sandboxed agent forging a tier by editing a file in the repo.
- Auto-promotion that touches anything the user pinned or reviewed.
- Spending the curator's daily cap on routine work (corrections stay first).

## Constraints

- Project memory lives as `.md` in `<repo>/.collie/memory`, which a sandboxed agent can write. Lifecycle state must therefore live in a daemon-owned file outside the repo (like `ScoreStore`: `<root>/learning/…`, 0600), never in the `.md` frontmatter. `pinned` and `reviewed` keep meaning "the user's"; the new tiers are separate and never set either.
- The curator is the headless curator (`claude -p` today; the provider becomes choosable in spec 2026-11-17-curator-provider), under a daily cap (`Curator.limit`, corrections reserved a quarter). Without the model, only the deterministic path and the two-flag rule run.
- Injected memory text is data, not instructions (existing headers). Flag reasons are agent text: scrub (`LotBoards.scrub`), cap 200 characters, shown to the curator inside the existing nonce-delimited input, never injected into another session.
- Tests: only changed or created tests via `--filter`; never the full suite.

## Approaches

- **A. Deterministic signals only** (reads, corrections, git/disk checks). Cheap, safe, cannot judge fit-to-context.
- **B. The working agent judges** with a flag command. Best context, depends on agent cooperation.
- **C. The curator judges in batch.** Independent of agents, small model, no work context, capped.
- **Chosen by the owner: A as the base, B as the judge, C only to re-check contested memories and to gate promotion.**

## Design

### State (daemon side store, per memory id)

`<root>/learning/lifecycle.json`: `tier` (`provisional` | `earned` | `longTerm`), `usefulUses` (set of `{day, session}` pairs), `flags` (list of `{verdict, session, day, reason}`), `contestedNow` (bool), `lastContestedAt`, `recheckedAt`, `tierSince`. Absent entry = `provisional`. Applies to `scope == .project`, status `active`, not pinned, not reviewed. Others are never tiered, never auto-archived by this feature.

- **Session** = the agent conversation: the memory event log's session id (`sessions[terminal]`, set at SessionStart), not the terminal and not the work. A re-summoned terminal or a resumed conversation with a new session id counts as a new session.
- **Injected-to-you is persisted.** The ids injected in a session (full-body lines only) are kept in the same file as `injectedBySession` and dropped 7 days after the session's last event, so a daemon restart does not make a legitimate `--wrong` fail.
- **Keyed by memory id alone** (UUIDs are unique across stores). Entries whose id is in no known store for 30 days are pruned in the consolidation pass. `memory.promote` moves lot → project only: the old lot record is superseded, its entry dropped, and the new project record starts `provisional`.

### Signals (A)

- **Useful use.** A prompt-relevance injection (`noteRead` path) leaves a `pendingUse` for that session (ids of the last injection only). It resolves at the session's next prompt: no correction (`CorrectionDetector`) and no `wrong`/`outdated` flag for it → counted, once per `(day, session)`; a correction → dropped, and the existing score penalty path runs as today. A `pendingUse` with no next prompt (session ends first) is dropped, not counted: absence of data is neutral. An explicit `--useful` flag counts immediately.
- **Claim checks** (deterministic, run in the consolidation pass): a path in `path` or in the body that is gone (existing `archiveMissingPath`); a branch name (`feat/…`, `fix/…`, `spike/…`) that is merged or deleted while the body says it is not merged or pending (pt: "não mergead", "não foi mergead", "pendente", "ainda não"; en: "not merged", "pending"); a commit SHA (≥ 7 hex) absent from the repo. A failed check sets `contested`, with the reason.
- **Map drift** (spec 2026-11-17-memory-stage-rules, item 7; owner's decision 2026-11-17): an eligible `map` is anchored at the store root's `HEAD` on its first pass, per store and text (`RepoMemory.key`, `textHash`: the pasture and each paddock worktree measure against their own branch), in `lifecycle.json` (`mapAnchors`, never in the `.md`; an older anchor without a store is replaced, uncontested; up to 32 a memory, and a store Collie no longer knows, such as a deleted paddock, loses its anchors when the entry is next written, so live stores never evict each other). From then on each pass measures `git diff --numstat <anchor> HEAD -- <path>` (commit against commit only; literal pathspec, no pager, no external diff, no textconv, no signature check). Past 40 changed lines or 40% of the file (a directory: 5 files or 30% of its tracked files; binary ignored) it is contested with a `mapDrift` reason (the numbers and up to 5 commit subjects, which is all the curator gets: `enqueueVerify` passes it as a verified fact, `mapDrift`, besides the flag). A drift is *soft*: with no model it never archives (it goes to "Precisa de você" after 14 days). When a store's drift contest is over (a valid re-check or the user keeping it), that store re-anchors at `HEAD`, the others keep theirs; an anchor git no longer has, or a path not in the anchor's tree (committed after it), re-anchors too. At most 50 maps measured a pass; drift contests share the 10-a-pass cap.
- **Cold.** Existing `archiveCold` stays for earned memories.

### Judge (B)

- Command `memory.flag {id, verdict: useful|wrong|outdated, reason?}`; CLI `collie memory flag <id> --useful|--wrong|--outdated ["motivo"]`; MCP `memory_flag`. Terminal token only.
- Accepted only for an id injected into the caller's own session (`injectedBySession`), at most 20 flags per session. Anything else is `invalidArgs`.
- Full-body injected lines carry a short id (first 8 hex of the UUID): prompt-relevance, pushed rules, checklist, pinned and long-term lines. Index (title-only) lines do not: the agent has not read those memories. The flag command accepts any unambiguous prefix among the ids injected to the caller's session; an ambiguous prefix is `invalidArgs` asking for more characters. The header gains one line: "memória errada ou velha: `collie memory flag <id> --wrong|--outdated`".
- The Stop ask (`MemoryCapture.stopReason`) gains: "e marque as memórias injetadas que estavam erradas ou velhas". No flag means no change.
- `wrong`/`outdated`: `ScoreStore.penalize(id, -0.3)`, `contested = true`, curator re-check queued, memory still injected but tagged `(contestada)`.
- A user-reviewed or pinned memory is never archived by flags: it goes to the digest's "Precisa de você" (`memory.resolve`).

### Re-check (C)

- New curator job kind `verify`: input = the memory, flag reasons (data), and the deterministic facts (branch merged?, path exists?, SHA exists?). Output uses existing ops: `retire` (invalid), `score` (small), or no op (valid).
- Verdict `valid`: flags cleared, 14-day cooldown before flags can contest it again. Verdict `invalid`: archive (reversible via `memory.undo` / `memory.restore`).
- **Flags never archive without a verdict.** Two flags from two distinct sessions only make the re-check urgent. With no model, or the cap reached, the memory stays `(contestada)` and is archived only if a deterministic claim check also failed (a map drift doesn't count); after 14 days still contested it goes to the digest's "Precisa de você". So a planted second session cannot silence a memory by itself.
- The same job kind gates promotion (below). Budget order inside the daily cap: corrections (reserved quarter), then `verify` of contested memories, then `verify` for promotion (at most 3 a day), then routine jobs. Cap reached: the memory stays as it is, retried next day.

### Tiers and lifetime (starting values, tuned from `memory.stats`)

| Tier | How it gets there | Injected as | Lifetime |
|---|---|---|---|
| provisional | any new `active` memory not from the user | `(provisória)` | archived after the kind's TTL (below) counted from `max(tierSince, last useful use)` with no useful use |
| earned | ≥ 2 useful uses on ≥ 2 distinct days and ≥ 2 distinct sessions, never contested | no tag | existing cold rule (60 days unread) |
| longTerm | earned + ≥ 8 useful uses over ≥ 4 distinct days spanning ≥ 14 days, not contested in 30 days, **and** a `verify` pass says valid | no tag; up to 3 injected in full at session start (≤ 600 B), rest in the index | no decay, no cold archive; at most 12 per project |

- Provisional TTL per kind (2026-11-17; was 21 days for all):

  | Kind | TTL | Digest reason |
  |---|---|---|
  | decision | 21 days | `provisória sem uso há N dias (prazo de decisão: 21)` |
  | map | 21 days | `provisória sem uso há N dias (prazo de mapa: 21)` |
  | pitfall | 60 days | `provisória sem uso há N dias (prazo de armadilha: 60)` |
  | procedure | 60 days | `… (prazo de procedimento: 60)`; today out of the cycle as a user's kind, the value only guards the rule |
  | feedback | none | user's kind, never archived by the lifecycle |

  Pitfalls and procedures are used rarely and cost a lot to lose, so they wait as long as the earned cold rule (60 days). Archive stays reversible (digest + `memory.undo`). At the change: 230 eligible (126 pitfall, 104 decision, 0 map), 48 provisional, all with a clock started at the migration (≥ 2026-11-14), so the first pass archives nothing under either rule; the first decisions can go from ~2026-12-05, the first pitfalls from ~2027-01-13.
- Demotion: a contested longTerm falls back to earned until re-checked.
- Work-capture proposals (`proposed`, 14-day expiry today) become `provisional` active once the claim checks pass, instead of expiring unseen; their provisional clock starts at that moment, not at proposal creation. (My call; see below.)
- The label `(não revisada, <origem>)` is replaced by `(provisória)` on provisional memories only. Earned, longTerm, reviewed and pinned memories carry none.

### Session-start budget (leva 2, item 5, 2026-11-17)

- Order inside the 4 096 B: header and pinned memories in full, long-term (≤ 3, ≤ 600 B), the pitfall checklist (≤ 1 200 B), Cursor's focus block (its own budget, total 9 000 B), the index.
- Pinned cap: header + pinned in full take at most `limit − 2 496` B (`MemoryService.pinnedReserve`; never below the header), 1 600 B of the usual 4 096, so the long-term block (600), the checklist (1 200) and the index (≥ 696) keep their room. Measured that day: the real project had 0 pinned of 251 active (the block was the bare header), so the cap only binds past ~4 pinned lines. A pinned memory past the cap is never dropped: it becomes an index line marked `(fixada)`, first in the index; it is not counted as injected.
- Index order: by use (number of `usefulUses` in `lifecycle.json`), ties newest first, records without a lifecycle entry last. A title that doesn't fit is skipped and the next ones are still tried (was: the index stopped at the first one).
- Provenance unchanged: an unverified memory (pinned or not) is only a title marked `(editada fora do Collie)`, never `(fixada)`, never in full.

### Observability

`memory.stats` gains: counts per tier, promotions, demotions, flags by verdict, contested open, `verify` results (valid/invalid/deferred), provisional archived. The digest lists every promotion and archive with `memory.undo`.

Precision (2026-11-17, Leva 1): beside coverage, `usage.precision` = useful uses counted at the next prompt ÷ the prompt-injected ids that can earn one (also per agent and in the weekly trend). Definitions in `2026-11-17-memory-measurement-baseline.md`. Measurement only: no cut, tier or TTL rule changed.

### Testing

- Pure units: tier transition function (uses → tier), lifetime/archival plan, claim checks against a fixture repo (merged branch, missing SHA, missing path).
- `memory.flag` rules: not-injected id refused, rate limit, scrub, per-session distinctness, pinned/reviewed never archived.
- `verify` job: op validation and cap behaviour with a fake curator call; no-model fallback.
- A forged `.md` (frontmatter claiming a tier) changes nothing.
- Injection text: id present, `(provisória)` and `(contestada)` tags, header line.

## Left to the builder

File and type names, the exact short-id format, the scrub of reasons, how the consolidation pass schedules claim checks, the `verify` prompt wording, the digest wording, and how `lifecycle.json` is migrated for the 188 existing memories (start all as provisional; their clock starts at the first run, not at `createdAt`, so nothing is archived by the migration itself).

## Calls I made (check these)

- Lifecycle state outside the repo (a sandboxed agent can write `.md` files).
- Passive "no correction" counts as use, but longTerm needs the curator gate; absence of objection is weak evidence and a planted memory could collect it.
- The numbers: 21 days (decision/map; 60 for pitfall/procedure since 2026-11-17), 2 uses / 2 days / 2 sessions, 8 uses / 4 days / 14 days, 12 longTerm per project, 3 in full at start, −0.3 per flag, 14-day cooldown.
- One flag contests; only a curator `invalid` verdict, or a failed claim check with no curator available, archives. Two flags from distinct sessions just make the re-check urgent. (Closes the "two planted sessions" hole.)
- A session is the agent conversation (memory event log session id); injected-to-you is persisted; a use whose next prompt never arrives is dropped, not counted.
- Verify budget order: corrections, contested re-checks, promotion gates (≤ 3 a day), routine.
- Ids only on full-body injected lines, not on title-only index lines; prefix match among the caller's injected ids.
- lifecycle entries keyed by memory id, pruned after 30 days with no store holding it; promotion lot → project starts a new provisional entry.
- Contested memories stay injected with a tag, not removed, so one confused agent cannot hide a good memory.
- Proposals become provisional instead of expiring.
- Lines carry an 8-hex id. Cursor and Codex excluded.
