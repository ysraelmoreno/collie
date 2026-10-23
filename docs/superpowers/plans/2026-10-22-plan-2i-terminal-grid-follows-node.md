# Plan 2I — Terminal Grid Always Follows the Node Size

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A terminal node's SwiftTerm grid (and so the PTY) always matches the node's body size; no node ever shows a smaller grid in its top-left corner.

**Architecture:** User screenshot 2026-10-22: Claude Code in a ~127×38 node draws at ~81×21 — text, prompt box and status line all stop at ~2/3 width and the bottom half is empty. Grid and PTY agree (Claude's rule line ends exactly at the grid edge), so the PTY path (`sizeChanged` → `TerminalStream.resize` → `PTYProcess.resize`) is fine; the SwiftTerm grid itself did not follow `term.frame`. Since 2H, `TerminalNodeView.layout` sets `term.frame = bodyFrame` (canvas points) only when `place` saw a new `canvasSize`, and SwiftTerm resizes only from `setFrameSize` (sync via `processSizeChange`, or deferred via `queueSizeChange` while the window is `inLiveResize`). Some path leaves the frame big and the grid small. Task 1 finds which; Task 2 fixes it at the root and adds one reconcile so a stale grid can't persist.

**Tech Stack:** Swift 6.2, AppKit, SwiftTerm 1.99.0 (pinned exact).

**Spec:** user report 2026-10-22 ("o terminal do Claude está assim, não faz um resize correto").

## Global Constraints

- 2H invariants stay: zoom and pan never change cols/rows; PTY resizes only on node resize, font change, mount (and now: grid/frame mismatch repair).
- No change to daemon, protocol, `LayoutFile`, or SwiftTerm (pinned; no fork).
- Font changes keep using `setFontKeepingModes` (no DECSTR soft reset). Any forced resync must go through the frame path, never `terminal.resize` / the `font` setter.

## Review Focus

1. Collie window live resize / fullscreen toggle / moving the window to a display with another backing scale: grid must match the node after the gesture ends.
2. Zoom crossing 1.0 (raster scale 2→4) and 0.5 (remount): grid unchanged, matching the node.
3. Node created by `summon` while off-screen or before the app connects, then scrolled into view: grid matches on first mount.
4. Daemon restart / stream reattach: `lastSize` resent equals the current grid, not an old one.
5. The repair must not loop: after it runs once, `terminalDimensions` equals expected and no further `sizeChanged` fires.

---

### Task 1: Reproduce and name the path

**Files:**
- Modify: `Sources/CollieApp/TerminalNodeView.swift` (`layout`, debug log only)

- [ ] **Step 1:** In `layout()`, after `term?.frame = bodyFrame`, log `Log.canvas.debug("grid \(id) frame \(bodyFrame.size) dims \(t.terminalDimensions.cols)x\(t.terminalDimensions.rows) live \(inLiveResize)")`.
- [ ] **Step 2:** Run the app with `log stream --level debug --predicate 'category == "canvas"'`; run Claude Code in a node and try each Review Focus scenario 1–4, plus a corner drag. Record which scenario leaves dims smaller than `frame / cell` (≈ `bodyFrame.width / cellWidth`).
- [ ] **Step 3:** Write the finding (scenario + why SwiftTerm's grid didn't update) as the first line of Task 2's commit body. Keep the log line (debug level).

### Task 2: Fix the path, plus a reconcile

**Files:**
- Modify: `Sources/CollieApp/TerminalNodeView.swift`

**Interfaces:**
- Produces: `TerminalNodeView.reconcileGrid()` — if the mounted terminal's `terminalDimensions` differ from the cols/rows its current frame implies, re-run SwiftTerm's frame path (`setFrameSize(.zero)` then the frame size, as `setFontKeepingModes` does) so `processSizeChange` → `sizeChanged` fire synchronously. No-op otherwise.

- [ ] **Step 1:** Fix the root cause found in Task 1 where it lives (e.g. a `place` that skips `needsLayout`, a queued live-resize size never applied, a mount before `canvasSize` is set).
- [ ] **Step 2:** Implement `reconcileGrid()`; call it at the end of `layout()`, in `viewDidEndLiveResize()`, and in the `viewDidChangeBackingProperties` async block. Expected cols/rows: compute from SwiftTerm's own cell size if exposed (`getOptimalFrameSize`/cell dimension); otherwise compare against the dims SwiftTerm reports right after a forced frame pass — do not hand-roll font metrics.
- [ ] **Step 3:** Verify: every Task 1 scenario shows dims matching frame in the log; Claude Code fills the node width and its prompt sits at the node's bottom; at 50%/200% zoom no `pty resize` lines (2H Step 4 still holds); a corner drag logs one resize per step.
- [ ] **Step 4: Commit**

```bash
git add Sources/CollieApp/TerminalNodeView.swift
git commit -m "fix(app): terminal grid always follows the node size"
```
