# Plan 2O — Sandboxed Terminals Can Open the Files Collie Makes for Them

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A file the daemon makes for a terminal (design/browser/device screenshots, design exports) is readable by that terminal under the 4S sandbox; `--out` works for every one of them; an empty design batch is a no-op and a delete without ids never acts on the user's selection.

**Architecture:** The daemon writes these files under its root (`DesignService` `screens`/`exportsDir`, `BrowserCommands.swift:306`, `DeviceService+Android.swift:121`, `DeviceService+iOS.swift:52`) and returns `path`. 4S closes the root to the terminal (`SandboxProfile`: `deny file-read* (subpath collie)`, re-opening only `ownFiles` and `terminalDir`), and `collie … --out` copies in the CLI, which runs inside the same sandbox — so the agent gets a path it can't open ("Sem acesso aos screenshots", user screenshot 2026-10-24). Fix once in the router: for a sandboxed caller, a returned output file is cloned into the terminal's own readable dir `<root>/sandbox/<id>/files/` and `path` rewritten. `--out` then copies from a readable file, so it is opened to all those commands.

**Tech Stack:** Swift 6.2, `clonefile(2)`/`copyfile`, Seatbelt.

**Spec:** user report 2026-10-24 ("os terminais não estão conseguindo acessar screenshots que eles fazem, por exemplo do FigCraft"; frequent `batch failed: … the batch must be a non-empty JSON array of {command, params}` and `edit.delete failed: … nothing is selected (pass ids)` in a designer terminal).

## Global Constraints

- The sandbox profile does not change: `files/` sits under `terminalDir`, already readable (`allow file-read* (subpath tdir)`) and not writable (only `state/` is).
- Only these results are handed over: `design.screenshot`, `design.export`, `browser.screenshot`, `device.screenshot` (the iOS/Android ones), and any later command listed in one constant `CommandRouter.outputFileCommands`. Never memory files, artifacts, crash logs or anything else under the root.
- The source must be a regular file whose resolved path is under the daemon's root (no symlink follow); otherwise the result is returned unchanged.
- Free terminals and the admin are unchanged (they can read the root).
- `files/` keeps the newest 100 files per terminal; it goes with the terminal (`SandboxLaunch.remove` already deletes the dir).
- Design-engine selection belongs to the user: no agent command acts on it.

## Review Focus

1. A designer agent in a sandboxed terminal: `collie design screenshot --panel design-1` then reads the returned PNG (Claude's Read tool) → works.
2. `collie design screenshot --out shot.png` from a project subdir → file there, readable, path absolute in the reply.
3. Same file name twice (two screenshots in one ms on two panels): no overwrite — keep the source's unique name, add a suffix on collision.
4. Daemon restart: earlier `files/` contents still readable; a new result doesn't fail if `files/` is missing (created 0700).
5. An agent script whose filter finds nothing sends `[]` → OK, nothing done, no error.

---

### Task 1: Hand output files to the sandboxed caller

**Files:**
- Modify: `Sources/CollieDaemonKit/CommandRouter.swift` (after the command returns, in `handle`; `sandboxed(_:)` at :697 already exists)
- Modify: `Sources/CollieDaemonKit/Sandbox/SandboxLaunch.swift` (`static func filesDir(_ id: UUID, root: URL) -> URL` = `dir(id, root:)/files`)
- Test: `Tests/CollieDaemonKitTests/SandboxProfileTests.swift` (probe), router test file next to the sandbox ones

**Interfaces:**
- Produces: `CommandRouter.outputFileCommands: Set<String>`; `SandboxLaunch.handOver(_ src: URL, terminal: UUID, root: URL) throws -> URL` (clone into `filesDir`, prune to 100 newest, return the new path).

- [ ] **Step 1: Tests**
  - `sandboxedScreenshotPathIsReadable`: router with a sandboxed terminal, a stub `design.screenshot` result pointing at a PNG under the root → reply `path` is under `sandbox/<id>/files/`; a `sandbox-exec` probe under that terminal's rendered profile `cat`s it → exit 0; the original stays.
  - `freeTerminalPathUnchanged`, `adminPathUnchanged`.
  - `notListedCommandUnchanged` (e.g. a `memory.get` result with `path`).
  - `symlinkSourceNotHandedOver` (`path` is a link to `~/.ssh/id_ed25519` → reply unchanged, nothing copied).
  - `prunesToHundred`, `nameCollisionGetsSuffix`.
- [ ] **Step 2:** Run the filter → FAIL.
- [ ] **Step 3:** Implement; clone off the cooperative pool (`UnixSocketClient.offPool`), as the other file I/O in the router.
- [ ] **Step 4:** Tests PASS. Commit `fix(sandbox): output files readable by the terminal that asked`.

### Task 2: `--out` for every output-file command

**Files:**
- Modify: `Sources/collie/CLI.swift:26` (`browser.screenshot` only → `CommandRouter.outputFileCommands`' names; move that set to `CollieProtocol` as `Commands.outputFile` so the CLI can see it, router uses the same)
- Modify: `Sources/CollieProtocol/OutFile.swift` (doc comment), command specs' help for the added `--out`
- Test: existing OutFile / CLI tests

- [ ] **Step 1: Tests** `outAcceptedForDesignScreenshot`, `outAcceptedForDesignExport`, `outRejectedForOtherCommands` (unchanged message).
- [ ] **Step 2:** Implement; tests PASS.
- [ ] **Step 3: Manual (Review Focus 1–2):** rebuild, restart daemon and terminals; in a sandboxed Claude terminal with a Design panel: screenshot, Read the PNG; `--out shot.png`; same with `collie browser screenshot`.
- [ ] **Step 4: Commit** `feat(cli): --out for every command that returns a file`.

### Task 3: Design batch and delete

**Files:**
- Modify: `Sources/CollieDaemonKit/Design/DesignService.swift` (`steps(text:)` :891; the single-command path for `edit.*`)
- Modify: the `design.batch` / design edit help text in `Sources/CollieProtocol/Plugins.swift`
- Test: `Tests/CollieDaemonKitTests/DesignCommandTests.swift`

- [ ] **Step 1: Tests**
  - `emptyBatchIsNoOp`: `[]` → `{"results": []}`, engine not called.
  - `deleteWithEmptyIdsIsNoOp`: `edit.delete {ids: []}` (alone or as a batch step) → skipped, result `{"skipped": "no ids"}`, engine not called.
  - `deleteWithoutIdsRefused`: `edit.delete {}` → `invalidArgs` "edit.delete needs ids: agents never act on the user's selection", engine not called. Same rule for every `edit.*` step the engine would apply to the selection (list them from the engine's command table; at least `edit.delete`, `edit.duplicate`, `edit.group`).
  - `nonArrayBatchStillRefused` (`{}` → the old message without "non-empty").
- [ ] **Step 2:** Implement; tests PASS.
- [ ] **Step 3:** Help text: batch accepts `[]`; `edit.*` needs `ids`.
- [ ] **Step 4: Commit** `fix(design): empty batch is a no-op; edits never use the user's selection`.
