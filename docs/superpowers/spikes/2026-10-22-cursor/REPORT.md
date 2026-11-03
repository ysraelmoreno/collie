# Spike: what the installed `cursor-agent` offers (plan 3E, Task 1)

Date: 2026-10-22. Steps 1, 2 and 4 were done offline. Step 3 (a live session) is still open; it is for the user to run.

Method: `--version`/`--help` ran under `sandbox-exec` with all outbound IP traffic denied, so the CLI could not reach the network. Everything else is read-only `grep`/`dd` over the installed JS bundle. No session was started, no prompt was sent and no `login` was run. Nothing was written to `~/.cursor` or to any `.cursor/` folder.

Bundle root, written `$V` below: `~/.local/share/cursor-agent/versions/2026.10.19-6bbf2c4/`. Offsets are byte offsets (`grep -ob`) into the named chunk, and they are only valid for this version.

## 1. Binary

| Item | Value |
|---|---|
| Names on PATH | `~/.local/bin/cursor-agent` and `~/.local/bin/agent` |
| Same binary? | Yes. Both are symlinks to `$V/cursor-agent`. |
| What it is | A bash launcher. It sets `CURSOR_INVOKED_AS=$(basename $0)` and `NODE_COMPILE_CACHE=~/Library/Caches/cursor-compile-cache`, then runs `exec "$V/node" --use-system-ca "$V/index.js" "$@"`. The UI is Ink (React) in webpack chunks `$V/*.index.js`. |
| `--version` | `2026.10.19-6bbf2c4` |
| Usage line | `agent [options] [command] [prompt...]` |

Subcommands: `persist`, `install-shell-integration`, `uninstall-shell-integration`, `login`, `logout`, `mcp`, `plugin`, `worker`, `status|whoami`, `models`, `team`, `bedrock`, `about`, `update`, `create-chat`, `generate-rule|rule`, `agent`, `ls`, `resume`, `help`.

Top-level flags relevant to Collie:
- `--plugin-dir <path>` (repeatable): loads a local plugin directory. This is the hook path, see §3.
- `--workspace`, `--add-dir`, `--trust`: `--trust` skips the workspace-trust prompt.
- `--force`/`--yolo`, `--auto-review`, `--sandbox enabled|disabled`, `--approve-mcps`.
- `--mode plan|ask`, `--plan`, `--model`, `--resume [chatId]`, `--continue`.
- `-p/--print`, `--output-format text|json|stream-json`: headless only, not used here.
- `--worktree` creates worktrees under `~/.cursor/worktrees/...`. Collie must never pass it.

No flag takes a config file or a hooks file. There is no `--settings` equivalent.

## 2. Hooks (`hooks.json`)

### Sources the CLI loads

Loader in `$V/6121.index.js` @77758–80500:

| Source | Path | Per terminal? |
|---|---|---|
| enterprise | `/Library/Application Support/Cursor/hooks.json` | no |
| team | `<dir>/.cursor/managed/active-team-hooks/hooks.json` (fetched) | no |
| user | `homedir()/.cursor/hooks.json` (**hard-coded `homedir()`**, ignores `CURSOR_CONFIG_DIR`) | no |
| project | `<workspace>/.cursor/hooks.json` | no (touches the repo) |
| Claude user | `~/.claude/settings.json` (`hooks` key, converted) | no |
| Claude project | `<ws>/.claude/settings.json`, `<ws>/.claude/settings.local.json` | no |
| **plugins** | `pluginHooks`: one entry per loaded plugin, from `<plugin>/hooks/hooks.json` or the manifest's `hooks` key | **yes, through `--plugin-dir`** |

### Event names

Taken from the `../hooks/dist` enum in `$V/index.js`: `sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `afterAgentResponse`, `afterAgentThought`, `stop`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeTabFileRead`, `afterTabFileEdit`, `preCompact`, `subagentStart`, `subagentStop`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `workspaceOpen`.

Claude tool names are mapped: `Bash→Shell`, `Edit→Write`. There is **no** permission-request or notification event. `beforeShellExecution`/`preToolUse` run before the approval decision, not when the menu appears.

### Environment variables

Config-path variables, from `$V/index.js` @3821807 (`../cursor-config/dist/paths.js`):
- `CURSOR_CONFIG_DIR`, else `$XDG_CONFIG_HOME/cursor`, else `~/.cursor`. This moves **`cli-config.json` only** (permissions, approvalMode, sandbox, vim). It does **not** move `hooks.json`.
- `CURSOR_DATA_DIR`, else `~/.cursor`. This moves `projects/` (chat/transcript storage).
- Credentials on macOS use the Keychain by default (`AGENT_CLI_CREDENTIAL_STORE` = `file`/`memory` overrides it). From this, redirecting the config dir should not log the user out. Step 3 should confirm this, but there is no need for it.
- UI knobs found: `AGENT_CLI_HIDE_HEADER`, `AGENT_CLI_HIDE_PROMPT_BAR`, `AGENT_CLI_DISABLE_HALF_BLOCK_PROMPT_BAR`, `AGENT_CLI_LOG_PATH`, `AGENT_CLI_UPDATE_CHECK_URL`, `NO_OPEN_BROWSER`.
- Variables passed to hook commands: `CURSOR_PROJECT_DIR`, `CURSOR_TRANSCRIPT_PATH`, and `CURSOR_PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT` for plugin hooks (`$V/6121.index.js`, `buildHookEnvironment`).

## 3. Per-terminal hook mechanism: **YES (from the bundle; Step 3 must confirm it fires)**

How it works, without touching `~/.cursor` or the repo:

```
cursor-agent --plugin-dir <collie-owned dir>
<collie-owned dir>/
  .cursor-plugin/plugin.json     {"name":"collie-hooks"}
  hooks/hooks.json               {"version":1,"hooks":{"stop":[{"command":"..."}],
                                   "beforeSubmitPrompt":[...], "afterAgentResponse":[...]}}
```

Evidence:
- `$V/544.index.js` @24662: CLI `pluginDir` is passed through as `pluginDirPaths`.
- `$V/7629.index.js` @35463: `for (e of h.enableUserLocalPlugins ? t.pluginDirPaths : []) At.set(e,"cli-args")`, then `ve.registerExtensionPlugin({path, extensionId:"cli-args"})` and a reload.
- `enableUserLocalPlugins` (`$V/7629.index.js` @1038) is a local-agent-profile capability. It is `true` for the normal logged-in profile (`remote`) and for `local-authenticated`, and `false` only in `local-authless` mode.
- `$V/7629.index.js` @34368: `getPluginHooks()` then `{...config, pluginHooks}`, merged into the hook executor (log line "Plugin hooks merged into hook executor").
- `registerExtensionPlugin` (`$V/index.js` @4937762) rejects a path that is not a directory, that has fewer than 3 path segments, that equals `$HOME`, or that is `/`. A dir under Collie's Application Support or the scratchpad is fine.
- The manifest is looked up as `.cursor-plugin/plugin.json`, `.claude-plugin/plugin.json` or `plugin.json` (`$V/index.js`, constant `N`). Hooks come from the manifest `hooks` (string path or inline object) or from `hooks/hooks.json`. Both the Cursor format (`version` + camelCase events) and the Claude Code format are accepted (`Wc`).

Rejected alternatives:
- `CURSOR_CONFIG_DIR`/`XDG_CONFIG_HOME`: do not move `hooks.json`.
- Overriding `HOME`: breaks too much.
- `.cursor/hooks.json` in the repo: forbidden by the global constraints.

Side finding: the CLI **also runs hooks from `~/.claude/settings.json`**. That file currently has `SessionStart`×5, `UserPromptSubmit`, `PreToolUse`×2, `PostToolUse`, `SubagentStart`. The user's Claude hooks will therefore fire inside cursor-agent. Collie's own Claude hooks are passed per terminal through `--settings`, so they are not affected.

## 4. Screen texts (for preset state detection)

All are from `$V/544.index.js` unless noted.

**Ready for input (prompt placeholder)** @356466:
- new chat: `Plan, search, build anything`
- after a turn: `Add a follow-up` (or `Add a follow-up — /plan to review and build`)
- shell mode: `Run a command — e.g., ls` / `Run a command`
- while working, right placeholder: `ctrl+c to stop`
- Turn finished: it sends a desktop notification `Cursor is waiting for you` (@825308, `onTurnCompleted`) as OSC 9 (iTerm2), OSC 777 (Ghostty/Warp) or OSC 99 (kitty/vscode), picked from the detected terminal and sent only when the window is unfocused. It is a possible extra signal, but **not reliable** inside Collie.

**Permission request titles** @376099:
- `Run this command?` (`Run this command outside the sandbox?` when the sandbox is available)
- `Write to this file?`, `Delete this file?`, `Read this file?`, `Run this MCP tool?`, `Allow this web search?`, `Allow this web fetch?`, `Proceed with this edit?`
- In the tool row while pending: `Waiting for approval...` (@428677)

**Options with key hints** @373789:
- Shell: `Run (once) (y)` · `Add Shell(<cmd>) to allowlist? (tab)` · `Run Everything`/`Run in Sandbox (shift+tab)` · `Skip & tell the agent what to do instead (esc or n)`
- Write: `Proceed (y)` · `Reject & propose changes (esc or n or p)` · `Add Write(<path>) to allowlist? (tab)`
- Delete: `Delete (y)` · `Keep (n)`
- MCP: `Run (once) (y)` · `Allowlist MCP Tool (tab)` · `Reject & propose changes (p)` · `Skip (esc or n)`
- The selected row shows `(enter)` as its hint.

**Keys** (`decision-key-intent.ts`, @372393): a menu.
- ↑/↓ move (j/k in vim normal mode); **Enter** submits the highlighted option.
- `y`/`Y` approve; `n`/`N` reject or propose; `Esc` rejects; `p` proposes.
- `Tab` adds to the allowlist; `Shift+Tab` turns on auto-run; `Ctrl+C` rejects.
- **No digit shortcuts.** Collie's approve action should send `y`, and reject should send `n` (or Esc).

**Not logged in**:
- Interactive welcome screen: `Press any key to log in...` (`$V/index.js` @2196631). **Any key starts the browser login**, so Collie must not send keys to a terminal in this state.
- The login flow then shows `If your browser didn't open, click this link to log in:` / `Press q to show a QR code to log in from another device`.
- Non-interactive: `Error: Authentication required. Run 'cursor-agent login', pass --api-key/--auth-token, or set CURSOR_API_KEY/CURSOR_AUTH_TOKEN.` (`$V/index.js` @2021156).
- Slash command: `Not logged in. Run /login first.`
- `status` subcommand: `Not logged in` (`$V/9960.index.js`).

## 5. Usage / limits source: **NONE locally**

`/usage` fetches plan usage from the server (dashboard API, `$V/544.index.js` @901944). Nothing usage-related is cached on disk. `~/.cursor/cli-config.json` holds only UI and permission settings. I read its key names only, plus `approvalMode=allowlist`, `sandbox.mode=disabled`, `vimMode=false`, `notifications=true`. The usage panel stays empty for Cursor.

Directory names listed but contents not read (skipped as possibly secret or irrelevant):
- `~/.cursor`: `mcp.json` (mode 600), `projects/`, `ai-tracking/`, `sandbox-policies/`, `agents/`, `extensions/`, `skills*/`, `plugins/local/`, `ide_state.json`, `argv.json`.
- `~/Library/Application Support/Cursor` (IDE profile): `Local State`, `Trust Tokens*`, `Session Storage`, `Network Persistent State`, `machineid`, `User/`, `IndexedDB`, `Partitions`, `*.sock`.
- `~/.config/cursor`: absent.

## 6. Recommendation

**Task 3 (hooks) can run**, using `--plugin-dir` pointing at an Collie-owned plugin dir. Use `stop` / `afterAgentResponse` for "done" and `beforeSubmitPrompt` for "working". Permission state still has to come from screen text, because no hook fires when the approval menu appears. This is gated on Step 3 below confirming the hook fires in the interactive CLI. If it does not, fall back to screen-text detection only (texts in §4).

## 7. What Step 3 (user's live session) must confirm

1. A `--plugin-dir` plugin with `hooks/hooks.json` → `stop` writing a scratch file **fires in interactive mode**. It must not require approval or "enable plugin" UI, and it must not write anything under `~/.cursor/plugins` or another location.
2. Hook commands inherit the terminal's environment, so `COLLIE_*` variables reach the hook script. Check the stdin JSON shape for `stop`.
3. The real rendered screen for (a) ready (`Plan, search, build anything`), (b) a `ls` permission menu (title, option rows, the selected-row glyph), and (c) the not-logged-in welcome screen if it can be seen safely.
4. `y` approves and `n`/Esc rejects in the live menu, and Enter takes the highlighted row.
5. How the user's `~/.claude/settings.json` hooks behave inside cursor-agent (they will run). Decide whether that matters.
6. Optional: the workspace-trust prompt on first run in a fresh repo. Is `--trust` needed for Collie-spawned terminals?

## 8. Step 3 results (live, 2026-11-03, `cursor-agent` 2026.10.22-27dcf5f)

The user was logged in. Sessions ran in a throwaway git repo in the scratchpad, driven by `expect` (PTY): one short
prompt ("Reply with exactly the word: pong") and one `ls` request answered with `n`. A few `-p` runs used the same prompt.
Nothing was written to `~/.cursor` except the CLI's own per-project state (`~/.cursor/projects/<path>/`: transcript,
`worker.log`, `.workspace-trusted` from `--trust`); `~/.cursor/plugins` was unchanged.

1. **`--plugin-dir` hooks: only `sessionStart` fires.** A plugin (`.cursor-plugin/plugin.json` with name/version/description,
   `hooks/hooks.json` in Cursor format) gets `sessionStart` in both interactive and `-p` mode. `beforeSubmitPrompt`,
   `afterAgentResponse` and `stop` from the plugin **never fire** (Cursor format and Claude format alike), unless the same
   event is also declared in a non-plugin source: with a `.cursor/hooks.json` in the throwaway repo declaring them, the
   plugin's copies fired too. The likely cause: the step list sent with the request (`hooksConfigLease.getConfiguredSteps()`)
   is taken before the plugin hooks are merged in. The only working sources are `~/.cursor/hooks.json` and the repo's
   `.cursor/hooks.json`, both forbidden. **Decision: Task 3 is skipped; `ask` to a Cursor terminal completes on idle.**
   Recheck on a later `cursor-agent` version: if plugin turn hooks start firing, Task 3 can run as planned.
2. Hook commands inherit the terminal's environment (`COLLIE_X=1` reached the hook). The `sessionStart` payload on stdin has
   `conversation_id`, `session_id`, `hook_event_name`, `cursor_version`, `workspace_roots`, `user_email`, `transcript_path`.
3. Screen texts, as rendered: ready shows `Plan, search, build anything` and, after a turn, `Add a follow-up`. They are drawn
   one character per line, so they are not usable as a ready marker. The permission menu renders as plain text:
   `Run this command?` / `Not in allowlist: <cmd>` / `→ Run (once) (y)` / `Add Shell(<cmd>) to allowlist? (tab)` /
   `Run Everything (shift+tab)`. These titles are what `AttentionDetector` matches.
4. `n` rejected the command at once (the agent said "Shell was blocked"). Text then `\r` 1 s later submitted the prompt.
5. **The user's `~/.claude/settings.json` hooks run inside cursor-agent.** The `PreToolUse` `Bash` hook (`rtk hook claude`)
   rewrote the agent's `ls` into `rtk ls`, so the approval menu asked about `rtk` ("Not in allowlist: rtk"). It changes
   which command is shown for approval and what lands in Cursor's allowlist. Collie can't turn this off without touching
   `~/.claude` (no flag or env for it was found; the loader reads `homedir()/.claude/settings.json` unconditionally).
   None of the user's hooks call `collie`, and Collie's own Claude hooks go only through `--settings`, so Collie's state
   is not affected. Collie does not read these hooks: the approval card shows the screen as drawn, including the
   rewritten command. The README says so. A project-level `.claude/settings.json` with `Stop`/`UserPromptSubmit`
   did **not** fire.
6. Not seen: the not-logged-in screen (it would have needed a logout). `--trust` avoided the workspace-trust prompt; the
   preset does not pass it (trusting a folder is the user's call), so the first run in a folder shows Cursor's own prompt.
