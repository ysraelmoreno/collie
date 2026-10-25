# Plan 2Q — Diagram Panel (draw.io editor, Mermaid in, PNG/SVG out)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Diagrama" panel: a lightweight Lucidchart-like editor (flowcharts, swimlanes, ERD, UML) that the user edits by hand and agents drive by command — open a `.drawio` file of the project, read/replace it, insert from Mermaid, export PNG/SVG.

**Architecture:** Same shape as the Design panel (`ColliePlugins/DesignPanel.swift`): a `WKWebView` serving a pinned, locally bundled web editor through a custom scheme — here draw.io's embed mode (`index.html?embed=1&proto=json&offline=1…`, Apache-2.0, jgraph/drawio), talking JSON over `postMessage`. The plug-in runs in the app (`runsInDaemon: false`): agent commands reach `DiagramPanel.handle` through the existing `ui.host` path. The document is a plain `.drawio` XML file in the project (git-versioned, editable by agents directly); the panel autosaves user edits to it and reloads when it changes on disk.

**Tech Stack:** Swift 6.2, WebKit (`WKURLSchemeHandler`, `WKContentRuleList`), draw.io embed protocol, bash build script.

**Spec:** user request 2026-10-25 ("criar um lucid chart lightweight") + agreed shape: draw.io in the panel, Mermaid as the agents' input, built-in plug-in now (external plug-ins designed separately: `docs/superpowers/specs/2026-10-25-external-plugins-design.md`).

## Global Constraints

- Nothing leaves the machine: the web view loads only `collie-diagram://`; a `WKContentRuleList` blocks every `http(s)`/`ws(s)` load; draw.io runs with `offline=1`, `stealth=1`, no plugins, no cloud storage, no Google fonts (bundled fonts only).
- Pinned build: `scripts/build-drawio.sh` fetches one drawio release tag by commit, verifies it, copies only what embed mode needs into `vendor/drawio/web` (+ `LICENSE`), target ≤ 40 MB (measure and record the real size in the script header). `bundle-app.sh` copies it to `Contents/Resources/drawio/`, warning if missing (like figcraft).
- Name: UI says "Diagrama"; "draw.io"/"diagrams.net" appear only in `Resources/NOTICE-drawio` and the About credits (trademarks of JGraph; Apache-2.0 §6). Patch out any visible draw.io branding/links in the embed UI if present (a `patches/drawio/` patch, listed in the NOTICE).
- The file must resolve inside the panel's project root (the opening terminal's project, as `panel.open` already resolves `cwd`), extension `.drawio`, ≤ 8 MiB; no symlink out. Default `<project>/docs/diagrams/<panel name>.drawio`.
- Plug-in id `diagram`, commands `diagram.*`; placements canvas + docks, default canvas; herds may carry `state: {file}`.
- Exports and screenshots are output files: add `diagram.export`, `diagram.screenshot` to `Commands.outputFile` (plan 2O) so sandboxed agents read them and `--out` works. If 2O isn't merged yet, add them when it is (note in the commit).
- UI copy pt-BR; code/commits English.

## Review Focus

1. User edits while an agent runs `diagram.set`: the agent's version wins only if the user has no unsaved edit in the last 2 s; otherwise `conflict` error to the agent ("o usuário está editando; tente de novo") and the user's edit is kept.
2. File changed on disk by an agent's own write (not through the panel): the panel reloads within 1 s, keeping zoom/scroll when possible.
3. Malformed XML from an agent (`diagram.set`): refused before it reaches the editor (`invalidArgs` with the parse error line), file untouched.
4. Mermaid the converter can't handle: `invalidArgs` naming the first bad line; nothing inserted.
5. Panel closed and reopened, app relaunched: same file, same page; the file is never deleted with the panel (it belongs to the project).

---

### Task 1: Vendor draw.io + spike the embed protocol

**Files:**
- Create: `scripts/build-drawio.sh`, `Resources/NOTICE-drawio`
- Modify: `scripts/bundle-app.sh` (copy step), `.gitignore` (`vendor/drawio*`)
- Create: `docs/superpowers/notes/2026-10-25-drawio-embed-spike.md` (findings)

- [ ] **Step 1:** Script: clone tag (pin `DRAWIO_TAG` + `DRAWIO_COMMIT`, check `rev-parse`), copy the embed webapp subset, apply `patches/drawio/*.patch`, write `vendor/drawio/web`. Idempotent like `build-figcraft.sh`.
- [ ] **Step 2: Spike** (throwaway Swift test harness or a scratch app target, not committed code): load embed mode from a custom scheme in a `WKWebView` with all network blocked and confirm, writing the answer for each in the note:
  - `init` → `load {xml}` round-trip; `autosave` events carry the XML.
  - `export {format: "png"|"svg"}` returns data without network.
  - Mermaid → **editable shapes** offline (draw.io's Mermaid import; which message/action triggers it). If only a non-editable image is possible, say so — Task 3 then inserts Mermaid as an image and the plan's `diagram.mermaid` help says "imagem (não editável)".
  - Real size of the subset.
- [ ] **Step 3: Commit** `build: vendor draw.io embed for the Diagram panel` (body: spike findings summary).

### Task 2: Plug-in spec, panel view, file sync

**Files:**
- Modify: `Sources/CollieProtocol/Plugins.swift` (`PluginRegistry.diagram`, add to `all`)
- Create: `Sources/ColliePlugins/DiagramPanel.swift` (`DiagramPanel: PluginPanelView`, scheme handler `collie-diagram://`, content rule list, bridge)
- Create: `Sources/ColliePlugins/DiagramFile.swift` (pure: resolve/validate path, read/write atomically, XML well-formedness via `XMLParser`, conflict rule)
- Modify: `Sources/CollieApp/CollieApp.swift:51` (`PluginViews.register("diagram", DiagramPanel.self)`), `Sources/CollieCore/Herd.swift:89` (`"diagram": ["file"]`), `Sources/CollieDaemonKit/CollieOrientation.swift:57` (hint `"diagram": "diagram --file <path.drawio>"`)
- Test: `Tests/CollieAppTests/DiagramFileTests.swift`, `CollieOrientationTests` (worst case still ≤ 1300)

**Interfaces:**
- Produces: `DiagramFile.resolve(_ requested: String?, panelName: String, projectRoot: URL) throws(ProtocolError) -> URL`; `DiagramFile.validate(xml: String) throws(ProtocolError)`; `DiagramFile.mayOverwrite(lastUserEditAt: Date?, now: Date) -> Bool` (false within 2 s).
- Produces commands (Task 3 implements the bodies): `diagram.get` → `{file, xml, pages:[{id,name}]}`; `diagram.set --xml X | --from PATH` → `{file, bytes}`; `diagram.mermaid <text> [--page NAME]` → `{inserted, editable}`; `diagram.export --format png|svg [--page NAME] [--out PATH]` → `{path, width, height}`; `diagram.screenshot [--out PATH]` → `{path, width, height}`.

- [ ] **Step 1: Tests** `resolveDefaultPath` (`docs/diagrams/<name>.drawio`), `resolveRelativeInsideProject`, `resolveRefusesOutside` (`../x.drawio`, absolute elsewhere, symlink out), `resolveRefusesWrongExtension`, `validateRejectsMalformed` (message has the line), `validateAcceptsEmptyDiagram`, `mayOverwriteRule` (1.9 s → false, 2.1 s → true, nil → true).
- [ ] **Step 2:** Implement `DiagramFile` → tests PASS.
- [ ] **Step 3:** `DiagramPanel`: on mount, read the file (create with an empty `<mxfile>` if missing), `init`→`load`; `autosave` → atomic write + `lastUserEditAt`; a `DispatchSource` file watch reloads on outside change (ignoring its own writes by content hash). Header shows the file path relative to the project. Network blocked as in Global Constraints.
- [ ] **Step 4:** Register view, herd key, orientation hint; orientation test PASS.
- [ ] **Step 5: Manual:** open from the palette and with `collie panel open diagram --file docs/diagrams/arq.drawio`; draw, quit, relaunch → same diagram; `git diff` shows the XML.
- [ ] **Step 6: Commit** `feat(diagram): Diagram panel with a project .drawio file`.

### Task 3: Agent commands

**Files:**
- Modify: `Sources/ColliePlugins/DiagramPanel.swift` (`handle`)
- Modify: `Sources/CollieProtocol/Commands.swift` (`Commands.outputFile` gets `diagram.export`, `diagram.screenshot`, if 2O merged)
- Test: `Tests/CollieAppTests/DiagramPanelTests.swift` (with the vendored web build present; skipped with a message when `vendor/drawio/web` is missing)

- [ ] **Step 1: Tests** `getReturnsFileXml`, `setReplacesAndPanelReloads`, `setMalformedRefused` (file unchanged), `setConflictWhileUserEditing` (simulate `lastUserEditAt = now`), `mermaidInsertsFlowchart` (`graph TD; A-->B` → 2 vertices + 1 edge in the XML if editable, else 1 image cell), `mermaidBadLineRefused`, `exportPngIsPng`, `exportSvgIsSvg`, `noNetworkRequests` (rule list: a page `fetch("https://example.com")` fails).
- [ ] **Step 2:** Implement; exports written under `<root>/screens/` with the same naming as design screenshots.
- [ ] **Step 3:** `swift test` → PASS.
- [ ] **Step 4: Manual:** from a sandboxed Claude terminal leashed to the panel: `collie diagram mermaid "graph TD; Cliente-->API; API-->DB"`, then `collie diagram export --format png --out docs/diagrams/arq.png`, Read the PNG; edit by hand meanwhile and check Review Focus 1.
- [ ] **Step 5:** README: one paragraph "Diagrama" (what it is, `.drawio` in the project, Mermaid, exports) + NOTICE line. Commit `feat(diagram): agent commands — get/set, Mermaid, export`.
