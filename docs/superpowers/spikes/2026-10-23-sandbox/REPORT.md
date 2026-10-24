# Spike: terminal sandbox (plan 4S, Task 1)

macOS 15.6.1 (24G90), Xcode 26.3, Swift 6.2.4, nvm node 24.14.1 / npm 11.11.0, system python3 3.9. Everything ran as the normal
user, offline, against a **fake home** in a temp dir (R2). No real agent sessions (R1). The only real paths exercised are
system/toolchain reads (`/Applications/Xcode.app`, `/usr`, `~/.nvm` node binaries) and simulator listing (`simctl list`).

**Gate: PASS.** A workable detection mechanism exists (Step 4): the unified log, readable without root, plus a per-terminal
`(with message "collie-term:<id>")` tag on every deny rule.

## Files

| File | What |
|---|---|
| `probe.sb` | The draft per-terminal profile that passed the matrix (shape for Task 3) |
| `primitives.sh` | Step 1/3/4 primitive checks with inline profiles (params, regex, signals, setuid, nesting, message tag, no-log) |
| `setup.sh` / `sockserver.py` | Temp root: fake home with fake secrets, stand-in Collie dir + daemon socket, throwaway projects |
| `sbrun.sh` | Runs a command under `probe.sb` with the fake home and prints the tagged denials from the log |
| `escapes.sh` | Escape-route checks run inside the sandbox |
| `matrix.sh` | Step 5: escapes + tool matrix end to end (`zsh -f matrix.sh`) |
| `pty_harness.py` / `ctrlc.py` | Step 2: `collie-ctty → sandbox-exec → zsh` on a fresh setsid'ed PTY (tty, SIGWINCH, ^C) |

## Results

| # | Check | Result |
|---|---|---|
| 1 | `file-read*`/`file-write*` deny/allow by `subpath`/`literal`/`regex` with `(param …)`, `string-append`, `define` | Works. Last matching rule wins, so "deny tree, re-allow subtrees, re-deny secrets" layers cleanly |
| 1 | Path in a rule written as `/tmp/...` | **Never matches**: rules see the resolved vnode path (`/private/tmp/...`). Every param must be `realpath`'d. Symlinked project, spaces, unicode: match on the resolved path; a symlink or hard link inside the project to a denied file is denied (`forbidden-link-priv`) |
| 1 | `(deny process-exec (literal "/usr/bin/security"))` | Works (`operation not permitted`, logged as `process-exec*`) |
| 1 | `(deny signal (target others))` | **Does not deny**: outside processes still get signals |
| 1 | `(deny signal) (allow signal (target same-sandbox))` | Works: outside pid denied (logged `signal pgrp [sleep(pid)] signum:19`), own children and self OK; `kill -0` outside also denied |
| 1 | `network-outbound` to the daemon socket while its dir is read-denied | Works: `(deny file-read* (subpath COLLIE))` + `(deny network-outbound (remote unix-socket (subpath COLLIE)))` + `(allow network-outbound (remote unix-socket (path-literal SOCK)))` → daemon.sock connects; other.sock, `admin-token`, `ls` of the dir denied |
| 1 | **setuid binaries** | **Any** sandboxed process fails to exec a setuid binary (even under bare `(allow default)`): `/bin/ps`, `top`, `sudo`, `su`, `login`, `crontab`, `at*`, `quota`, `newgrp`, `traceroute*`. `(allow process-exec (literal "/bin/ps") (with no-sandbox))` makes `ps` work (it runs outside the sandbox; SIP protects the binary and it execs nothing). Recommend only `ps` (agents use it); `sudo`/`top` etc. stay broken |
| 2 | `collie-ctty → sandbox-exec -f probe.sb … /bin/zsh` on a setsid'ed PTY | Controlling tty kept (`ps -o tty=` → `ttys110`), resize delivers SIGWINCH (`winch 38 127`), ^C reaches the fg job (`after-sleep-rc=130`). `sandbox-exec` applies the profile and `execvp`s in the same pid, so session/ctty survive. No change needed in `collie-ctty` |
| 3 | `sandbox-exec` inside the sandbox | **Fails**: `sandbox-exec: sandbox_apply: Operation not permitted` (exit 71), whatever the outer profile. `(allow process-exec (literal "/usr/bin/sandbox-exec") (with no-sandbox))` "fixes" it but is a full escape (the agent picks the inner profile): rejected |
| 3 | Consequence for toolchains | `swift build` fails the same way (SwiftPM sandboxes manifest compilation); `--disable-sandbox` fixes it (no env var exists; checked the binary's strings). `xcodebuild` on a package fails in "Resolve Package Graph"; `-IDEPackageSupportDisableManifestSandbox=YES` (and `-IDEPackageSupportDisablePluginExecutionSandbox=YES` for plugins) as xcodebuild arguments fixes it. Not tested: Xcode `ENABLE_USER_SCRIPT_SANDBOXING` script phases (likely the same failure; override `ENABLE_USER_SCRIPT_SANDBOXING=NO`) |
| 4 | Violation messages visible to a normal user | Yes: `/usr/bin/log stream --style ndjson --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "collie-term:"'` (no root). Use `/usr/bin/log` (zsh has a `log` builtin) |
| 4 | Fields | `eventMessage` = `Sandbox: <proc>(<pid>) deny(1) <operation> <path>` + `\n<message tag>`; JSON `processID` is 0 (kernel sender), the pid is only in the text. Ops seen: `file-read-data`, `file-read-metadata`, `file-write-create/-data/-unlink`, `network-outbound <path>`, `process-exec* <path>`, `signal pgrp [proc(pid)] signum:N`, `forbidden-link-priv<file-read*> <src> <dst>` |
| 4 | `(with message "collie-term:<id>")` | Works on deny rules; the tag rides along in `eventMessage` (also on "N duplicate reports for …" lines). **This is the mapping**: no pid→terminal lookup, which would race with short-lived pids (`cat` is gone before its line arrives) |
| 4 | `(with report)` | Only valid on allow rules (`report modifier does not apply to deny action`); not needed |
| 4 | `(with no-log)` | Works: silent deny, no line. Use for known-benign probes (listing `~`, `~/Library`) so they raise no card |
| 4 | Latency | ~20 ms from the denied call to the line on the stream. `log stream` takes ~1–2 s to start: the daemon keeps one stream running before terminals start |
| 4 | Storm | Same path ×500 in one process → 1 line + a later "499 duplicate reports" line (kernel dedupe). 2000 distinct existing paths in 0.1 s → 1944 lines (~3% dropped). Watcher must dedupe per (terminal, op, folder) and tolerate drops; the deny itself is always enforced |
| 4 | Non-existent paths | Opening a missing file under a denied tree returns ENOENT and logs **nothing** (existence leaks via ENOENT vs EPERM; metadata is allowed anyway) |
| 5 | Escape routes (`escapes.sh`) | All 35 as expected after two profile fixes (below): secrets, `~` listing, Documents, shell rc / `~/.gitconfig` writes, `.git/hooks` create/rm/rename/symlink swap, `.git/config` write and lock-file rename (`git config`), `.git/info/attributes`, renaming `.git`, Collie dir/token/other socket, `security`, signal outside, symlink/hard link to a secret. `osascript` stays open (accepted risk) |
| 5 | `swift build` | Fails (nesting) → passes with `--disable-sandbox`; only denial: create `~/.swiftpm` (build still succeeds) |
| 5 | `npm i` (local tarball, `--offline`; nvm node) | Passes, no denials (cache in `~/.npm`) |
| 5 | `python3 -m venv` + pip | Passes, no denials |
| 5 | git: `commit`/`gc`/`branch`/`tag` in a repo; `add`/`commit`/`fetch`/`rebase` in a worktree (`.git` is a file) | Pass, no denials (GITCOMMON = main repo `.git`) |
| 5 | `xcodebuild -scheme Hello build` (macOS, SwiftPM package; default and custom DerivedData) | Passes with the manifest-sandbox flag; benign denials: read of `~` and `~/Library` listings, create `~/.swiftpm` |
| 5 | `xcodebuild … -destination 'generic/platform=iOS Simulator'` | Fails "iOS 26.2 is not installed", caused by the **fake home**, not the sandbox (same failure unsandboxed with the fake home; passes under an allow-default sandbox with the real home). Xcode reads platform state from the real `~/Library`; see the essential list, verify on the user checklist |
| 5 | `xcrun simctl list` | Passes, no denials (CoreSimulatorService works over XPC) |

### Profile fixes found by the escape checks

1. **Writes: re-deny `~` after the temp allows.** With the project under `~` (the real case) the order must be: deny all writes → allow temp/cache/devices → deny `(subpath HOME)` → allow project + home caches → deny git internals. (Found because the fake home under `/private/tmp` was writable through the temp allow.)
2. **Git pointers.** With only hooks/config/attributes denied, an agent could still `mv .git .gitold` (then build a new `.git` with a planted `core.hooksPath`), rewrite a worktree's `.git` file (`gitdir: /evil`), or rewrite `.git/worktrees/<name>/commondir`; each makes the user's own unsandboxed git load a planted config. Now denied: `(literal GITCOMMON)`, `(literal PROJECT/.git)`, `worktrees/[^/]+/(commondir|gitdir|config.worktree)`.

## Profile shape that passed

See `probe.sb`. Params: `HOME`, `PROJECT`, `GITCOMMON` (main repo `.git`; `PROJECT/.git` for a plain repo), `TMP`/`CACHE`
(`getconf DARWIN_USER_TEMP_DIR`/`DARWIN_USER_CACHE_DIR`, resolved), `COLLIE` (support dir), `SOCK` (daemon socket), `TAG`
(`collie-term:<terminal id>`).

```
(allow default)
reads:  deny (subpath HOME) [tagged] → allow file-read-metadata (subpath HOME) → allow essentials + PROJECT + GITCOMMON
        → deny secrets [tagged]
writes: deny all [tagged] → allow /private/tmp, TMP, CACHE, /dev/{null,zero,tty,ttysN,fd/*,dtracehelper}
        → deny (subpath HOME) [tagged] → allow PROJECT, GITCOMMON/{objects,refs,logs,worktrees,packed-refs}, home caches
        → deny GITCOMMON (literal), PROJECT/.git (literal), hooks, config, info/attributes, worktree pointers [tagged]
collie: deny read (subpath COLLIE), deny unix connect in COLLIE, allow connect (path-literal SOCK)
procs:  deny exec /usr/bin/security [tagged]; allow exec /bin/ps (with no-sandbox); deny signal [tagged]; allow signal same-sandbox
```

Notes for Task 3:
- Every path param must be resolved (`realpath`). `HOME`/`GITCOMMON` go into regexes → regex-escape them (`.`, `+`, `(` …). `-D` values need no SBPL quoting; inlined strings would.
- The spike allowed all of `GITCOMMON/worktrees`; a paddock terminal should get only `worktrees/<name>`.
- `TMP`/`CACHE` are the user's whole per-user temp/cache dirs (other apps' caches live in `CACHE`); accepted for the spike.
- Collie's generated files for the terminal (settings/hooks/MCP config) need a read allow placed after the COLLIE deny.
- Tag every deny that should raise a card; `(with no-log)` for benign probes (`(literal HOME)`, `(literal HOME/Library)`).

## Nesting decision

Seatbelt does not nest: every inner `sandbox-exec`/`sandbox_init` in a Collie terminal fails. So:

- **Claude Code**: sandbox off via `{"sandbox": {"enabled": false}}` in the `--settings` JSON Collie already generates (CLI `--settings` outranks user/project settings; off by default, this pins it). From `claude --help` + docs only.
- **Codex**: `--sandbox danger-full-access` (`-s`), or `-c sandbox_mode="danger-full-access"`; keep the user's approval policy. Codex isn't installed on this Mac: flags from its docs, confirm on the user checklist.
- **Cursor agent**: `cursor-agent --sandbox disabled` (from `--help`: "Explicitly enable or disable sandbox mode (overrides config)").
- **Toolchains that sandbox themselves** (no preset flag reaches them): `swift build/test/run` need `--disable-sandbox`; `xcodebuild` needs `-IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES` for packages. No env var. Options, cheapest first: (a) a per-terminal PATH dir with `swift`/`xcodebuild` shims adding the flags (the outer sandbox still enforces); (b) a line in the agent's generated instructions; (c) `defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`, rejected: it changes the user's unsandboxed Xcode too. Recommend (a). Without it every SwiftPM/Xcode-package build in a sandboxed terminal fails (tools-break anti-goal).

## Detection mechanism (for Task 4)

One `/usr/bin/log stream --style ndjson --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "collie-term:"'` child of
the daemon (normal user), started before any terminal, restarted if it dies. Parse `eventMessage`: line 1
`Sandbox: <proc>(<pid>) deny(1) <op> <path…>` (or `N duplicate report(s) for …`), line 2 the tag → terminal id. Dedupe per
(terminal, op, folder), rate-limit, bounded queue. Expect ~20 ms latency, kernel dedupe of repeats, a few % dropped in storms,
nothing for missing paths.

## Essential-path list (Task 3 must encode)

Reads (outside `~` everything stays allowed by `(allow default)`: `/usr`, `/bin`, `/System`, `/Library`, `/Applications/Xcode.app`,
`/opt/homebrew`, `/private/var/folders`):
- `PROJECT`, `GITCOMMON`; Collie's generated files for that terminal; `file-read-metadata` on all of `~`.
- Shell: `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zlogin` (+ oh-my-zsh etc. if present), `~/.CFUserTextEncoding`, `~/Library/Preferences/.GlobalPreferences.plist`.
- Git/SSH: `~/.gitconfig`, `~/.config/git`, `~/.ssh` (dir), `~/.ssh/known_hosts`, `~/.ssh/config`; `SSH_AUTH_SOCK` needs no rule (launchd socket outside `~`).
- Node: `~/.nvm`, `~/.npm`, `~/.npmrc`. Python: `~/.cache` (pip), `~/.pyenv`. If present: `~/.cargo`, `~/.rustup`, `~/.rbenv`, `~/.gem`, `~/go`.
- Swift/Xcode: `~/.swiftpm`, `~/Library/org.swift.swiftpm`, `~/Library/Caches`, `~/Library/Developer`, `~/Library/Preferences/com.apple.dt.Xcode.plist` (+ `com.apple.dt.*`). The fake-home iOS-destination failure says Xcode reads real-home state; exact file unverified (R2).
- Agents (binaries + state/config, read): `~/.local/bin`, `~/.local/share/claude` (the claude binary lives there), `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.cursor`, `~/.config/cursor` if present.

Writes: `PROJECT`; paddock: `GITCOMMON/objects`, `refs`, `logs`, `packed-refs`, `worktrees/<name>` (minus `commondir`/`gitdir`/`config.worktree`);
`/private/tmp`, `TMP`, `CACHE`; `/dev/null`, `/dev/zero`, `/dev/tty`, `/dev/ttys*`, `/dev/fd/*`, `/dev/dtracehelper`;
`~/.npm`, `~/.cache`, `~/Library/Caches`, `~/Library/Developer` (DerivedData, CoreSimulator), `~/Library/org.swift.swiftpm`,
`~/.swiftpm` except `~/.swiftpm/configuration` (mirrors/registries would redirect the user's own builds); agent state dirs per
the spec (`~/.claude/projects`, todos, shell-snapshots, statsig, session files; `~/.codex/sessions`, logs).

Denied explicitly (tagged): `~/.ssh/id_*` (and other private keys), `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.docker/config.json`,
browser profiles; `/usr/bin/security` exec; signals outside the sandbox; the Collie dir except generated files + socket;
global agent config writes; git hooks/config/attributes/pointers.

## Limits of this spike

- Real-home reads weren't exercised (R2): with the fake home, tools showed only what they look for under `$HOME`/`CFFIXED_USER_HOME`; frameworks resolving the home via `getpwuid` still read the real one (not denied here). The real-`~` list above is from these runs plus knowledge; Task 3's gated toolchain test / the user checklist must confirm.
- No network: `npm i` used a local tarball; registry installs and `git fetch` over ssh (`SSH_AUTH_SOCK`) not exercised.
- No real Claude/Codex/Cursor sessions; no simulator boot; no iOS app build (blocked by the fake home, above).
