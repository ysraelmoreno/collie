# Plan 2U — Prévia panel + artifact templates

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Prévia" panel that shows a project HTML page live (reload on change, offline) or an artifact, and `collie artifact new deck|dashboard|doc|prototype [name]` that writes a themed starter page and opens a Prévia on it.

**Architecture:** Same shape as the Diagram panel: an app-side plug-in (`runsInDaemon: false`) with a `WKWebView` on a custom scheme (`collie-preview://app/<path>`) serving the opening terminal's project through `DiagramFile`'s no-follow access, network blocked by `HTMLSnapshotter.ruleList()` + `WebLockdown`. The Diagram panel's file watch is extracted into `FileWatch` and shared. Templates are Swift string constants rendered by the daemon with the active design system's tokens (`ExportStyles.themes`), written atomically into the project.

**Tech Stack:** Swift 6.2, WebKit (`WKURLSchemeHandler`, `WKContentRuleList`), Dispatch file sources.

**Spec:** `docs/superpowers/specs/2026-10-25-artifacts-design-like-design.md` (calls 1, 2, 3, 8).

**Parallelism:** independent of 2V (templates use no libraries; 2V Task 4 upgrades them after this merges). 2W Tasks 1–3 run in parallel; 2W Task 4 needs this merged. Conflicts to expect: `Plugins.swift` artifacts spec (2V adds `artifact.libs`) and the Artifacts line in `CollieOrientation.swift` (2V) — the second to merge rebases.

## Global Constraints

- NEVER run the full test suite: only the tests a task creates or changes, `swift test --filter <TestClass>`.
- No real claude prompts in tests; no app launch in subagent work (manual steps are for the user, listed, not run).
- No network at all in this plan.
- Nothing leaves the machine: the Prévia loads only `collie-preview://`, `collie-artifact://` (and `collie-lib://` after 2V); `HTMLSnapshotter.ruleList()` added; `WebLockdown.harden` before the view, `peerConnectionsOff` checked before the first load (fail closed with "Não consegui bloquear a rede da prévia").
- Served files: inside the panel's project root, no component starting with `.`, no symlink (opened with `O_NOFOLLOW` from the root, as `DiagramFile.read`), regular file ≤ 8 MiB.
- Page file: `.html`/`.htm`, inside the project; default for `artifact new`: `docs/pages/<slug>/index.html`; slug `[a-z0-9-]{1,48}` from the name (lowercased, other chars → `-`, trimmed); empty after slugging → `invalidArgs`.
- Plug-in id `preview`, title "Prévia", commands `preview.*`; placements canvas + docks, default canvas; herd state key `file`.
- UI copy pt-BR; code/commits English. Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01PjAbEfJwb2ZH5ScKq3gEbN`

## Review Focus

1. Page links `../../.env`, `/etc/hosts`, `.git/config`, or a symlink in the project pointing out → 404, never served (Task 1 test `servableRefuses…`).
2. An agent rewrites the page in a burst (several writes, a partial file in between) → one reload after the 150 ms coalescing, scroll position kept (Task 2 test `burstReloadsOnceKeepsScroll`).
3. Page tries `fetch("https://…")`, `<img src=http…>`, `new WebSocket`, `RTCPeerConnection` → all fail; panel refuses to load if WebRTC is still on (Task 2 test `noNetwork`).
4. `artifact new` with a name that exists, `../x`, `"Meu Deck 2026!"`, or only symbols → existing file never touched (`invalidArgs` "já existe"), traversal impossible (slug), `meu-deck-2026`, `invalidArgs` (Task 4 tests).
5. No active design system, or the design engine down/slow → page still written with the seed tokens, `warnings` says so, Light/Dark both work (Task 4 test `newWithoutSystemUsesSeed`).
6. Page deleted while shown → status "Arquivo removido" over the last render; recreated → reloads (Task 2 test `deletedThenRecreated`).

---

### Task 1: `PreviewFile` + shared `FileWatch`

**Files:**
- Create: `Sources/CollieCore/PreviewFile.swift`
- Modify: `Sources/CollieCore/DiagramFile.swift` (add `readData`; error noun parameter)
- Create: `Sources/ColliePlugins/FileWatch.swift`
- Modify: `Sources/ColliePlugins/DiagramPanel.swift` (use `FileWatch`, delete `watch/rearmFileWatch/source/stopWatching/scheduleCheck`)
- Test: `Tests/CollieAppTests/PreviewFileTests.swift`; existing `Tests/ColliePluginsTests/DiagramPanelSyncTests.swift` must still pass

**Interfaces:**
- Produces: `PreviewFile.resolve(_ requested: String, projectRoot: URL) throws(ProtocolError) -> URL` (inside project, `.html`/`.htm`, ≤ 8 MiB, symlinks resolved like `DiagramFile.resolve`); `PreviewFile.servable(_ urlPath: String, projectRoot: URL) -> URL?` (percent-decoded path; nil for `..` escaping, any `.`-prefixed component, outside root); `PreviewFile.contentType(_ ext: String) -> String` (html, htm, css, js, mjs, json, svg, png, jpg, jpeg, gif, webp, ico, woff, woff2, txt; else `application/octet-stream`).
- Produces: `DiagramFile.readData(_ url: URL, root: URL, noun: String = "diagrama") throws(ProtocolError) -> Data?` (no-follow, regular file, ≤ 8 MiB; `read` becomes a UTF-8 wrapper over it); `write(_:to:root:noun:)` gains the same `noun` default so messages say "página grande demais" for pages.
- Produces: `@MainActor final class FileWatch { init(file: URL, root: URL, onChange: @escaping @MainActor () -> Void); func rearm(); func stop() }` — watches the file's folder (`.write, .rename, .delete`) and the file (`.write, .extend, .delete, .rename, .attrib`), both via `DiagramFile.openDirectory` + `openat(O_EVTONLY|O_NOFOLLOW)`, re-arms the file source after each event, coalesces bursts into one `onChange` 150 ms later.

- [ ] **Step 1: Tests** `resolveInsideProject`, `resolveRefusesOutside` (`../x.html`, absolute elsewhere, symlink out), `resolveRefusesNonHTML` (`a.md`), `servableAllowsSiblingAssets` (`docs/pages/d/app.css`), `servableRefusesDotPaths` (`.env`, `.git/config`, `a/.collie/x`), `servableRefusesTraversal` (`%2e%2e/%2e%2e/etc/hosts`), `servableRefusesSymlinkOut`, `readDataBinary` (PNG bytes round-trip), `readDataNounInMessage` (9 MiB file, noun "página" → message contains "página grande demais"), `contentTypes`.
- [ ] **Step 2:** Run `swift test --filter PreviewFileTests` → FAIL (types missing).
- [ ] **Step 3:** Implement `PreviewFile`, `readData`/noun; extract `FileWatch` and switch `DiagramPanel` to it (its own-write check by content hash stays in the panel's `onChange`).
- [ ] **Step 4:** `swift test --filter PreviewFileTests` and `swift test --filter DiagramPanelSyncTests` → PASS.
- [ ] **Step 5: Commit** `refactor(diagram): shared FileWatch; feat(preview): PreviewFile rules`.

### Task 2: Prévia plug-in and panel view

**Files:**
- Modify: `Sources/CollieProtocol/Plugins.swift` (`PluginRegistry.preview`, add to `builtIn`)
- Create: `Sources/ColliePlugins/PreviewPanel.swift` (`PreviewPanel: PluginPanelView`, `PreviewSchemeHandler`)
- Modify: `Sources/CollieApp/CollieApp.swift:53` (`PluginViews.register("preview", PreviewPanel.self)`), `Sources/CollieCore/Herd.swift:89` (`"preview": ["file"]`)
- Modify: `Sources/CollieDaemonKit/PanelCommands.swift` (open rules + state), `Sources/CollieDaemonKit/PluginHost.swift:127` (the docked-panel same-project check applies to `preview` too)
- Test: `Tests/ColliePluginsTests/PreviewPanelTests.swift`, `Tests/CollieDaemonKitTests/PanelCommandTests.swift`

**Interfaces:**
- Consumes: Task 1 `PreviewFile.*`, `FileWatch`, `DiagramFile.readData`.
- Produces: panel state `root` (set by the daemon from the opener's project, as `diagramRoot`), `file` (relative or absolute, resolved with `PreviewFile.resolve`) or `artifact` (artifact id; page URL from `artifact.get`'s `url`). `panel.open preview --file <path> | --artifact <id>`.
- Produces: `PreviewPanel.reload(keepScroll: Bool)`; `PreviewPanel.errors: [String]` (last 20 `window.onerror`/`unhandledrejection` messages, captured by a script in an isolated `WKContentWorld` named `collie-preview`); `PreviewPanel.setTheme(_ t: String?)` ("light" | "dark" | nil = page default) applied as `document.documentElement.dataset.theme`.

- [ ] **Step 1: Tests (daemon)** in `PanelCommandTests`: `nonShepherdOpensPreviewOnCanvas` (leashed to it), `nonShepherdPreviewDockRefused`, `previewCapIs8PerTerminal` (shares `testerBrowserCap`'s number, counted separately), `previewFileOutsideProjectRefused`, `previewNeedsFileOrArtifact`, `previewStateHasRoot`.
- [ ] **Step 2: Tests (app)** in `PreviewPanelTests` (temp project dir, no app launch; WKWebView in-process like `DiagramPanelSyncTests`): `servesPageAndSiblings`, `dotPathIs404`, `noNetwork` (page `fetch("https://example.com")`, `new WebSocket("wss://example.com")` both fail; `typeof RTCPeerConnection === "undefined"`), `reloadsOnWriteWithin1s`, `burstReloadsOnceKeepsScroll` (5 writes in 100 ms → 1 navigation; `scrollY` restored), `deletedThenRecreated`, `artifactModeLoadsCollieArtifact` (fixture `<root>/artifacts/<id>/source.html`), `themeToggleSetsDataTheme`, `errorsCaptured` (page throws → `errors` has the message).
- [ ] **Step 3:** Run both filters → FAIL.
- [ ] **Step 4:** Implement. Daemon: `panel.open` lets a non-Shepherd open `preview` (canvas only, leashed, cap 8); `state["root"]` from `diagramRoot` (rename it `projectRootForPanel`, both plug-ins call it); `--artifact` must exist (`artifacts.get`). App: header (file relative to project, **Recarregar**, **Claro/Escuro** segmented `Página | Claro | Escuro`, and two buttons Task 5 wires, hidden until then); `FileWatch` on the page; reload = save `scrollY` via JS, `reload()`, restore on `didFinish`; scheme handler serves `PreviewFile.servable` paths with `readData(noun: "página")`; `collie-artifact` scheme via `DesignSchemeHandler(root: <root>/artifacts, artifacts: true)`. A `ponytail:` comment names the ceiling: in-place writes to files in subfolders aren't watched; **Recarregar** covers it.
- [ ] **Step 5:** Run both filters → PASS.
- [ ] **Step 6: Manual (user, not subagents):** `collie panel open preview --file docs/x.html` from a terminal; edit the file in another terminal → updates; quit/relaunch → same page.
- [ ] **Step 7: Commit** `feat(preview): Prévia panel — live project page, offline`.

### Task 3: Agent commands `preview.get`, `preview.screenshot`

**Files:**
- Modify: `Sources/CollieProtocol/Plugins.swift` (commands on `PluginRegistry.preview`; `screenshot` has `outputFile: true`)
- Modify: `Sources/ColliePlugins/PreviewPanel.swift` (`handle`)
- Test: `Tests/ColliePluginsTests/PreviewPanelTests.swift`

**Interfaces:**
- Produces: `preview.get` → `{file, url, errors: [String]}`; `preview.screenshot [--full-page] [--out PATH]` → `{path, width, height}`, written under `<root>/screens/` with the Diagram screenshot naming.

- [ ] **Step 1: Tests** `getReturnsFileAndErrors`, `screenshotIsPNG` (magic bytes, width = view width), `screenshotFullPage` (height ≥ document height of a 3000 px fixture).
- [ ] **Step 2:** `swift test --filter PreviewPanelTests` → FAIL.
- [ ] **Step 3:** Implement with `WKWebView.takeSnapshot` (full page: the same approach as `BrowserCommands` screenshot; reuse its helper if it is reachable, else move it to a shared static).
- [ ] **Step 4:** `swift test --filter PreviewPanelTests` → PASS.
- [ ] **Step 5: Commit** `feat(preview): preview.get and preview.screenshot`.

### Task 4: Templates and `artifact new`

**Files:**
- Create: `Sources/CollieDaemonKit/Artifacts/ArtifactTemplates.swift`
- Modify: `Sources/CollieProtocol/Plugins.swift` (`acmd("new", …)` on `artifacts`)
- Modify: `Sources/CollieDaemonKit/ArtifactCommands.swift` (`case "artifact.new"`), `Sources/CollieDaemonKit/Design/DesignSystemService.swift` (`variables(of:deadline:)`)
- Modify: `Sources/CollieDaemonKit/CollieOrientation.swift:54` (Artifacts line), `README.md` (section "Prévia e modelos", after Artifacts)
- Test: `Tests/CollieDaemonKitTests/ArtifactTemplateTests.swift`, `Tests/CollieDaemonKitTests/ArtifactTests.swift`, `Tests/CollieDaemonKitTests/CollieOrientationTests.swift`

**Interfaces:**
- Consumes: Task 2's `panel.open preview` path (call the daemon's `openPanel` directly with `state: ["file": rel]`, leash to caller), `DiagramFile.write(_:to:root:noun:)`.
- Produces: `enum ArtifactTemplates { enum Kind: String, CaseIterable { case deck, dashboard, doc, prototype }; static func slug(_ name: String) -> String?; static func tokensCSS(variables: JSONValue?) -> String; static func render(_ kind: Kind, title: String, tokensCSS: String) -> String }`. `tokensCSS(nil)` = seed tokens built from `DesignSystemService.colors/numbers` in the same `variable.list` shape, then `:root{…first mode…}` + `ExportStyles.themes(root:variables:)`; a real system's variables override and add.
- Produces: `DesignSystemService.variables(of ds: DesignSystem, deadline: ContinuousClock.Instant) async throws(ProtocolError) -> JSONValue` (`variable.list` on the system's own file, daemon client).
- Produces command: `artifact.new <kind> [name] [--title T]` (terminal or admin; admin needs `--paddock`/workspace project like `diagramRoot`) → `{file, panel, warnings}`; `panelFree: true`.
- Template contract (all four): `<!doctype html>`, `<html lang="pt-BR">`, `<title>` = escaped title, one `<style>` with the tokens then the kind's CSS using only `var(--bg|--surface|--text|--muted|--accent|--space-s|m|l|xl|--radius-card|--type-body|h1|h2|h3)`, no external URL, no `<script src>`. deck: `<section class="slide">` ×4, 16:9 scaled to the viewport, ←/→/espaço navigate, counter; dashboard: 4 KPI tiles + an inline-SVG bar chart from a `const data = […]` array + a table; doc: header, sticky TOC built from `h2`, article; prototype: phone-width app shell (top bar, list, bottom tabs, a button that opens a sheet). Sample copy pt-BR.

- [ ] **Step 1: Tests** `ArtifactTemplateTests`: `slugCases` (`"Meu Deck 2026!"` → `meu-deck-2026`, `"../x"` → `x`, `"!!!"` → nil, 60 chars → 48), `seedTokensHaveLightAndDark` (`[data-theme="light"]`, `[data-theme="dark"]`, `--accent`), `systemVariablesOverrideSeed` (fixture `variable.list` with `accent` Light `#FF0000` → `--accent: #FF0000` in `:root`), `everyKindIsOffline` (for each kind: no `http`, no `src=`/`href=` to another origin, has `<title>`), `titleIsEscaped` (`<script>` in title → `&lt;script&gt;`).
- [ ] **Step 2: Tests** `ArtifactTests`: `newWritesPageAndOpensPreview` (file at `docs/pages/deck-1/index.html`, a `preview` panel leashed to the caller, `state.file` = that path), `newDefaultNameCounts` (second deck → `deck-2`), `newRefusesExisting` (bytes unchanged), `newWithoutSystemUsesSeed` (warning `"sem design system ativo: tokens padrão"`), `newEngineDownUsesSeed` (warning `"design system indisponível: tokens padrão"`), `newBadKind` (`invalidArgs` lists the four).
- [ ] **Step 3:** `swift test --filter ArtifactTemplateTests` and `--filter ArtifactTests` → FAIL.
- [ ] **Step 4:** Implement (engine read bounded at 10 s; on any `ProtocolError` → seed + warning).
- [ ] **Step 5:** Orientation: Artifacts line becomes `- Artifacts: collie artifact … keeps handed-in pages; artifact new deck|dashboard|doc|prototype starts one in a Prévia.`; `swift test --filter CollieOrientationTests` → PASS (worst case ≤ 1300; shorten the tight variant if needed).
- [ ] **Step 6:** Tests PASS; README paragraph (what the Prévia is, `artifact new`, where pages go, tokens, offline). Commit `feat(artifacts): artifact new — themed starter pages in a Prévia`.

### Task 5: Salvar como artifact, Importar no Design, Abrir na Prévia

**Files:**
- Modify: `Sources/ColliePlugins/PreviewPanel.swift` (the two header buttons)
- Modify: `Sources/ColliePlugins/ArtifactsPanel.swift` (row action **Abrir na Prévia**)
- Test: `Tests/ColliePluginsTests/PreviewPanelTests.swift`, `Tests/ColliePluginsTests/ArtifactsPanelTests.swift`

**Interfaces:**
- Consumes: `artifact.add`, `artifact.import`, `panel.open` through the panel host's daemon client (admin), as `ArtifactsPanel` does today.
- Produces: `PreviewPanel.saveArgs() -> [String: JSONValue]` (pure): `path` = absolute page path, `title` = the page's `<title>` or file name, `root` = the page's folder **unless** it is the project root (then no `root`). The last saved artifact id is kept in `state["saved"]` (`artifact` stays the viewer-mode key), cleared when the page changes on disk.

- [ ] **Step 1: Tests** `saveArgsUsesPageFolder`, `saveArgsNoRootAtProjectRoot`, `saveArgsTitleFromPage`, `artifactModeHidesSaveButtons` (an artifact Prévia shows neither button), `artifactsPanelOpenInPreviewArgs` (`plugin: preview, artifact: <id>`, placement dock right).
- [ ] **Step 2:** filters → FAIL.
- [ ] **Step 3:** Implement. **Salvar como artifact** → `artifact.add` (the import starts in the background, as today), toast "Salvo como artifact"; **Importar no Design** → `artifact.add` if not saved since the last change, then `artifact.import <id>` (spinner "Importando…", errors shown in the header), then `panel.open design --file <returned file>`.
- [ ] **Step 4:** filters → PASS.
- [ ] **Step 5: Manual (user):** `collie artifact new dashboard vendas` → Prévia opens; **Importar no Design** → a Design panel on "vendas"; Artifacts panel → **Abrir na Prévia**.
- [ ] **Step 6: Commit** `feat(preview): save as artifact, import into Design, open artifacts in a Prévia`.
