# Pitfall checklist ranked by what the session is about — short design

Date: 2026-11-13. Status: in progress (the owner said "pode começar" after the analysis).

## Why

The pitfall checklist injected at every session start (≤ 7 lines, ≤ 1 200 B) is ranked by `hits × recency × score`, not by the work. Over a week the same 5 pitfalls were injected 120 times each, 3 of them about Android and devices while the work was a deck export. 67 of the 76 pitfalls with `hits` have exactly 1 hit, so the order at the top is decided by a few points.

## Goal

At session start, the checklist leads with the pitfalls most relevant to what the session is working on, then fills the rest with the strongest recurring ones. No signal means today's behaviour.

## Non-goals

- `memory.checklist` (the command) keeps "most hit first".
- Prompt-time relevance, search, vectors: unchanged.
- No new signal storage; the focus is computed per session start.

## Design

- **Focus text** (≤ 600 chars), built from what exists at session start: branch name words (without `feat`, `fix`, `spike`, `docs`, `chore`, `collie`, `main`, `master`), the active work's title and open task titles, the last commit subjects, the changed paths' last two components, the cercado name, the lot goal. All parts optional; none gives an empty focus.
- **Pick** (`ChecklistRanking.pick`): up to **4** slots by relevance (score from the existing index search of the focus over pitfalls, kept when ≥ 0.4 × the best score), then fill to the existing max (7) by the old `hits × recency × score` rank. When the focus names a platform (`MemoryService.platforms`), pitfalls about another platform are dropped from both parts, like the prompt path does; when it names none, any platform may fill.
- **Pure first.** `ChecklistFocus.build` and `ChecklistRanking.pick` are pure and tested alone. The wiring (git signals in the `memory.hookContext` handler, index search in `checklistParts`) follows once `MemoryService.swift` is free: the `memory-lifecycle` terminal edits `checklistParts` in its Task 4, and two agents editing it at once is how hunks get lost.

## Calls I made

- 4 relevance slots and 3 fill slots, 0.4 relative cut, 600-char focus: starting values, tune with `collie memory stats` (injections per memory).
- The old rank stays as the fill, so a repository with no usable signal behaves as before.
- Git signals fail open (no repo, timeout, error → empty focus), because the hook has 5 s.
