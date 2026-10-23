# Plan 2K — Browser for QA: Viewport, Media, Screenshots, Real Input, Storage, Tester Browsers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tester agent can open its own browser (headless or on the canvas), set a real page width independent of the panel, emulate color scheme / reduced motion, drive it with trusted keyboard and mouse events, control storage and pre-load scripts, and save full-page or clipped screenshots where it chooses.

**Architecture:** All in the browser plug-in (`ColliePlugins/Browser*.swift`), its specs (`CollieProtocol/Plugins.swift`), the CLI, and panel gating (`CollieDaemonKit/PanelCommands.swift`, `ConnectionGraph`). Key facts from the current code:
- `browser.resize` sets `Container.viewport`, and a canvas node (`PanelContentSizing`) resizes itself to it: the page width is tied to the node. Fix: the viewport is the page's layout size; the container scales it to fit the slot (bounds = viewport, frame = slot, the 2H trick), never resizing the node.
- `browser.key`/`type` dispatch synthetic `KeyboardEvent`s from JS (`BrowserAutomation.swift:175-205`): `isTrusted == false`, so `:focus-visible`, default actions (Tab focus moves) and `:hover` never happen. Fix: AppKit `NSEvent`s sent to the `WKWebView` (trusted).
- `Container.offscreenFrame()` already keeps an unmounted page laid out: the base for headless panels.
- WebKit has no public reduced-motion override (checked: no `ReducedMotion` in the macOS SDK WebKit headers). Color scheme is real (`WKWebView.appearance`).

**Tech Stack:** Swift 6.2, WebKit (macOS 15 SDK, public API only), AppKit `NSEvent`.

**Spec:** user QA needs 2026-10-23 (6 items, pasted); item 6 decision: "Os dois" — headless by default, `--visible` puts it on the canvas.

## Global Constraints

- Public WebKit API only (no `_`-prefixed SPI).
- Leashes stay the only permission: a non-Shepherd terminal may open **only `browser`** panels; each is auto-leashed to its creator; it reaches only panels it created or is leashed to; close/move only its own. Max 8 open browser panels per non-Shepherd terminal (`tooMany` error past that). Shepherd rules unchanged.
- Headless panels: no canvas node, not in docks, listed by `panel.list` (with `placement: "headless"`) only to their creator, the admin, and the creator's leashed Shepherd; closed when the creator terminal is removed or its process exits.
- `--out` paths are written by the CLI process (relative to its cwd), never by the daemon; the daemon keeps writing only under `<root>/screens`.
- Init scripts and storage commands act on the panel's own data store only (`storage` isolated/workspace/global as opened).
- CLI: `collie browser <cmd>`; same params over MCP. Errors as `ProtocolError(.invalidArgs, …)` with the flag named.

## Review Focus

1. Headless page throttling: a page in no window (or an unordered window) may stop `requestAnimationFrame`/timers and render blank snapshots. Expected: animations run, screenshots match the visible case.
2. Scaled viewport input: click/hover at a ref in a 360-wide page shown at 0.6× hits the right element.
3. Tab order: `browser key Tab` ×3 from the page start focuses the 3rd tabbable element and `document.querySelector(':focus-visible')` is it; Shift+Tab goes back.
4. Full-page screenshot of a page with `100vh` hero: the hero keeps its viewport height (no stretch to the full document).
5. Tester terminal exits: its headless browsers close and their screenshots are removed (as panel close does today).

---

### Task 1: Viewport independent of the panel

**Files:** Modify `Sources/ColliePlugins/BrowserPanel.swift` (`Container`), `Sources/ColliePlugins/BrowserCommands.swift` (`resize`), `Sources/CollieProtocol/Plugins.swift` (resize spec). Test: `Tests/ColliePluginsTests/BrowserViewportTests.swift`.

**Interfaces:** Produces `browser.resize --width W [--height H] [--reset]` → `{width, height, scale}`; `Container.viewport: CGSize?`, `Container.scale: CGFloat` (fit, ≤ 1).

- [ ] **Step 1: Tests** `viewportKeepsNodeSize` (container in a 600×400 slot, resize to 360×800 → web frame 360×800, slot unchanged, scale = 0.5), `viewportWiderThanSlotScalesDown`, `resetFillsSlot`, `innerWidthIsViewport` (`window.innerWidth == 360` after resize), `widthBounds` (200 OK, 199 and 4097 rejected).
- [ ] **Step 2:** Container: with a viewport, `web.frame = viewport` inside a host view whose `bounds = viewport`, `frame` = fitted rect centered top in the slot (`scale = min(slot.w/vp.w, slot.h/vp.h, 1)`). Stop calling `PanelContentSizing.setContentSize` from `resize`. Height defaults to the current one. Width range 200–4096.
- [ ] **Step 3:** `swift test --filter BrowserViewportTests` → PASS. Commit `feat(browser): page viewport independent of the panel, scaled to fit`.

### Task 2: Media emulation

**Files:** Modify `BrowserCommands.swift`, `BrowserPanel.swift`, `BrowserAutomation.swift` (emulation script), `Plugins.swift`. Test: `Tests/ColliePluginsTests/BrowserEmulateTests.swift`.

**Interfaces:** `browser.emulate [--color-scheme light|dark|system] [--reduced-motion reduce|no-preference|system]` → `{colorScheme, reducedMotion, uncoveredSheets}`. State persists for the panel across navigations until changed.

- [ ] **Step 1: Tests** `colorSchemeDark` (`matchMedia('(prefers-color-scheme: dark)').matches == true` and a `@media (prefers-color-scheme: dark)` rule applies), `colorSchemeSystemResets`, `reducedMotionMatchMedia`, `reducedMotionCSSRule` (same-origin `@media (prefers-reduced-motion: reduce)` rule applies), `survivesNavigation`.
- [ ] **Step 2:** Color scheme: `web.appearance = .aqua / .darkAqua / nil`. Reduced motion (no public API): a `.atDocumentStart` script (all frames, page world) that overrides `matchMedia` for `prefers-reduced-motion` and rewrites the media text of CSSOM rules/`<link media>`/`<style media>` naming `prefers-reduced-motion` (re-applied on `DOMContentLoaded` and on new sheets via MutationObserver). Cross-origin sheets it can't read are counted in `uncoveredSheets`. Comment the ceiling: `// ponytail: CSSOM rewrite, no public WebKit override; cross-origin sheets reported, not covered`.
- [ ] **Step 3:** Tests PASS. Commit `feat(browser): emulate color scheme and reduced motion`.

### Task 3: Screenshots: full page, clip, --out

**Files:** Modify `BrowserCommands.swift` (`screenshot`), `Plugins.swift`, the CLI's plugin command printer (`Sources/collie/…` where `browser.*` results are printed). Test: `Tests/ColliePluginsTests/BrowserScreenshotTests.swift`, CLI test for `--out`.

**Interfaces:** `browser.screenshot [--full-page] [--clip x,y,w,h | --ref R] [--out PATH]` → `{path, width, height}` (path = `--out` when given).

- [ ] **Step 1: Tests** `clipRect` (100×50 clip → 100×50 × backing scale image), `clipByRef` (element rect), `fullPageHeight` (2000 px document in an 800 viewport → image height 2000 × scale), `fullPageKeepsVh` (Review Focus 4: a `100vh` element measures 800 in the image), `outCopiesRelativeToCwd` (CLI).
- [ ] **Step 2:** Clip: `WKSnapshotConfiguration.rect` (viewport coordinates; `--ref` resolves via the automation script's rect). Full page: tile — scroll by viewport height, snapshot each, stitch into one `CGContext`, restore scroll; do not resize the frame (keeps `vh`). Fixed/sticky elements repeating per tile is accepted; note it in the spec help text. Cap: 16384 px tall (error past it).
- [ ] **Step 3:** CLI: `--out` is consumed by the CLI (not sent): after the reply, copy `path` to `--out` (create parent dirs; overwrite), print the new path.
- [ ] **Step 4:** Tests PASS. Commit `feat(browser): full-page and clipped screenshots, --out`.

### Task 4: Trusted keyboard and mouse

**Files:** Create `Sources/ColliePlugins/BrowserInput.swift`; modify `BrowserCommands.swift` (`key`, `type`, `click`, new `hover`), `Plugins.swift`. Test: `Tests/ColliePluginsTests/BrowserInputTests.swift`.

**Interfaces:** `BrowserInput.key(_ web: WKWebView, _ spec: String)` (`Tab`, `Shift+Tab`, `Enter`, `Escape`, arrows, `Meta+a`…); `BrowserInput.type(_:_:)`; `BrowserInput.mouse(_:at: CGPoint, kind: .move|.click)`. `browser.hover --ref R`. `browser.click` and `browser.key` switch to trusted input; the old JS path stays only as fallback when the webview has no window (Step 1 decides).

- [ ] **Step 1: Spike (gate):** with `NSEvent.keyEvent`/`mouseEvent` sent via `web.keyDown(with:)` / `mouseMoved(with:)` / `mouseDown`+`mouseUp`, check `event.isTrusted`, Tab focus movement and `:focus-visible`, `:hover` — (a) web in the visible window, (b) web in a never-ordered offscreen `NSWindow`, (c) no window. Record results in the commit body. Headless (Task 6) uses the first variant that passes, preferring (b).
- [ ] **Step 2: Tests** `tabMovesFocusVisible` (Review Focus 3), `shiftTabBack`, `hoverAppliesHoverStyle` (computed style of a `:hover` rule), `clickIsTrusted`, `clickScaledViewport` (Review Focus 2: viewport 360 at scale 0.5 — point mapping through the container), `typeInsertsText`.
- [ ] **Step 3:** Implement; map page CSS px → view points through `Container.scale`; window/flip conversion in one helper.
- [ ] **Step 4:** Tests PASS. Commit `feat(browser): trusted keyboard and mouse input, hover`.

### Task 5: Storage, reload, init scripts

**Files:** Modify `BrowserCommands.swift`, `BrowserPanel.swift` (user content controller), `Plugins.swift`. Test: `Tests/ColliePluginsTests/BrowserStorageTests.swift`.

**Interfaces:** `browser.storage clear [--local] [--session] [--cookies]` (none = all), `browser.storage set --key K --value V` / `get --key K` (localStorage of the current origin); `browser.reload [--hard]`; `browser.init-script add --js JS` → `{id}`, `browser.init-script list|clear [--id]` (document-start, main frame, page world, run before page scripts; kept for the panel's life, not persisted).

- [ ] **Step 1: Tests** `clearLocalStorage`, `setThenReloadPersists`, `initScriptRunsBeforePage` (page reads `window.__x` set by the init script in its first inline script), `initScriptSurvivesNavigation`, `clearInitScripts`, `hardReloadBypassesCache` (`reloadFromOrigin`).
- [ ] **Step 2:** Implement: storage via `evaluateJavaScript` on the current origin; cookies via the panel's `websiteDataStore.httpCookieStore`; init scripts rebuild the controller's user scripts (automation + console scripts first, then init scripts in order).
- [ ] **Step 3:** Tests PASS. Commit `feat(browser): storage control, reload, init scripts`.

### Task 6: Tester browsers: headless and visible

**Files:** Modify `Sources/CollieDaemonKit/PanelCommands.swift`, `ConnectionGraph` (reachability), `CollieCore/Panels.swift` (`PanelPlacement.headless`), `Sources/CollieApp/*` (headless panels are hosted but never shown; docks/canvas skip them), `CommandRouter` (terminal exit/remove → close its headless panels), `Plugins.swift`/`Commands.swift` specs, README "Browser" section. Test: `Tests/CollieDaemonKitTests/PanelGatingTests.swift`.

**Interfaces:** `panel.open --plugin browser [--visible] [--url U] [--name N]` from a non-Shepherd → headless by default (placement `headless`), `--visible` → canvas node in the caller's paddock; either way a leash creator↔panel is added. Shepherds keep today's behavior and may also pass `--placement headless`.

- [ ] **Step 1: Tests** `testerOpensHeadlessBrowser`, `testerOpensVisibleBrowserLeashed`, `testerCannotOpenOtherPlugins` (`design`, `device` → `notShepherd`), `testerSeesOnlyOwnHeadless` (another tester's `panel.list` excludes it), `testerCap8`, `headlessClosesWithCreator` (Review Focus 5: remove/exit → panel gone, screenshots removed), `shepherdRulesUnchanged`.
- [ ] **Step 2:** Gating + placement + lifecycle in the daemon; app hosts headless panels per Task 4 Step 1's choice (offscreen window), never in docks or canvas; Review Focus 1 checked there (a rAF counter advances while headless).
- [ ] **Step 3:** README: tester browser flow (open headless, resize 360/768/1280 in three browsers in parallel, emulate, screenshot --out).
- [ ] **Step 4:** `swift test` → PASS. Commit `feat(panels): testers open their own browsers, headless or leashed on the canvas`.
