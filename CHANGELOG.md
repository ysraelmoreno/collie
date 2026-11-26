# Changelog

All notable changes to Collie, by version. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow the repository's `v*` tags (each tag publishes a signed and notarized release). Before 1.0, a new feature bumps the minor and a fix-only release bumps the patch (see "Versionamento" in `docs/release.md`); 0.1.0 to 0.1.9 bumped only the patch for every release, features included, and that is not repeated.

Names in quotes are labels of the app, which is in Portuguese.

## [Unreleased]

### Added
- **Fields (preview):** `collie summon --field <name>` gives an agent its own lane worktree inside a paddock; `collie field list|land|drop`. One integrator per paddock lands a field, and `ask --check` that passes lands its field. Fields are configured in `collie-work.json`, and the sandbox of a field is its own. A field that was not judged never lands, and nothing in a field is lost when it is dropped by mistake (review of F3 to F5).
- **Plug-in marketplace, phase 1 (unused until a catalog is published):** a signed catalog (`plugins.json` + Ed25519 signature, sequence number, 30 days before it is stale), install and update of a plug-in from the catalog (SHA-256 of the package and of its tree checked), installed plug-ins keep their source, `.github/workflows/plugins-release.yml` publishes the packages and the catalog, and the app's "Descobrir" tab installs and updates from it. The catalog's public key is in the app (`PluginCatalog.publicKeys`); the private half is the `PLUGIN_CATALOG_KEY` secret. A catalog signed by another key is refused.
- **`collie plugin validate <folder>`:** refuses what an install would refuse (`PluginStore.scan`, manifest, `apiVersion 1`) plus the curated catalog's rules (`permissions.network` empty, the helper a Mach-O signed as `dev.collie.plugin.<id>`). Exit 0 prints `ok` and the `TeamIdentifier`, exit 1 prints one reason per line. The files of the future `collie-plugins` repository (README, `check.yml`, `publish.yml`, the `publishers/` format) are in `docs/superpowers/roadmap/2026-11-24-marketplace/collie-plugins/`.

### Fixed
- **The loop's gate sees a runner rewritten in an ignored folder:** before the first attempt the loop records `node_modules/.bin`, `.venv/bin` and `venv/bin` (name, size, date, link target, never the content); a gate or acceptance that runs a runner that changed or appeared since is refused as tampered, like a tracked file. A spec that cites `npm install`, `pip install` and the like lets installs through.
- **"Cercado fábrica" says why it is disabled:** off a git repository the switch now shows "Precisa de um repositório git." beside it.
- **Cursor Shepherd, delegation:** the brief also reaches the Cursor Shepherd in its `sessionStart` context (no shell or file reads for the task), next to the plugin rule below. Asking it to *delegate* works; "open a terminal and do X" can still make it do X itself.
- **A Cursor Shepherd asked to open a terminal did the work itself:** the orientation teaches `collie summon` but, under its 1500-character cap, never said to hand the task over, so the agent opened the terminal and kept working in parallel. A Cursor Shepherd's plugin now carries an always-applied rule (`rules/collie-delegate.mdc`): after `collie summon`, give the terminal the task with `collie ask <name> "<task>" --no-wait`, wait for its reply, do not do the work or use your own subagents. A plain Cursor terminal gets no rule.

## [0.2.4] — 2026-11-25

### Fixed
- **Memory curator, an environment failure spends no attempt:** when a call fails because the sandbox blocked the CLI, there is no network or name resolution (`getaddrinfo`, `ENOTFOUND`, …) or its workspace folder is gone, or the provider is unavailable, the job waits for the next tick instead of burning one of its 3 attempts and heading for `failed/`. It counts as a bad call, so a provider that never works is paused. A plain failure of the run (bad exit, junk answer, timeout) still spends an attempt.
- **Conversation capture of a folder that is gone:** a `conversation` job whose terminal started in a folder that was later moved or deleted would fall back to the global store (and write the conversation's learnings there). It is now skipped (the mark moves on, so the chunk is not read again) and never fails. A job whose transcript no longer exists already ended `.ok`; a test pins it.
- **Memory curator, `failed/` no longer grows forever:** jobs parked after 3 failed attempts (or unreadable) are deleted after 7 days (`Curator.failedKeep`), at daemon start and whenever another job is parked. The "Curador falhando" alert counted every parked file, so a day of environment failures kept it on for good, even after the curator worked again.

## [0.2.3] — 2026-11-25

### Changed
- **Updates install through Sparkle:** the app checks `appcast.xml` on the release, downloads the dmg, verifies its EdDSA signature and the Apple team, installs (macOS asks for the admin password, or "Install with privilege management", when `/Applications` needs it) and relaunches, with no dmg to download by hand. While an agent is working the relaunch waits for you ("Atualizar mesmo assim" / "Depois"). Local builds (not signed by the team) never update themselves. Preferências › Atualizações now shows "Procurar agora" and the automatic-check switch. `CFBundleVersion` now grows with the tag (0.2.2 is `2002`). The `update.json` is still published so 0.2.x installs reach the first Sparkle version the old way, once.

### Fixed
- **Memory curator with Cursor, name resolution:** every call failed with `getaddrinfo ENOTFOUND api2.cursor.sh`, because the sandbox of the Cursor call did not open the system name resolver (the Claude one did). It does now.

## [0.2.2] — 2026-11-25

### Fixed
- **Memory curator with Cursor:** every call failed with `Workspace directory does not exist: /var/folders/…`. The call runs under a sandbox that allows the real path (`/private/var/…`) but not the `/var` link, so the CLI could not see its own workspace. It now gets the real path.

## [0.2.1] — 2026-11-25

### Fixed
- **"Memória" panel on a fresh install:** the global scope showed `repo '…/Application Support/Collie/memory' does not exist`, because the global store folder is only created by the first write and the daemon refused the path. It is now accepted before the folder exists.

## [0.2.0] — 2026-11-25

> The factory below is a **preview**. The auto-land was validated end to end in a throwaway repository
> (`docs/superpowers/roadmap/2026-11-24-autoland/a7-evidencia/`, scenarios S1 to S10): green landing, red gate, red
> acceptance, queue of two works, daily cap, refusals, a moved base, a stop during the land. Nothing here pushes,
> opens a PR or tags: a land is a local `--no-ff` merge into the base.

### Added
- **Factory for users (preview):** the `factory-init` Shepherd skill (a stack detector and Swift, Node and Python models in `docs/fabrica/modelos/`) builds a project's factory profile; `collie factory doctor` scores its layers (static, judge, verification, review, prose, guardrails) from 0 to 3, read only, and exits 1 below `--min`.
- **Loop with review by personas (preview):** `collie work run --review` has fresh reviewer terminals (personas in `docs/fabrica/personas/`: correção, segurança, testes, simplicidade, motor-concorrência) give each attempt an opinion; a blocker or major finding vetoes, it never approves alone (the check and the gate decide). `--personas`, `--reviewer-model`, `--no-review`; a mute opinion records its cause and is retried once; a prompt that was not delivered (or not submitted) does not spend the attempt; `work task add` takes a per-task agent and model.
- **`collie-work.json` with a `factory` block:** read strictly (an invalid block refuses `work run` in one line) and applied by `work run` from the base commit, never from the agent's tree: `factory.review` (personas, threshold), `factory.guardrails` (`budgetSeconds` and `maxTries` become the defaults of `--budget` and `--tries`; `destructive` and `land` are shown, not enforced; `autoLandPerDay`), `factory.autoland` (`ci`, `timeoutSeconds`). An explicit flag wins over the profile, the profile over the default, and `work status` says which one each value came from. The Collie repository now has its own profile.
- **Doctor, bait, ratchet:** `collie factory bait list|report` (a catalog of known-bad changes in `docs/fabrica/iscas/` and the capture rate per layer and persona) and `collie factory ratchet check|update|raise` (a generic measure whose baseline only goes down; raising needs a written reason).
- **Cercado fábrica:** a persistent mark on a paddock that only the owner sets (`collie paddock create --factory`, `collie paddock factory <name> on|off`, the app's switch and rail badge; never by MCP or an agent terminal); turning it on needs a valid profile with `static` and `judge` at 1 or more.
- **Auto-land (preview):** `collie work run --auto-land` (factory paddock, committed profile with a `gate`, review on). When every task is done the loop checks, in order, the gate on HEAD, a clean review of each task, runtime acceptance, the local CI, a clean tree and an unmoved base, then runs `paddock land` by merge, **locally: never a push or a PR**. Each failure stops with its own `stopReason` and notifies the owner: `landed`, `landGateRed`, `landReviewVeto`, `landCiRed`, `landDirty`, `landConflict`, `landNotFactory`, `landAcceptRed`, `landBaseMoved`, `landNothing`. The land records the base commit before and after, with the line to revert it.
- **Queue and caps:** `--queue` leaves an owner-approved work waiting in the paddock; `--auto-land-max N` (default 1, at most 5) lets one execution land several in turn (`queueEmpty`, `maxReached`); `factory.guardrails.autoLandPerDay` (1 to 20, default 3) caps lands per 24 h from a durable record (`landDailyCap`); the factory doctor must still pass before each next work (`landDoctorRegressed`); `--budget` covers the whole execution.
- **Immutable summary:** every `--auto-land` execution leaves a markdown summary written once in the daemon's own folder (mode 0444, never in the agent's tree, secrets scrubbed): times, `stopReason`, base before/after, who approved and who vetoed (`[persona] file:line`), attempts, the conditions that passed and the one that stopped it, what was not done (no push) and candidate traps repeated across attempts. One end notice carries its path; `work summary` and the app card show it.
- **Runtime acceptance:** `collie work task add --accept <cmd> [--accept-timeout s]` keeps a shell command in the work's state that runs after the check and the gate and judges the running result (exit 0 = accepted); a failure counts as a failed attempt with its output kept; with `--auto-land` it is the `landAcceptRed` condition.
- **PRD entry:** `collie work prd add|show` (an immutable, hashed copy of the PRD and its opaque origin), `collie work plan lint` (refuses, with file and line, tasks with no runnable check, trivial checks, cards over 1500 characters, cycles, no cited test) and `collie work plan apply --approve <sha256>` (creates the tasks by wave once the owner confirms the hash; never starts the loop), plus the `factory-plan` skill. `docs/fabrica/auto-land.md` and `docs/fabrica/aceite-e-entrada.md` describe the flow.
- **Device:** `collie device` got a signed accessibility helper (Android), OCR for `screen`, `find` and `tap --text` (iOS and Android), `ui` compact by default, `screen`, `wait --stable|--settle`, `--then ui|screen`, `find --scroll`, and a device frame in the panel.

### Changed
- `work run` applies the profile's review and guardrails instead of only describing them; a loop review also runs in open mode.
- Review text, notes and notices of a run are scrubbed before they reach the owner; the reviewers' folder is trusted in `~/.claude.json` before the review base is taken.

### Fixed (found by the end-to-end validation)
- `work run` no longer blocks on the "check already passes" pre-check: it runs inside the loop (4 at a time, 120 s each, a timeout counts as red) and `work stop` interrupts it; a cancelled `work run` never leaves the paddock reserved.
- An auto-land that stops without integrating (base moved, red gate, review veto, red CI, daily cap, a `work stop` during the land...) discards the attempt's commits from the paddock into a patch (`git am` to recover) and reopens the tasks they belonged to, so they never ride into another work's land.
- `work stop` during the land kills the CI of the land at once and the journal records the land's gate and CI; `--now` forces a stop; a shell agent in a paddock loop is refused.
- A spent daily cap is refused at `work run`, before any agent or review is paid for.
- The plan linter and `work plan apply` close the bypasses found in review (always-green checks, symlinked `tasks`, unreadable cards).

### Known limits
- A reviewer is a probabilistic veto: it can approve a justified bug (S3). The gate, the CI and the acceptance command are the hard checks.
- A `work stop` in the window between the last attempt and the land leaves the task done with its commit in the paddock (not discarded).
- `factory.guardrails.destructive` is a warning only; it blocks nothing.
- Parallel lanes (`--parallel` over 1) keep a known gap: a commit made after the integration is not re-reviewed.
- Runtime acceptance scripts for `collie device`, a browser or an app service are examples, not a framework.

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
