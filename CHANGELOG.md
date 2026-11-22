# Changelog

All notable changes to Collie, by version. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow the repository's `v*` tags (each tag publishes a signed and notarized release).

Names in quotes are labels of the app, which is in Portuguese.

## [Unreleased]

## [0.1.9] — 2026-11-21

### Added
- **Per-project loop config (`collie-work.json`):** a versioned file at the project root can declare the loop's `gate` and `precheck` (defaults for `work run`; the flag always wins), named `areas` (`collie work task add --area ask,quadro` builds the check as `area && area && smoke`), a `smoke` command and a `full` gate. `collie work config` shows what it resolves to and runs nothing. The loop reads the committed version (HEAD), never the working tree, and fails an attempt that edits the file; commands that would change what the `&&` chain means (`;`, `||`, `#`, `&`) are refused, and `work run` warns when the file has uncommitted changes. Projects without the file behave exactly as before.
- **Shepherd context lifecycle:** the large-context advice now reads the real context size in tokens (150k and 250k levels, numbers only, never conversation text), and at the end of a loop the daemon writes a short handoff for the next turn (`collie work handoff`).
- **Turn safety for loops:** the attempt prompt carries two fixed rules (run build and tests in the foreground; `swift build` does not compile tests), and `collie work run --precheck <cmd>` runs a fast check in the agent's own session before the full check, so a compile error costs a nudge instead of an attempt.
- **Quadro example app** (`Examples/apps/quadro`): a local kanban board (Python 3.9, standard library only) with a `collie.json` contract, so `collie app adopt quadro` gives agents commands to create, move, comment on, archive and restore cards while the owner watches the board in a panel. Data stays in `$QUADRO_DIR` (default `~/.collie/quadro`), with a readable `BOARD.md` mirror. Cards have a type (impl, bug, refactor, spike, test, docs, chore) and a priority (high, medium, low), with filters in the UI and in `list-cards`; a board from the first version migrates to `schema` 2 on first open, keeping a `board.json.v1.bak` copy.
- **Tokens in the immutable summary:** each task keeps its attempts' token counts (counts and model name only); `collie work usage` also reads closed works of the caller's paddock, and the loops modal shows the totals.

### Changed
- **Faster checks:** `AskTests` went from about 173 s to 30 s (every ask time limit is one injectable value, production defaults unchanged); an attempt's agent reuses one build folder per loop instead of compiling cold on each attempt (`scripts/dev/prune-builds.sh` lists, and with `--apply` removes, the old ones); `scripts/laco-check.sh` validates every filter against real suites, runs a task's declared area plus a fixed smoke set, and runs the whole list only with `--full`.
- **CI:** the build caches `.build`, each test shard has a timeout and prints the last test it started, and a shard that hangs fails instead of being cancelled an hour later.
- Near-duplicate memories of the same kind and scope (same subject, three or more shared title terms, or close vectors) no longer enter one injection block together; only the best of each group is injected. Nothing in the memory store changes.

### Fixed
- An app panel opened right after `collie app attach` (the service still starting) stayed blank: it now shows "Iniciando <app>…", loads the page by itself when the service comes up, and says "não está respondendo em <address>" if the service reports running but never answers.
- The full-screen button (and the other controls of a terminal's title bar) did nothing on the canvas at any zoom other than 100%.
- Parallel loop lanes no longer raise sandbox access cards (granting one restarted the lane's agent mid-attempt); the denials stay, they are just not asked about.

## [0.1.8] — 2026-11-21

### Added
- **"O que o Collie faz":** an info icon (above the usage summary in "Trilho", beside it in "Compacta") opens a carousel of 17 cards, one per feature, with how to call it and a button that takes you there. It never opens by itself; a dot on the icon shows while there are cards you have not seen.
- **Agent hooks for plug-ins:** an external plug-in can declare `hooks` (`edit`, `stop`) and a `helper`; the daemon hands it the files an agent wrote and returns its answer to the agent, as guidance or as a block. The helper runs once per event in its own sandbox (reads the project, writes only its data folder, no network), with a 3 s deadline, and any failure is silent. Claude terminals only. Installing shows what the plug-in may do. API: `docs/plugins/api-v1.md`.
- **Vizinho plug-in** (`Examples/plugins/vizinho`, built with `scripts/build-vizinho-plugin.sh`; not bundled): when an agent writes a file, it says what the sibling files of the same kind do (imports, paired test) and names a model file. It also mines conventions nearly every file follows and proposes them as fences; the ones the owner approves block the end of a turn that breaks them.
- **Custom themes:** Preferences › "Aparência" has a gallery of themes and an editor with two views of the same file, "Lista" and "JSON", beside a preview. A theme is a JSON file in `~/Library/Application Support/Collie/themes/` that names the colours it changes and the built-in theme it extends; it reloads when saved in any editor.
- **Canvas:** dragging with the middle mouse button pans; several items can be selected (⌘-click, ⇧-click, a rectangle dragged on empty canvas) on the canvas and in the side panel, with the existing actions in a context menu for all of them.
- **DMG:** the installer window has a background and positioned icons (`scripts/make-dmg.sh`); where Finder cannot be driven the DMG is built without the layout, with a warning.

- **Drag and drop into terminals:** dropping files or an image on a terminal pastes their shell-escaped paths, as Terminal.app does, so agents attach the image; an image with no file of its own is saved as a PNG first.
- **Loops that say why they stopped:** every loop that stops records the reason (`stopReason`), with a note, in `collie work status` and in the end notice.
- **Loop journal:** `collie work status --events [N]` shows the latest loop events (turn, check, gate, verdict), up to the newest 100.
- **Waiting on a loop without a terminal:** `collie work wait [--since N] [--timeout S]` answers when the work changed or the loop ended; `work status` says since when the phase has been running and when the turn expires. `/collie:loop` and the Shepherd's orientation now teach `work wait` instead of waiting for a typed notice.
- **Reopening a task:** `collie work task reopen <task> [--keep-tries]` puts a deferred or abandoned task back in the queue, in the same position.
- **Parallel tasks:** `collie work run --parallel <n>` (default 1, at most 4) runs each task in a lane (a temporary worktree of the loop) and integrates them one at a time, running the gate again after each merge; `collie work task add --scope --needs` declares what each task touches and what it depends on (without `--scope` a task runs alone). Status, `work wait`, the journal and the card show the lanes. A lane writes only its own branch; `--budget` counts the lanes alive; the sweeper removes only lanes its own daemon made. `scripts/dev/lane-coldbuild.sh` measures a lane's cold build cost.
- **Agents of the loop have names of their work:** `<work>-<task>-t<attempt>` instead of `loop-<random>`.
- **Loops in the side panel ("Trilho"):** a "LAÇOS" section under "Lotes" shows the running loop as a card (work title, progress bar, done/total, current attempt and phase) and exists only while a loop runs; "Ver tudo" opens a modal with the loop's tasks (state, attempt, agent) and the last 20 closed works of the paddock, whose detail (tasks, attempts, full timeline) opens inside the modal and can still be opened as a page in the canvas. Without a running loop, "Ver tudo" stays while the paddock has history.
- **Immutable summary of a closed work:** when a work closes the daemon writes a summary that never changes (full timeline, up to 500 events), and `collie work history [--limit N] [--id <work>]` reads it for the caller's paddock.
- **Token accounting for loops:** `collie work usage` and `collie work status` show, per attempt, the tokens the agent spent (counts only, never content).
- **The loop stops when the model's usage limit is hit** instead of waiting an hour for the agent: a clear note and no attempt is spent.
- **Default model for a loop's agents:** a preference in Preferences › "Laços" (`--model` still wins), so agents do not inherit a model that has hit its limit.
- **`collie work run --notify task|end`:** with `end` (now the default for new loops) the Shepherd is told only when a task is deferred, a loop stops or ends; the state is read with `collie work wait`.
- **Large-context advice:** the Shepherd's Stop hook says once, in one line, when its session has grown large and each turn re-reads it all.
- **"Abrir painel" with the Prévia plug-in** now has a picker for an artifact or an HTML file.

### Changed
- **Device panel:** the screen sits inside a frame drawn for the kind of device (phone, foldable, tablet, modern iPhone, iPhone with a home button, iPad), picked automatically; the buttons are icon pills and the link state ("ao vivo", "conectando", "offline") moved to the footer with a colored dot. Small panels and physical devices show no frame.
- The Stop hook asks for memories at most every 20 minutes, never while a loop of the work is running, and only for work that is not the loop's own commits.
- The loop resubmits the Enter of a prompt that was typed but not submitted, and nudges an agent that ends its turn early with no commit, instead of burning the attempt.
- After a daemon crash, the loop resumes the commit the attempt had already made instead of restarting the task; stopping the daemon no longer spends the attempt in progress.
- This changelog is written in English.

### Fixed
- Loop gate leftovers are moved to a quarantine inside `.git` instead of being deleted, with literal paths; an orphaned `collie work wait` no longer hides a Shepherd that is editing; a work closed while its loop runs keeps the whole timeline in its summary.
- Loop: a task no longer stays "in progress" because of an out-of-phase event; a malformed new field in the work record no longer breaks reading the work; the journal writes half as often per attempt.
- **Deterministic CI:** the test step (`scripts/ci/run-tests.sh`) no longer trusts the exit code of `swift test`, which was green with 237 failures when the test process exited midway; it runs the suite in 3 serial parts and passes only with the final count of each. Tests the hosted runner does not run are listed in `scripts/ci/ci-skip.txt`, with the reason. Fixed outdated tests (Cursor's `--plugin-dir`, the page title on import) and a fatal error of the fake daemon in `MCPTests`.

## [0.1.7] — 2026-11-19

### Added
- **"Trilho" layout** in the "Completa" structure: a column of paddocks on the left, a context panel with the **agent tree** (the Shepherd and the terminals leashed to it, with a badge for pending cards) and a strip of tabs "Canvas" / "Preferências". In "Completa", Preferences now open **in place of the canvas** (`⌘,`, the palette, the gear and a page requested by another panel), without rebuilding the terminals. The "Compacta" structure is unchanged and still opens the Settings window.
- **Cursor conversation memory:** the session start of a Cursor terminal is recorded, the transcript is read in chunks, and its growth triggers the idle capture.
- **Curator:** no daily cap by default (the cap is now the user's choice).

### Changed
- In "Trilho", the **Pasture** ("Pasto": terminals and panels without a paddock) is no longer a fixed paddock: it shows only while it holds something, when it is the selection, or when there is no paddock; empty and selected, the app moves to the first paddock. "Compacta" keeps the "Pasto" chip.
- The lint baseline for `sleep` in `ConversationCapture.swift` went from 1 to 2: it is the poll for the growth of the Cursor transcript, which has no event to wait for.

### Fixed
- Curator: Claude's sandbox profile lets `dyld` start, keeps the temporary directory inside the profile and allows reading the link it was started by; Claude always gets `USER`, even when capturing the environment fails.
- Memory: a Cursor transcript that appears after `sessionStart` is found by the capture.

## [0.1.6] — 2026-11-19

### Added
- **Loops without a card, per paddock:** the loop card gains "Sempre neste cercado"; after that, loops of that paddock start without a card and the Shepherd only gets a notice. New **"Laços"** page in Preferences, with **"Revogar"**.
- **A more reliable loop:** `collie work run --gate "<cmd>"` runs a gate (lint, build) after each task's check; the loop fails the attempt that rewrites a script the gate runs (except what the task's spec names); it records and shows the **evidence** of each task that passed; it waits for another terminal of the same worktree instead of stopping; it notifies the Shepherd at the end of each task; the status shows what it is doing (agent, check or gate) and the loop's numbers (attempts, reverted commits).
- **Memory that becomes a rule:** a pitfall or a decision can be enforced by a check (`enforcedBy`, `memory enforce`); recurring pitfalls without a check show up as candidates; an enforced item leaves the injection, the TTL and the count of dead memories; if the check disappears, the memory returns to the injection.
- **Feature map** (`docs/feature-map.md`) and the `feature-map` lint rule.
- **CI:** `ci.yml` (lint, architecture, build and tests on PRs and on `main`), `check-architecture.sh` (module boundaries; base modules import neither Cocoa, Carbon, Quartz, PDFKit nor SwiftUI) and a ratchet lint for `sleep`, concurrency escapes and forced casts.

### Fixed
- The loop no longer waits for the Shepherd to be idle before going on.
- `collied` no longer crashes when the terminal goes away during `noteModel`.
- Memory: a check that disappeared does not write an "outdated" mark; only verified pitfalls become candidates.
- The package declares `CollieCore` as a direct dependency of `collie` and `collied`.

## [0.1.5] — 2026-11-18

### Added
- **Curator with a provider of your choice:** new **Cursor** provider (isolated and without tools); in Preferences › "Memória" the user picks the provider, gives consent and tests it.

### Fixed
- Curator: validates the model id; Cursor always runs sandboxed in production; it never follows a link planted in Cursor's home; Cursor's profile runs the real tools and only port 443; it tells a user environment that was not captured from a missing `claude`, and looks for `claude` in known directories when the environment has no `PATH`.

## [0.1.4] — 2026-11-18

### Added
- **Unattended loops:** `collie work run` / `work stop`, the loop engine (a fresh agent per attempt, each task's check decides), a spec and a check per task, an approval card in the app with hard limits, `/collie:loop` for Claude and Cursor terminals, and the loop's state with a stop action in the "Trabalho" panel.
- **Memory measurement:** a precision metric next to coverage, use with evidence (a quote from the turn, `memory.get`, `--useful`), statistics per agent and obedience to `ask`, a provisional TTL per kind, and a session-start index ordered by use, with a ceiling for pinned memories.
- **Memory for Cursor and Codex:** `memory.task` (pulled per task, for agents without a prompt hook), a focused and bounded `sessionStart` for Cursor, the MCP profile and a memory badge on Cursor cards, with a preference and **"Confiar"** in Preferences › "Memória".
- **Map drift:** map memories whose file changed since the anchor are contested, and the curator receives the verified fact.
- **Curator:** providers behind a single interface, its own sandbox profile (deny by default), a pause on bad output, job results, and a provenance ledger outside the memory files; records say who curated them.
- **Network:** the macOS trust bundle goes to `mitmdump` on every start, and the upstream CA respects the user's mitmproxy configuration.

### Security
- The loop never runs a check or `git` without the sandbox, never undoes someone else's work nor outlives its agents, hides secrets in notes, and the approval card shows every task in a way that cannot be forged; one loop per paddock even under concurrent `work run`.
- Injected memory is labelled as data, escaped and cleaned; only memory written by the daemon enters in full or as a user rule; curator verdicts fail closed; a corrupted provenance ledger adopts nothing.
- The daemon's `git` uses neither lazy fetch nor the `ext` transport.

### Fixed
- A child that times out and dies on SIGTERM no longer hangs; a refused `adb root` names the cause; map file reads interrupted by a signal are retried; map anchors are per store, with no back and forth between the Pasture and the worktree.

## [0.1.3] — 2026-11-17

### Changed
- The "not an admin" detection became a single notice, not a red label; the detection label says why and how to fix it, and the sandbox watcher explains why detection is off.

## [0.1.2] — 2026-11-17

### Added
- **Automatic updater:** the daemon checks the release manifest and prepares the dmg, and the app swaps the bundle in a verified way, keeps the previous one and reopens. New **"Atualizações"** page and an install sheet; `app.update` commands (admin).
- The sandbox denies writes to the update sibling; downloads have a byte limit and Collie release paths.
- The Shepherd delegates with `collie summon`, not with its own subagents.
- Commands an older daemon does not know answer "restart the service to use this".

## [0.1.1] — 2026-11-16

### Added
- **Design engine (figcraft) as a downloadable plug-in:** the app and the daemon download, verify and install the engine (version pin and resolution), with `design.engine` commands (admin) and a CLI; the Design panel offers the download; Preferences open on the page the panel asks for.
- Release: notarization with an API key, a polling wait and a forced version.

### Fixed
- CI: tolerates "already exists" when importing the keychain and requires the signing identity.

## [0.1.0] — 2026-11-16

First public version (the project was previously called Orq).

### Added
- **Canvas** with agent terminals (Claude, Codex, Cursor), leashes between them and **paddocks** (git worktrees or folders); full screen per window.
- **Panels:** Browser (driven by the agent), Device (Android via adb/scrcpy, iOS Simulator via AXe), Design, Design Systems, Diagram (draw.io), Preview of HTML pages with comments, Artifacts, Network (local response mapping) and Work.
- **Memory** in three scopes (global, project and lot), injected into the agents' prompt.
- **Herds** (ready-made teams of terminals and panels) and **Lots** (grouping terminals by effort).
- **Sandbox** (Seatbelt) on every terminal, open (default) or strict mode, with access cards.
- **Communication between agents:** `collie ask`/`reply` with a verified sender, `summon`, `wait`.
- **Paddock apps** with approval and events.
- **Preferences** with a sidebar and search (Appearance, Terminal and fonts, Design and sandbox, Memory, Plug-ins, Phone, Android).
- Release signed with Developer ID and notarized (dmg).
