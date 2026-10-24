# Plan 4S — Terminal Sandbox

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Collie terminal (agents and shells) runs confined to its project: writes only there, reads only there plus tool essentials, Collie internals and secrets closed; blocked accesses become explicit user grants; free terminals only from the app.

**Architecture:** `collie-ctty` (already the first exec of every terminal) takes the controlling terminal, then execs `/usr/bin/sandbox-exec -f <profile>` with a per-terminal SBPL profile the daemon renders (`SandboxProfile`). The daemon resolves each terminal's project root, refuses agent-supplied paths outside it, watches sandbox violations of its terminals' process trees, and turns them (and `collie access request`) into grant cards; a grant re-renders the profile and restarts the terminal with resume.

**Tech Stack:** Swift 6.2, SwiftPM, Seatbelt (`sandbox-exec`, SBPL), unified log, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-10-23-agent-sandbox-design.md` (commit 079806f), including "Decisions after the builder check".

**Prerequisite:** the admin-token fix (branch `fix/admin-token-agents`: admin refused from inside terminals + admin only from the signed app) is merged to main before Task 2.

## Global Constraints

- Writes only in the terminal's project (paddock terminal: its worktree + the main repo's `.git` objects/refs/`worktrees/<name>`); never `.git/hooks`, `.git/config`, `.git/info/attributes`; a pasture terminal never writes paddock worktrees.
- Reads: project + tool essentials (system, toolchains, Homebrew, nvm, Xcode, `~/Library/Developer`, caches, temp, the agent's own state/config, the files Collie generates for that terminal). Denied by default: the rest of `~`, Documents, other repos.
- Secrets closed: `~/.ssh` key files (`id_*`, other private keys; `known_hosts`/`config` readable), `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.docker/config.json`, browser profiles; exec of `/usr/bin/security` denied. `SSH_AUTH_SOCK` usable.
- Collie internals never writable: app bundle, `~/Library/Application Support/Collie` (and the `Orq` symlink) except that terminal's generated files (read) and the daemon socket (connect), `~/Library/LaunchAgents/dev.collie.daemon.plist`; no signals to processes outside the terminal's sandbox.
- Global agent config read-only (`~/.claude/settings.json`, `~/.claude/hooks`, skills, commands, plugins, `~/.claude/CLAUDE.md`, `~/.claude.json`, `~/.codex/config.toml`); agent state dirs writable (`~/.claude/projects`, todos, shell-snapshots, statsig, session files; `~/.codex/sessions`, logs). Project agent config writable (user decision).
- `launchctl` closed (exec of `/bin/launchctl` denied); `open` of scripts/executables closed: `/usr/bin/open` exec denied, an `open` PATH shim calls `collie open <url|app>` which the daemon performs only for http(s)/mailto URLs and `.app` bundles (user decision, revised). `osascript` and the Docker socket stay open — accepted risk, documented.
- Grants: explicit user click only; per terminal by default, optional "para o lote"; persisted; summoned/herd terminals don't inherit terminal-level grants. Widening = restart with resume (no private SPI).
- Free terminal ("Terminal livre (sem sandbox)"): created only by the app; never by agents, `summon` or herds; no leash may reach it; marked on the canvas.
- Leashes stay the only permission; no change to reach. Nothing deleted automatically. UI copy pt-BR in the Collie vocabulary. Never launch the real app or real agents in tests; tests use temp dirs and `sandbox-exec` with small probe commands.

## Review Focus

1. A Swift/SwiftPM build, `npm install`, `git commit`, Xcode `xcodebuild` + iOS Simulator inside a sandboxed terminal run without any denial (tools-break anti-goal).
2. An agent summons a terminal with `--cwd ~` or `/`: refused; the new terminal can't get a wider project than the summoner's.
3. Daemon restart with running sandboxed terminals: reattach keeps them sandboxed; grants survive; free terminals stay free and unleashable.
4. A denial storm (agent loops over 10 000 paths): one card per (terminal, op, folder), daemon stays responsive, log watcher bounded.
5. Paths with spaces, unicode and symlinks (`/tmp` → `/private/tmp`, the `Orq` → `Collie` symlink, a project that is itself a symlink): rules apply to the resolved path; no bypass through a symlink inside the project pointing outside.

---

### Task 1: Spike (gate)

**Files:** Create `docs/superpowers/spikes/2026-10-23-sandbox/REPORT.md`, `docs/superpowers/spikes/2026-10-23-sandbox/probe.sb` (scratch profile), scripts under the same folder. No product code.

- [ ] **Step 1:** With a hand-written SBPL profile (`(version 1) (allow default)` + targeted denies), verify on this Mac (macOS 15) using probe commands in temp dirs: deny/allow of `file-read*` / `file-write*` by `subpath`/`literal`/`regex` with parameters (`(param "PROJECT")`); `(deny process-exec (literal "/usr/bin/security"))`; `(deny signal (target others))` vs `(allow signal (target same-sandbox))`; `network-outbound` to a Unix socket path allowed while the containing dir is read-denied.
- [ ] **Step 2:** `collie-ctty` → `sandbox-exec -f probe.sb /bin/zsh -lc …`: controlling terminal kept (`ps -o tty=`), SIGWINCH delivered (reuse the `ControllingTerminalTests` approach in a scratch harness).
- [ ] **Step 3:** Nesting: inside the outer sandbox, does `sandbox-exec` (as Claude Code's optional sandbox and Codex's command sandbox use) work, fail, or degrade? Record exact errors. If it fails: the flags to turn each agent's inner sandbox off (Claude settings `sandbox.enabled false`; Codex `--sandbox danger-full-access` / `-c sandbox_mode=…`) — read their docs/help only, no sessions (R1 of earlier plans).
- [ ] **Step 4:** Detection: can a normal-user process see the kernel's sandbox violation messages for a given pid tree (`log stream --style ndjson --predicate 'sender == "Sandbox"'` or the right predicate), latency, and fields (pid, operation, path)? Alternatives if not (SBPL `(with report)` / `(with message)`).
- [ ] **Step 5:** Tool matrix under the draft profile: `swift build`, `npm i` (nvm node), `python3 -m venv`, `git commit` (also from a worktree whose `.git` is a file), `xcodebuild -scheme … build` of a tiny project, `xcrun simctl list` — record every denial and the read/write paths needed.
- [ ] **Step 6:** REPORT.md: results table, the profile shape that passed, nesting decision, detection mechanism, and the essential-path list Task 3 must encode. Commit `docs: sandbox spike`. **Gate:** if detection (Step 4) has no workable mechanism, stop and report — Task 4's flow changes.

### Task 2: Project roots, free terminals, path checks

**Files:** Modify `Sources/CollieCore/Workspace.swift` (`TerminalRecord.sandbox: TerminalSandbox`, `projectRoot: String?`), `Sources/CollieDaemonKit/CommandRouter.swift` (spawn/summon/herd paths), `ShepherdCommands.swift` (summon), `Herds/HerdApplier.swift`, `ConnectionGraph.swift` (free terminals unreachable), `Sources/CollieProtocol/Commands.swift`, `Sources/CollieApp/TerminalSheet.swift` (Terminal livre toggle + mark). Test: `Tests/CollieDaemonKitTests/SandboxRootsTests.swift`.

**Interfaces:**
- Produces: `public enum TerminalSandbox: String, Codable, Sendable { case sandboxed, free }` (decode unknown/missing → `.sandboxed`); `ProjectRoot.resolve(cwd: String, paddock: Paddock?) -> URL` (git toplevel via `git rev-parse --show-toplevel`, else the folder; paddock → its worktree; symlinks resolved); `ProjectRoot.contains(_ path: String, root: URL) -> Bool` (resolved, prefix on path components).
- [ ] **Step 1: Tests** `defaultIsSandboxed` (old workspace.json without the field), `projectRootIsGitToplevel`, `paddockRootIsWorktree`, `summonCwdOutsideProjectRefused` (`~`, `/`, a sibling repo, a symlink inside the project pointing out → refused, message names `--cwd`), `herdCwdOutsideProjectRefused`, `freeOnlyFromApp` (Shepherd `summon --free` / any agent → refused), `leashToFreeRefused` (`collie leash` and ask/inject to a free terminal → `notConnected`), `freeSurvivesRestart`.
- [ ] **Step 2:** Implement; `admin.spawn` from the app accepts `sandbox: free`; every other creation path forces `.sandboxed` and a cwd within the creator's project. App sheet: toggle "Terminal livre (sem sandbox)" with a one-line warning; canvas node shows a "livre" badge (CollieTheme danger tint).
- [ ] **Step 3:** `swift test` → PASS. Commit `feat(sandbox): project roots, free terminals, path checks`.

### Task 3: Profile rendering + launch

**Files:** Create `Sources/CollieDaemonKit/Sandbox/OpenCommand.swift` (`open` shim target: `collie open` → daemon validates URL scheme / `.app` bundle and opens it outside the sandbox; scripts, executables, `.command`/`.tool`, documents → refused), `Sources/CollieDaemonKit/Sandbox/SandboxProfile.swift`, `Sources/CollieDaemonKit/Sandbox/EssentialPaths.swift`; modify `Sources/collie-ctty/main.swift` (optional `--sandbox <profile-path>` before the command), `TerminalRegistry.swift` / `CommandRouter.swift` (render to `<root>/sandbox/<terminal-id>.sb` 0600, pass to ctty), `AgentLaunch.swift` (inner-sandbox flags per Task 1). Test: `Tests/CollieDaemonKitTests/SandboxProfileTests.swift` (renders + runs probes through `sandbox-exec`).

**Interfaces:**
- Consumes: `ProjectRoot` (Task 2), Task 1's essential-path list and nesting decision.
- Produces: `SandboxProfile.render(_ input: SandboxInput) -> String` with `struct SandboxInput { project: URL; mainGitDir: URL?; paddockWorktrees: [URL] /* denied for pasture */; home: URL; collieRoot: URL; ownFiles: [URL]; socket: URL; agent: Preset; grants: [SandboxGrant] }`; `struct SandboxGrant: Codable, Sendable, Equatable { path: String; access: Access /* read|write */; scope: Scope /* terminal|lot */; createdAt: Date }`.
- [ ] **Step 1: Tests** (each runs a probe under the rendered profile in temp dirs): `writesProjectOnly`, `readsDeniedOutsideProject` (a fake `~/Documents/x`), `secretsDenied` (`~/.ssh/id_ed25519`, `~/.aws/credentials`; `known_hosts` readable), `collieDataDenied` (except `ownFiles`; socket connect OK), `gitHooksAndConfigDenied`, `pastureCantWritePaddockWorktree`, `paddockCanCommit` (worktree + main `.git/objects`), `globalAgentConfigReadOnly` + `agentStateWritable`, `projectAgentConfigWritable`, `securityExecDenied`, `signalOthersDenied`, `grantReadOpensPath`, `grantWriteOpensPath`, `pathsWithSpacesAndUnicode`, `symlinkOutOfProjectDenied` (Review Focus 5), `toolEssentialsReadable` (`/usr/bin`, `/opt/homebrew`, `~/.nvm`, `/Applications/Xcode.app`).
- [ ] **Step 2:** Implement: profile = `(version 1) (allow default)` + deny rules + allow-backs, every path SBPL-escaped and passed as `(param …)`; ctty `--sandbox p` → TIOCSCTTY then `execv("/usr/bin/sandbox-exec", ["-f", p, cmd…])`; a free terminal skips it. Existing terminals become sandboxed on their next start.
- [ ] **Step 3:** Review Focus 1: add a gated integration test (`COLLIE_SANDBOX_TOOLCHAIN_TESTS=1`) running Task 1's tool matrix under the real profile; document how to run it.
- [ ] **Step 4:** `swift test` → PASS. Commit `feat(sandbox): per-terminal Seatbelt profile`.

### Task 4: Denials, requests, grants, restart with resume

**Files:** Create `Sources/CollieDaemonKit/Sandbox/SandboxWatcher.swift` (Task 1's detection mechanism), `Sources/CollieDaemonKit/Sandbox/SandboxGrants.swift` (store `<root>/sandbox/grants.json` 0600, defensive decode), `Sources/CollieDaemonKit/SandboxCommands.swift`; modify `Commands.swift` (`access.request`, `access.list`, `access.grant`/`deny`/`revoke` admin-only), `WorkspaceEvent` (`.sandboxDenied(SandboxDenial)`), app: card on the terminal node + list in the lot view, restart-with-resume per preset. Test: `Tests/CollieDaemonKitTests/SandboxGrantTests.swift`.

**Interfaces:**
- Produces: `struct SandboxDenial: Codable, Sendable { terminal: UUID; op: String /* read|write|delete|exec */; path: String; count: Int; at: Date; requested: Bool; reason: String? }`; CLI `collie access request <path> --read|--write [--reason R]` (from the terminal; → card), `collie access list` (own grants).
- [ ] **Step 1: Tests** `denialRaisesOneCardPerFolder` (Review Focus 4: 10 000 denials → ≤ one card per (terminal, op, folder), bounded memory), `requestRaisesCard` (reason shown, scrubbed of secrets), `onlyAppGrants` (agent `access.grant` → `notShepherd`/unauthorized; admin from the app ok), `grantRerendersAndRestarts` (profile file contains the path; the terminal restarts with Claude `--continue`), `lotGrantAppliesToLaterMembers`, `summonedDoesNotInheritTerminalGrants`, `revokeNarrows`, `grantsSurviveRestart` (Review Focus 3), `denialForUnknownPidIgnored`.
- [ ] **Step 2:** Implement; card copy: "Agente *<nome>* tentou **<ler|escrever|apagar|executar>** `<caminho>`" with **Liberar este caminho**, **Liberar a pasta**, **Negar**, and a "para o lote" checkbox; restart = existing relaunch path with resume args (Claude `--continue`; Codex/Cursor per Task 1 or plain relaunch, said in the card).
- [ ] **Step 3:** `swift test` → PASS. Commit `feat(sandbox): access cards and grants`.

### Task 5: Docs, notice, checklist

**Files:** Modify `README.md` (section "Sandbox dos terminais": what is closed, what stays open and why, free terminals, grants, the residual risks: system-service escapes, project agent config, agent replacing the app + daemon restart), first-run notice in the app (once), `docs/superpowers/plans/…roadmap` line; create `.superpowers/checklists/plan4s-sandbox.md` (git-ignored).

- [ ] **Step 1:** README + notice copy (pt-BR, Collie vocabulary).
- [ ] **Step 2:** Checklist: real Claude/Codex terminal under the sandbox doing a build, a git commit, an iOS Simulator run; an attempted read of `~/Documents` → card → Liberar → restart resumes; free terminal; daemon restart keeps everything.
- [ ] **Step 3:** Commit `docs: terminal sandbox`.
