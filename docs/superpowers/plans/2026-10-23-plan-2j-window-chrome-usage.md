# Plan 2J — Traffic Lights, Settings Gear, Claude Code Usage, Stable Signing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The main window shows the macOS close/minimize/zoom buttons; the sidebar footer has a gear that opens Preferences; the USO bar for Claude Code shows real 5h/7d usage; local builds keep their TCC grants across rebuilds.

**Architecture:**
- Traffic lights: `Shell` uses `.toolbar(.hidden, for: .windowToolbar)` (comment claims "the traffic lights stay"); on macOS 15 that can drop the titlebar buttons. Replace with a hidden-titlebar style that keeps them, and inset the sidebar top so the logo isn't under them.
- Usage: `DefaultUsageProviders.claude` ships disabled (no local source). There is one now: Claude Code ≥2.1 passes `rate_limits.five_hour|seven_day.{used_percentage,resets_at}` (epoch seconds) in the JSON it pipes to its statusLine command. Collie already writes a per-terminal `--settings` file (`AgentLaunch.claude`); add a `statusLine` there pointing at `collie hook claude-statusline`, which records `rate_limits` to a file the claude provider reads, then runs the user's own statusLine so their bar is unchanged.
- Signing: `scripts/bundle-app.sh` signs ad-hoc, so every rebuild is a new code identity and TCC forgets "Documents"/Full Disk Access. Sign with a stable local identity when present.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit (macOS 15), Claude Code 2.1.309 statusLine contract, `codesign`/`security`.

**Spec:** user report 2026-10-23 (screenshot: no traffic lights; "adicione um ícone de engrenagem para abrir as preferências" — footer chosen; "o limite do Claude Code não está lendo corretamente… a barra de uso não cresce"); TCC loss on rebuild seen 2026-10-22/23.

## Global Constraints

- Nothing in the user's global config: never write `~/.claude/settings.json` (read-only access to find their statusLine is fine). The statusLine is injected only through Collie's per-terminal `--settings` file.
- No network, no credentials: no OAuth/Keychain reads, no `api/oauth/usage` calls.
- The usage file holds only `rate_limits` + a timestamp (no session/cwd/transcript fields), mode 0600, written atomically.
- `collie hook claude-statusline` must never break Claude's bar: any failure (bad JSON, no rate_limits, file write error, user's command failing) still prints the user's statusLine output (or nothing) and exits 0. Total time bounded (user command timeout 5 s).
- Preferences open through SwiftUI's `openSettings` (same window as ⌘, and the palette's "Preferências…").
- UI copy in Portuguese; code/commits in English.

## Review Focus

1. User with their own statusLine (e.g. this user's `[CAVEMAN]` line): inside a Collie Claude terminal the bar looks exactly as before.
2. Free/API-key users (no `rate_limits` in the JSON): file untouched, USO shows "—" with no error.
3. Existing installs: `<root>/usage/providers/claude.json` was seeded disabled with the old template; it must be upgraded once, but a provider file the user edited stays.
4. Fullscreen: macOS hides traffic lights until hover by design — windowed mode is the check.
5. No signing identity on the machine (CI, other devs): `bundle-app.sh` still builds, ad-hoc, with a one-line warning.

---

### Task 1: Traffic lights + gear

**Files:**
- Modify: `Sources/CollieApp/Shell.swift` (`Shell.body`, `WorkspaceSidebar` top inset and footer)
- Modify: `Sources/CollieApp/CollieApp.swift` (scene modifier, if the fix lives on `Window`)

- [ ] **Step 1:** Build, run windowed (not fullscreen), confirm lights are missing. Swap `.toolbar(.hidden, for: .windowToolbar)` for a style that keeps them (`.windowStyle(.hiddenTitleBar)` on the `Window` scene, or `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` + `.toolbar(removing: .title)`); pick whichever shows the lights with no visible toolbar band. Fix the comment.
- [ ] **Step 2:** Top-pad `WorkspaceSidebar` (≈28 pt) so "collie default" sits below the lights; Compacta's floating bar gets the same offset if it overlaps them.
- [ ] **Step 3:** Footer of `WorkspaceSidebar`, after the `usage` block: a borderless `Button` with `Image(systemName: "gearshape")`, `.help("Preferências (⌘,)")`, `.accessibilityLabel("Preferências")`, action `openSettings()` (`@Environment(\.openSettings)`).
- [ ] **Step 4:** Verify: lights visible and working (close/minimize/zoom, double-click titlebar area still zooms), gear opens Preferences, ⌘, still works, Compacta unaffected.
- [ ] **Step 5: Commit** `fix(app): keep traffic lights; settings gear in the sidebar footer`

### Task 2: `collie hook claude-statusline`

**Files:**
- Modify: `Sources/collie/HookCommands.swift` (new subcommand)
- Create: `Sources/CollieCore/ClaudeRateLimits.swift` (pure parse + file format)
- Test: `Tests/CollieCoreTests/ClaudeRateLimitsTests.swift`

**Interfaces:**
- Produces: `ClaudeRateLimits.extract(_ statusJSON: Data) -> Data?` — returns `{"five_hour":{…},"seven_day":{…},"recorded_at":<epoch s>}` (only those keys present in input; nil when `rate_limits` is absent or has neither window). `ClaudeRateLimits.fileName = "claude-rate-limits.json"`, stored in `<root>/usage/`.
- Produces: `ClaudeRateLimits.userStatusLineCommand(settings: Data) -> String?` — `statusLine.command` when `statusLine.type == "command"`.

- [ ] **Step 1: Tests** `extractsBothWindows`, `extractsFiveHourOnly`, `nilWithoutRateLimits`, `dropsOtherFields` (input with `session_id`, `cwd`, `transcript_path` → output has none of them), `userCommandFromSettings`, `noUserCommand`.
- [ ] **Step 2:** Implement; run `swift test --filter ClaudeRateLimitsTests` → PASS.
- [ ] **Step 3:** Subcommand: read stdin (cap 1 MiB); if `extract` returns data, write it atomically 0600 to `<root>/usage/claude-rate-limits.json` (root from the same resolution the other hooks use; skip silently if unknown); then if `~/.claude/settings.json` has a user statusLine command, run it via `/bin/sh -c` with the same stdin bytes, 5 s timeout, forward its stdout; exit 0 always.
- [ ] **Step 4: Commit** `feat(hooks): record Claude Code rate limits from the statusLine feed`

### Task 3: Wire it: settings + provider

**Files:**
- Modify: `Sources/CollieDaemonKit/AgentLaunch.swift` (`claude(_:)` settings JSON)
- Modify: `Sources/CollieDaemonKit/DefaultUsageProviders.swift`, `Sources/CollieDaemonKit/UsageService.swift` (seed upgrade)
- Test: existing AgentLaunch / UsageService test files

**Interfaces:**
- Consumes: Task 2 subcommand name and file name.

- [ ] **Step 1: Tests** `claudeSettingsHaveStatusLine` (settings JSON has `statusLine = {type: "command", command: "<collie> hook claude-statusline", padding: 0}`); `claudeProviderReadsRateLimitsFile` (provider pointed at a temp usage dir with a sample file → windows 5h/7d with the sample percents and resets); `upgradesOldClaudeSeed` (old shipped template byte-equal → replaced); `keepsEditedClaudeProvider` (edited file → untouched).
- [ ] **Step 2:** Add the `statusLine` key. New `claude` provider: `enabled: true`, command reads `<usage dir>/claude-rate-limits.json` (UsageService passes `COLLIE_USAGE_DIR` in the provider's env; command `["/bin/sh","-c","cat \"$COLLIE_USAGE_DIR/claude-rate-limits.json\" 2>/dev/null; true"]`), `parse: json`, windows `/five_hour/used_percentage`,`/five_hour/resets_at`,`/seven_day/used_percentage`,`/seven_day/resets_at`. Remove the "no local source" comment; say where the data comes from. Seed upgrade: on start, if `providers/claude.json` equals the previous shipped template exactly, overwrite it with the new one.
- [ ] **Step 3:** Empty file (no Collie Claude has refreshed yet, or not a subscriber) → report with no percents, shown as "—" (no error text).
- [ ] **Step 4:** Run `swift test` → PASS. Manual: start a Claude terminal in Collie, send one prompt; USO shows `Claude Code · 5h NN%` matching `/usage` in that session; the session's own statusline unchanged.
- [ ] **Step 5: Commit** `feat(usage): Claude Code 5h/7d usage from Collie's statusLine hook`

### Task 4: Stable local signing

**Files:**
- Create: `scripts/make-signing-cert.sh`
- Modify: `scripts/bundle-app.sh` (lines 2, 31–34), `README.md` (build section, one paragraph)

- [ ] **Step 1:** `make-signing-cert.sh`: creates a self-signed code-signing identity "Collie Local" in the login keychain (openssl key+cert with codeSigning EKU → `security import` → trust for code signing); idempotent (exits 0 if `security find-identity -v -p codesigning | grep "Collie Local"`).
- [ ] **Step 2:** `bundle-app.sh`: `ID="${COLLIE_SIGN_IDENTITY:-Collie Local}"`; if `security find-identity -v -p codesigning` lists it, sign with `-s "$ID"`, else `-s -` and print `warning: no "$ID" signing identity (run scripts/make-signing-cert.sh): ad-hoc, TCC grants reset on every rebuild`. Keep `--options runtime`, the figcraft binaries step and `codesign -v`. Update the header comment.
- [ ] **Step 3:** Verify: build twice with the identity; `codesign -dr - build/Collie.app` designated requirement identical both times (no cdhash); grant Documents once, rebuild, access still granted.
- [ ] **Step 4: Commit** `build: sign Collie.app with a stable local identity when available`
