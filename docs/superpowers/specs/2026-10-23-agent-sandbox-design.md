# Collie — Terminal Sandbox (design)

Date: 2026-10-23. Status: draft for the user's approval.

## Intent

An agent — confused, or manipulated by text in a web page or a repo (prompt injection) — must not be able to:

1. break Collie (its app, daemon, LaunchAgent, data, admin token, access rules: leashes, lots, preferences);
2. touch files outside the project it was opened in;
3. above all, delete something important anywhere else.

Today agents run as the user, so Collie's leashes and lot isolation are coordination guardrails, not a boundary. This makes them a boundary for everything that runs inside a Collie terminal.

## What the user decided

- **Deny by default, reads included.** A terminal sees only its project. Reading Documents, other repos, or the rest of the home is not allowed by default.
- **Writes:** only the terminal's project folder (a paddock terminal: its paddock worktree).
- **Reads:** the project folder plus what tools need to run (system/toolchains, the agent's own state, build/package caches, the temp dir, the files Collie generates for that terminal).
- **Secrets closed:** `~/.ssh` key files, `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.docker/config.json`, browser profiles. Git over SSH keeps working through the ssh-agent socket (`SSH_AUTH_SOCK`) without reading keys.
- **Collie's internals are never writable by agents** — app, daemon, LaunchAgent, data dir, admin token, access rules. Agents reach Collie only through `collie` with their own terminal token; the daemon enforces leashes/lots.
- **Access is the user's explicit decision.** On a blocked access the agent gets the error at once; Collie shows on the terminal's node: "Agente *X* tentou **ler|escrever|apagar** `<path>`" with **Liberar este caminho** / **Liberar a pasta** / **Negar**. An agent can also ask: `collie access request <path> --read|--write --reason "…"`, shown to the user the same way. Nothing is granted without the user's click.
- **After a grant, the terminal restarts** with the wider sandbox, resuming the conversation (Claude `--continue`, Codex resume equivalent); the running process is lost, the conversation isn't. Accepted by the user.
- **Every terminal is sandboxed by default, shells included** (an agent with a leash to a shell could otherwise send it commands). The app's new-terminal sheet offers **"Terminal livre (sem sandbox)"** for the user's own work: only the user, only in the app; agents, `summon` and herds never create one; no leash can reach a free terminal (no ask/inject into it); it shows a clear mark on the canvas.

## Goals

- Write confinement to the project; read confinement to project + tool essentials; secrets and Collie internals closed.
- Visible, explicit, per-terminal (and per-lot) grants, persisted, revocable in the app.
- Works the same for Claude, Codex, Cursor, custom commands and shells (it wraps the whole process tree, not only an agent's shell tool).
- Agents can't escape via the daemon: admin only from the signed app (fix in flight), process signals to Collie blocked.

## Non-goals (now)

- Network restriction (allowed as today; possible later).
- Protecting the user from code they run themselves outside Collie (e.g. a free terminal, Terminal.app).
- Another macOS user account or a VM.

## Anti-goals (failure even if it "works")

- An agent silently gets access to something the user didn't click.
- Tools break so often that the user turns the sandbox off.
- A grant leaks to other terminals/lots the user didn't pick.
- Any escape route left open that makes the boundary decorative (listed below; each must be closed or explicitly accepted).

## Constraints

- macOS 15 (and later). No Apple-special entitlements (Endpoint Security needs one + root — out). The available mechanism is Seatbelt (`sandbox-exec` / SBPL profile), the same one Claude Code and Codex use internally; it's deprecated-but-shipping — record the risk.
- Every terminal starts through `collie-ctty` today; the sandbox wraps there (ctty first, then the sandboxed exec) so SIGWINCH/controlling-terminal behavior is unchanged.
- Leashes remain the only permission between terminals; the sandbox adds file-system confinement, it does not change reach.
- Nothing deleted automatically; UI copy pt-BR in the Collie vocabulary.

## Escape routes the design must close (builder: verify each)

1. **Collie data and token:** deny all of `~/Library/Application Support/Collie` (and the legacy `Orq` symlink) except the files Collie generates for that terminal (its `--settings`/hooks/MCP config) and the daemon socket (connect only).
2. **Process control:** agents can't signal processes outside their sandbox (`kill` the daemon/app), can't `launchctl` the Collie agent, can't write `/Applications/Collie.app` or `~/Library/LaunchAgents`.
3. **Agent config as a backdoor:** the agent's own state dirs are writable (sessions, history, todos, caches), but its config is read-only inside the sandbox — `~/.claude/settings.json`, hooks, `CLAUDE.md`, skills, commands, plugins, MCP config; same for `~/.codex/config.toml` etc. Otherwise an agent plants a hook that runs in the user's unsandboxed sessions.
4. **Shell rc / user config:** `~/.zshrc`, `~/.gitconfig`, `~/.ssh/config` etc. not writable (covered by "writes only in the project", called out for tests).
5. **Git hooks and config in the project:** `.git/hooks/*`, `.git/config` (`core.hooksPath`, `core.fsmonitor`), `.git/info/attributes` filters — writes denied, so the user's own unsandboxed `git` never runs agent-planted code. (Project code itself — `package.json` scripts, Makefile — is the product; running it outside the sandbox is the user's conscious act; documented.)
6. **Free terminals:** never created by agents, never reachable by leashes, never inheritable by herds/summon.
7. **Inner sandboxes:** Seatbelt can't always nest. Claude Code's optional sandbox and Codex's default command sandbox run inside Collie's; if nesting fails, Collie launches them with their inner sandbox off (Collie's outer one enforces) — spike first.

## Detection of blocked accesses

Seatbelt denies synchronously and logs a violation ("Sandbox: <proc>(<pid>) deny(1) file-read-data <path>"). Collie maps the pid to its terminal and raises the prompt. Mechanism to confirm in a spike: unified log stream for sandbox violations of the terminal's process tree (readable without root?), or an SBPL `(with report)`/message variant. Rate-limit and dedupe (an agent hammering a path = one card).

## What is left to the builder

- Exact SBPL profile (base profile: allow default, then deny reads/writes per the rules above; parameters per terminal: project path, worktree, temp, caches, agent kind).
- Tool-essential read list (toolchains, Homebrew, nvm, Xcode, simulator runtime paths, `~/Library/Developer` for iOS work, language caches) — tuned so common workflows (Swift/SwiftPM, Node, Python, Xcode build, iOS Simulator, git) work without prompts; test matrix.
- Grant storage (per terminal, per lot), revocation UI, restart-with-resume per preset (Claude `--continue`; Codex/Cursor equivalents or plain relaunch).
- The device panel/simulator, design engine and browser stay in the app (not sandboxed by this).
- Migration: existing terminals become sandboxed on their next start; an in-app notice explains it once.

## Decisions after the builder check

**User's answers (2026-10-23):**
- **Revised 2026-10-23 (user): `launchctl` and `open` of scripts/executables are closed** — `/bin/launchctl` exec denied; `/usr/bin/open` exec denied inside the sandbox and replaced by an `open` shim that calls `collie open <url|app>`, which the daemon performs outside the sandbox only for http(s)/mailto URLs and `.app` bundles (never scripts, `.command`/`.tool`, executables or documents that would run code); `osascript` and the Docker socket stay open. Residual: an agent's own program calling LaunchServices/launchd APIs directly (not via these binaries). **Both denies match the binary's path only** (R14): a copy of `launchctl`/`open` runs, so they are defence in depth, not a boundary (same class as `osascript`).
- **(original answer) System-service escapes stay open, as an accepted risk.** `open`/LaunchServices, `osascript`/Apple Events, `launchctl submit`, the Docker socket keep working inside the sandbox (browser logins, `open -a Simulator`, Docker). README states plainly that a deliberately malicious agent can run code outside the sandbox through them. (Exception, from the rules above: `launchctl` against Collie's own job is still blocked if the profile can target it without breaking the rest; otherwise also accepted.)
- **Agent config inside the project is writable**: `.claude/settings.json`, `.mcp.json`, `.codex/`, `.cursor/`, `.envrc`, `.vscode/*` — accepted risk of a planted project hook. **Global agent config stays read-only** (`~/.claude/settings.json`, hooks, skills, commands, plugins, `CLAUDE.md`, `~/.codex/config.toml`): a write there raises the normal grant card (Liberar/Negar), since it would affect the user's sessions outside Collie. **Revised 2026-10-24 (user, R13): `~/.claude.json` is writable** (Claude rewrites it on every start) — accepted risk: an agent can plant a global MCP server that the user's unsandboxed Claude runs.
- **Accepted (R16):** shared caches are writable (`~/.npm`, `~/.cache`, `~/.cargo/registry`, `go/pkg`, DerivedData): they hold code the user's unsandboxed tools run (`~/.npm/_npx`, `~/.cache/pre-commit` envs), so a write there is code execution outside the sandbox, not only cache poisoning. `~/.claude/projects` (sessions, memory) is writable agent state that a free terminal's Claude also reads, so text from a sandboxed agent can reach a free terminal's prompt. Reads outside `~` and `/private/tmp` stay open.

**Calls I made (the user can override):**
- **Admin-only-from-the-signed-app is a prerequisite** (fix in flight, merged before this work); the daemon trusts only the app to create a free terminal or change grants.
- **A terminal's project** = the git toplevel of the cwd the user picked in the app (or the paddock's worktree for a paddock terminal); for a non-git folder, that folder. Agent-summoned terminals and herd terminals may only get a cwd inside the summoner's/applier's project; the daemon refuses other paths (no confused deputy). Same check for every agent-supplied path the daemon acts on.
- **Paddocks:** a pasture terminal does not get write access to paddock worktrees (separate efforts); a paddock terminal may write its worktree and the main repo's `.git` objects/refs/`worktrees/<name>` (needed to commit), but never `.git/hooks`, `.git/config` or `.git/info/attributes` (those still run in the user's unsandboxed git — kept denied, distinct from agent-tool config).
- **Keychain (revised 2026-10-24, user, R12):** `/usr/bin/security` runs inside the sandbox and `~/Library/Keychains` is writable, so Claude keeps its Keychain login and tokens refresh. Accepted risk: any agent can silently read keychain items stored through the `security` CLI (gh and similar); the framework is reachable from any process anyway.
- **Grant scope:** per terminal by default; the card also offers "para o lote" (current and future members of that lot, shown in the lot view). Summoned/herd terminals don't inherit the summoner's terminal-level grants (they prompt again); lot-level grants apply to them if they join the lot.
- **No private SPI:** widening needs the restart-with-resume the user accepted (no `sandbox_extension_*`).
