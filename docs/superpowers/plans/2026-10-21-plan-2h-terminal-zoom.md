# Plan 2H — Zoom Scales Terminal Nodes, Never Resizes the PTY

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zooming the canvas scales a terminal node visually; its cols/rows change only when the node itself is resized.

**Architecture:** Today `CanvasViewport` sets each node's frame to `canvasFrame * zoom` and `TerminalNodeView.layout` gives the SwiftTerm view the zoomed body, so SwiftTerm (`setFrameSize` → `processSizeChange(frame.size)`) recomputes cols/rows and `sizeChanged` resizes the PTY on every zoom tick. Each SIGWINCH makes TUIs (Claude Code/Ink) redraw mid-stream, which leaves the torn layout the user saw. Fix: the node keeps its zoomed *frame* but its *bounds* stay in canvas points (`setBoundsSize(canvasSize)`), so AppKit scales everything inside (title bar, terminal, handles) uniformly, and the terminal's frame — hence its grid — depends only on the canvas-space size.

**Tech Stack:** Swift 6.2, AppKit, SwiftTerm 1.99.0 (pinned).

**Spec:** user report 2026-10-21 ("o zoom in and out está bugando as janelas de terminais, causando esse layout shift").

## Global Constraints

- Zoom range stays `CanvasState.zoomRange` (0.25…2.0); interactive threshold stays `CanvasViewport.interactiveZoom` (0.5).
- PTY resize happens only on: node resize (corner drag), font change (Preferences), mount. Never on zoom or pan.
- Panels (`PanelNodeView`) are out of scope; they keep today's behavior.
- No change to the daemon, protocol, or stored layout file format (`LayoutFile` frames stay canvas-space).

## Review Focus

1. Text crispness at 200%: a bounds-scaled layer-backed view can be rasterized at canvas size and upscaled (blurry). Expected: text as sharp as at 100%.
2. Mouse: click-to-place cursor, selection drag, and mouse reporting in TUIs must hit the right cell at 50% and 200%.
3. Corner resize at zoom ≠ 1 still changes cols/rows once per drag step, in canvas units (existing `d / canvas.zoom`).
4. Crossing 0.5 (label ↔ terminal remount) still sends exactly one resize on mount with the canvas-space grid.
5. Cord handle and cord endpoints stay on the node edge (CordLayer reads screen frames, unchanged).

---

### Task 1: Bounds-scaled terminal nodes

**Files:**
- Modify: `Sources/OrqApp/CanvasViewport.swift:160-180` (where node frames are set)
- Modify: `Sources/OrqApp/TerminalNodeView.swift` (`layout`, `bodyFrame`, header comment line 14)
- Test: manual (OrqApp has no test target); Step 4 is the check.

**Interfaces:**
- Produces: `TerminalNodeView` whose `bounds.size == canvas.frames[id].size` at any zoom; `term.frame.size` is `(w, h - titleHeight)` in canvas points.

- [ ] **Step 1: Set bounds after frame.** In `CanvasViewport.sync`, right after `v.frame = CGRect(origin: canvas.toScreen(f.origin), size: f.size * zoom)` for a `TerminalNodeView`, call `v.setBoundsSize(f.size)`. Re-apply it whenever the frame is set (frame changes reset bounds scaling).
- [ ] **Step 2: Layout in canvas points.** `TerminalNodeView.layout` already uses `bounds`; with Step 1 `bodyFrame` becomes canvas-space with no code change. `move`/`resize` read `event.deltaX` (screen) and must keep dividing by zoom. Update the header comment to: "Its bounds are the node's canvas size and its frame the screen size: zoom scales it, cols/rows follow canvas size only."
- [ ] **Step 3: Crispness.** Build, open a terminal, zoom to 200% and screenshot. If text is soft, set `contentsScale = (window?.backingScaleFactor ?? 2) * canvas.zoom` on the node's layer tree (term, title host) whenever zoom changes, capped at `backingScaleFactor * 2`. Do not change the font.
- [ ] **Step 4: Verify no resize on zoom.** Add a `Log.canvas.debug("pty resize \(newCols)x\(newRows)")` in `sizeChanged`, run with Claude Code in a node, pinch from 50% to 200% and back: log shows no resize lines; TUI has no torn lines. Corner-drag: resize lines appear.
- [ ] **Step 5: Manual checks for Review Focus 2–5** at 50% and 200%: click places cursor in the right cell, selection highlights the dragged text, cord handle drag still connects, crossing 0.5 remounts cleanly.
- [ ] **Step 6: Commit**

```bash
git add Sources/OrqApp/CanvasViewport.swift Sources/OrqApp/TerminalNodeView.swift
git commit -m "fix(app): zoom scales terminal nodes instead of resizing the PTY"
```
