# Plan 2N — Claude Code Can Log In Inside a Sandboxed Terminal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `claude` in a sandboxed Collie terminal reads an existing login and saves a new one (Keychain, or its credentials-file fallback), so `/login` never ends in "credentials could not be saved to the macOS Keychain or the credentials file".

**Architecture:** Plan 4S's profile (`SandboxProfile.render`) denies every read under the home, then re-opens `EssentialPaths.homeReads`. R12 meant the Keychain to stay usable — `Library/Keychains` is in `homeWrites` and the `neverGranted` comment says "Not read-denied (Claude reads its Keychain login, R12)" — but it is missing from `homeReads`, so the Security framework (in-process, file-based login keychain) can't open `~/Library/Keychains/login.keychain-db`: no read of the old login, no save of the new. The fallback `~/.claude/.credentials.json` is under `agentConfig` (`.claude` closed for writes) and not in `agentStateWrites`, so it fails too. Fix both lists; prove it with the real `security` tool under the rendered profile.

**Tech Stack:** Swift 6.2, Seatbelt (`sandbox-exec`), `/usr/bin/security`.

**Spec:** user report 2026-10-24 (screenshot: Pastor terminal, Claude Code 2.1.310, "Sign-in completed in the browser, but your credentials could not be saved to the macOS Keychain or the credentials file — you are not logged in. (No previous login on this machine is usable right now either.)"); plan 4S R12 (user decision: keychain usable by agents, accepted).

## Global Constraints

- Only `EssentialPaths` lists and tests change; the profile's rule order stays.
- `Library/Keychains` stays in `neverGranted` (no grant card for it) and out of `secrets`.
- Credentials-file writes: `~/.claude/.credentials.json` and its same-dir atomic-write temps only (`.claude/.credentials.json*`); `~/.claude/settings.json`, hooks, agents, commands stay read-only (R34).
- Tests must never touch the real login keychain: use a temp keychain (`security create-keychain` in a fake home) and pass it explicitly.

## Review Focus

1. A user already logged in before 4S: a new sandboxed Claude terminal starts logged in, no `/login`.
2. Token refresh mid-session (Keychain write of an existing item) works in the sandbox.
3. Security framework needing other files: if the probe still fails after the Keychains read, the missing read is `~/Library/Preferences/com.apple.security*.plist` — add exactly that (read-only, `Library/Preferences` stays in `neverWritable`).
4. A Codex terminal: `~/.codex/auth.json` already writable — unchanged.
5. Terminals already running keep their old profile: the user must restart them (say so in the commit body).

---

### Task 1: Open the Keychain read and the credentials file

**Files:**
- Modify: `Sources/CollieDaemonKit/Sandbox/EssentialPaths.swift` (`homeReads`, `homeWrites`/`agentStateWrites`)
- Test: `Tests/CollieDaemonKitTests/SandboxProfileTests.swift` (existing `sandbox-exec` probe helper, line ~93)

- [ ] **Step 1: Tests** (probe under the rendered profile, fake home with a temp keychain at `<home>/Library/Keychains/test.keychain-db`):
  - `keychainReadableAndWritable`: inside the sandbox `security add-generic-password -a x -s collie-test -w y <kc>` then `security find-generic-password -s collie-test -w <kc>` → prints `y`, exit 0.
  - `claudeCredentialsFileWritable`: write `<home>/.claude/.credentials.json` and `<home>/.claude/.credentials.json.tmp` → OK.
  - `claudeSettingsStillReadOnly`: write `<home>/.claude/settings.json` → denied (R34 unchanged).
  - `keychainsNotGrantable`: `SandboxGrantStore.refusal` for `~/Library/Keychains` unchanged.
- [ ] **Step 2:** Run `swift test --filter SandboxProfileTests` → the two new positive tests FAIL (permission denied).
- [ ] **Step 3:** Add `"Library/Keychains"` to `homeReads` (agents block, with an R12 comment); add `".claude/.credentials.json*"` to `homeWrites` next to `".claude/history.jsonl"` so `agentStateWrites` picks it up. If `keychainReadableAndWritable` still fails, apply Review Focus 3.
- [ ] **Step 4:** `swift test --filter "SandboxProfileTests|SandboxGrantTests"` → PASS.
- [ ] **Step 5: Manual:** rebuild + reinstall the app, restart the daemon, open a new sandboxed Claude terminal: logged in (Review Focus 1); `/login` once more → succeeds, a second new terminal starts logged in.
- [ ] **Step 6: Commit** `fix(sandbox): Claude Code can read and save its login` (body: running terminals need a restart to get the new profile).
