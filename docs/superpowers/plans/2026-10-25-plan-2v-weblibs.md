# Plan 2V — Offline web libraries (`collie-lib://`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** React + ReactDOM, htm, Chart.js and Lucide available offline to Collie's local pages under `collie-lib://lib/<name>@<version>/<file>`, pinned by version and SHA-256, so agents' pages and the starter templates use them without a CDN.

**Architecture:** A fetch script in the `build-drawio.sh` mould downloads the npm tarballs once, checks each SHA-256, and copies only the UMD files + licences into `vendor/weblibs/` with a `manifest.json`; `bundle-app.sh` copies it to `Contents/Resources/weblibs`. One `WKURLSchemeHandler` (`WebLibs`) serves it read-only; it is registered in the Prévia, the Browser (only for `collie-artifact://` documents) and the HTML import. The daemon reads the manifest for `collie artifact libs`.

**Tech Stack:** bash + curl + shasum + tar, Swift 6.2, WebKit.

**Spec:** `docs/superpowers/specs/2026-10-25-artifacts-design-like-design.md` (calls 3, 4).

**Parallelism:** Tasks 1–3 are independent of 2U and 2W (start now). Task 4 needs 2U merged (Prévia + templates). Expect a small conflict with 2U in `Plugins.swift` (artifacts commands) and the Artifacts line of `CollieOrientation.swift`.

## Global Constraints

- NEVER run the full test suite: only the tests a task creates or changes, `swift test --filter <TestClass>`.
- No real claude prompts in tests; no app launch in subagent work.
- Network only in `scripts/fetch-weblibs.sh` (npm registry tarballs, `https://registry.npmjs.org/<pkg>/-/<pkg>-<ver>.tgz`); nothing in Swift ever fetches.
- Pinned set (exact; the script header records the real tarball SHA-256 and the measured size): `react@18.3.1` → `umd/react.production.min.js`; `react-dom@18.3.1` → `umd/react-dom.production.min.js`; `htm@3.1.1` → `dist/htm.umd.js`; `chart.js@4.x` (latest 4.4 patch whose tarball has `dist/chart.umd.js`, MIT) → `dist/chart.umd.js`; `lucide@<exact>` (a version whose tarball has `dist/umd/lucide.min.js`, ISC) → `dist/umd/lucide.min.js`. Each with its `LICENSE`. No other file.
- Layout: `vendor/weblibs/<name>@<version>/<file basename>`, `vendor/weblibs/manifest.json` = `[{name, version, files: [basename], licence, global}]` (`global`: `React`, `ReactDOM`, `htm`, `Chart`, `lucide`). Total target ≤ 1 MB.
- URL form: `collie-lib://lib/<name>@<version>/<basename>`; anything else 404. Served only `GET`, `Content-Type: text/javascript; charset=utf-8`, `Access-Control-Allow-Origin: *`, `Cache-Control: immutable`.
- Only documents on `collie-preview` and `collie-artifact` main frames get files (external plug-ins: not now); any other main document (http, https, about) → 403.
- Licences: `Resources/NOTICE-weblibs` (one block per library: name, version, licence, copyright line) copied by `bundle-app.sh`; README credits.
- UI copy pt-BR; code/commits English. Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01PjAbEfJwb2ZH5ScKq3gEbN`

## Review Focus

1. A tarball whose SHA-256 differs from the pin (or a 404) → the script exits non-zero and leaves the existing `vendor/weblibs` untouched (writes to a temp dir, swaps at the end) (Task 1 verification).
2. `collie-lib://lib/react@18.3.1/../../manifest.json`, `%2e%2e`, an unknown version, a file not in the manifest → 404 (Task 2 test `refuses…`).
3. An https site open in the Browser that adds `<script src="collie-lib://lib/react@18.3.1/react.production.min.js">` → 403, `window.React` undefined (Task 2 test `httpDocumentRefused`).
4. A dev build without the script run (`vendor/weblibs` missing) → nothing crashes: the scheme answers 404, `artifact.libs` returns `unavailable` "Bibliotecas offline ausentes: rode scripts/fetch-weblibs.sh", templates show their no-library fallback (Tasks 2–4).
5. An agent page that renders with React is imported (`artifact add` → HTML import) → the snapshot sees the rendered DOM, not an empty root (Task 2 test `snapshotterServesLibs`).

---

### Task 1: Fetch script, manifest, bundle

**Files:**
- Create: `scripts/fetch-weblibs.sh`, `Resources/NOTICE-weblibs`
- Modify: `scripts/bundle-app.sh` (copy `vendor/weblibs` → `Contents/Resources/weblibs`, warning if missing, like drawio)

- [ ] **Step 1:** Script: a `LIBS` table (`name version path-in-tarball sha256 licence global`), download each tarball to a temp dir, `shasum -a 256` check, extract only the listed file + `LICENSE` (`tar -xzf … package/<path> package/LICENSE`), write `manifest.json` (from the table, `printf`, no jq), then replace `vendor/weblibs` atomically (`mv` of the temp tree). Idempotent; `--print-sums` prints the computed sums without checking (only to fill the pins once). Header comment: pinned versions, measured total size.
- [ ] **Step 2:** Pick the exact Chart.js 4.4.x and Lucide versions (check the tarball contains the UMD path with `tar -tzf`), run `--print-sums`, paste the sums into the table, run the script normally.
- [ ] **Step 3: Verify:** `scripts/fetch-weblibs.sh` → `ok: vendor/weblibs (<size>)`; edit one pin's last hex digit → script fails with "sha256 mismatch: <name>" and `vendor/weblibs` is unchanged (`shasum` of the manifest before/after); restore the pin.
- [ ] **Step 4: Commit** `build: vendor pinned offline web libraries (React, htm, Chart.js, Lucide)`.

### Task 2: `collie-lib://` scheme

**Files:**
- Create: `Sources/ColliePlugins/WebLibs.swift`
- Modify: `Sources/ColliePlugins/BrowserPanel.swift:45` (register), `Sources/ColliePlugins/HTMLSnapshotter.swift:109` (register; its navigation allow-list adds `collie-lib`)
- Test: `Tests/ColliePluginsTests/WebLibsTests.swift`, `Tests/ColliePluginsTests/HTMLSnapshotterTests.swift`

**Interfaces:**
- Produces: `enum WebLibs { static let scheme = "collie-lib"; static let directory: URL? }` (Resources `weblibs`, then `vendor/weblibs` in DEBUG, like `DiagramPanel.webDirectory`; nil when no `manifest.json`); `struct WebLibEntry: Codable, Sendable { name, version, files: [String], licence, global: String }`; `static func manifest(in dir: URL) -> [WebLibEntry]`; `final class WebLibSchemeHandler: NSObject, WKURLSchemeHandler { init(directory: URL?); func serve(_ r: URLRequest) -> (Int, [String: String], Data) }`.
- Produces: `WebLibs.url(_ name: String, in entries: [WebLibEntry]) -> String?` (first file's URL) for Task 3/4.

- [ ] **Step 1: Tests** (fixture dir with a fake `manifest.json` and a tiny `react.production.min.js` that sets `window.React = {ok:1}`): `servesManifestFile` (200, headers as in Global Constraints), `refusesTraversal`, `refusesUnknownVersion`, `refusesFileNotInManifest`, `refusesPost`, `missingDirectoryIs404`, `httpDocumentRefused` (a request whose `mainDocumentURL` is `https://x` → 403), `previewDocumentAllowed` (`collie-preview://app/…` → 200), `snapshotterServesLibs` (in `HTMLSnapshotterTests`: artifact page that does `document.body.textContent = React ? "ok" : "no"` → snapshot text "ok").
- [ ] **Step 2:** `swift test --filter WebLibsTests` and `--filter HTMLSnapshotterTests` → FAIL.
- [ ] **Step 3:** Implement; path checked against the manifest (no file-system lookup of arbitrary names), file read once and cached in memory.
- [ ] **Step 4:** filters → PASS.
- [ ] **Step 5: Commit** `feat(weblibs): collie-lib:// scheme for local pages`.

### Task 3: `artifact.libs`, orientation, README

**Files:**
- Modify: `Sources/CollieProtocol/Plugins.swift` (`acmd("libs", …)`), `Sources/CollieDaemonKit/ArtifactCommands.swift`
- Modify: `Sources/CollieDaemonKit/CollieOrientation.swift:54`, `README.md` (subsection "Bibliotecas offline" under Artifacts), `Sources/CollieDaemonKit/Daemon.swift` or wherever the daemon finds `figcraft` (same lookup for `weblibs`: `COLLIE_WEBLIBS_DIR`, then the app's Resources)
- Test: `Tests/CollieDaemonKitTests/ArtifactTests.swift`, `Tests/CollieDaemonKitTests/CollieOrientationTests.swift`

**Interfaces:**
- Consumes: `WebLibEntry` shape (decode the same JSON in the daemon; `CollieDaemonKit` doesn't import WebKit — put `WebLibEntry` + `manifest(in:)` in `CollieCore/WebLibManifest.swift` and have `WebLibs` use it).
- Produces: `artifact.libs` → `[{name, version, global, url, licence}]`, `panelFree`, terminal or admin.

- [ ] **Step 1: Tests** `libsListsManifest` (fixture dir via `COLLIE_WEBLIBS_DIR`), `libsMissingIsUnavailable` (message "Bibliotecas offline ausentes: rode scripts/fetch-weblibs.sh"), orientation worst case ≤ 1300 with the new text.
- [ ] **Step 2:** filters → FAIL.
- [ ] **Step 3:** Implement. Orientation: append to the Artifacts line `No CDN: offline React/htm/Chart.js/Lucide URLs from collie artifact libs.` (tight variant: `libs: artifact libs`).
- [ ] **Step 4:** filters → PASS. README: what's there, URL form, `<script src>` example with React + htm, "sem JSX: use htm", where licences are.
- [ ] **Step 5: Commit** `feat(weblibs): artifact libs and agent orientation`.

### Task 4: Prévia + templates use the libraries (after 2U merges)

**Files:**
- Modify: `Sources/ColliePlugins/PreviewPanel.swift` (register `WebLibSchemeHandler`)
- Modify: `Sources/CollieDaemonKit/Artifacts/ArtifactTemplates.swift` (dashboard, prototype, icons)
- Test: `Tests/CollieDaemonKitTests/ArtifactTemplateTests.swift`, `Tests/ColliePluginsTests/PreviewPanelTests.swift`

**Interfaces:**
- Consumes: 2U `ArtifactTemplates.render(_:title:tokensCSS:)` — gains `libs: [WebLibEntry]` (empty = 2U's library-free output, unchanged).
- Produces: dashboard: Chart.js bar + line chart from the same `data` array; prototype: React + htm components (`html\`<${App}/>\``); all four: Lucide icons via `lucide.createIcons()` on `<i data-lucide="…">`. Each guarded: library global missing → the 2U vanilla rendering plus a muted note "Bibliotecas offline indisponíveis".

- [ ] **Step 1: Tests** `templatesUseVersionedLibURLs` (dashboard contains the manifest's Chart.js URL; prototype React, ReactDOM, htm), `templatesWithoutLibsUnchanged` (`libs: []` output equals 2U's), `everyKindIsOffline` still passes (allow only `collie-lib://` as an external `src`), `previewLoadsLibs` (Prévia page with the fixture React → `window.React` defined).
- [ ] **Step 2:** filters → FAIL.
- [ ] **Step 3:** Implement; `artifact.new` passes the daemon's manifest entries (missing dir → `[]`, warning "bibliotecas offline ausentes").
- [ ] **Step 4:** filters → PASS.
- [ ] **Step 5: Manual (user):** `collie artifact new dashboard` → Chart.js chart; `prototype` → React app; switch Claro/Escuro.
- [ ] **Step 6: Commit** `feat(artifacts): templates use the offline libraries`.
