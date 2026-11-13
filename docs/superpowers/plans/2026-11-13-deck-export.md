# Deck Export (PPTX editable + PDF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `collie artifact export <id> --format pptx|pdf [--out path]` plus an **Exportar** menu in the Artifacts panel, producing an editable `.pptx` (real text, shapes, pictures, notes) or a PDF from a `.slide` HTML deck.

**Architecture:** The app (has WebKit) renders the artifact page and answers two new host commands: `deck.snapshot` (one DOM snapshot per slide, written to `<artifact>/.export/`) and `deck.pdf` (PDF written to the same folder). The headless daemon turns the snapshot into a `.pptx` with a pure-Swift `PPTXWriter` + store-only `ZipWriter`, then optionally copies the file to `--out`.

**Tech Stack:** Swift (SwiftPM targets `CollieDaemonKit`, `ColliePlugins`, `CollieProtocol`, `CollieApp`), WebKit (`WKWebView.pdf`), PDFKit, zlib `crc32`, swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-13-deck-export-design.md`

## Global Constraints

- No new dependency, no external runtime. ZIP is store-only (no deflate).
- Export never touches the network: reuse the snapshot web view's lockdown (`HTMLSnapshotter.ruleList`, `WebLockdown.harden`).
- Host replies cap at 1 MiB: results go to files in `<artifactsRoot>/<id>/.export/`; replies carry names only.
- Design-import output stays byte-identical: `HTMLSnapshotScript.userScript` is unchanged when deck mode is off; existing `HTMLSnapshotterTests` and `ArtifactImportTests` pass unmodified.
- Slide size 12192000×6858000 EMU. Scale per slide = `12192000 / slide.w` EMU per CSS px (9525 for w=1280). Font size: `sz = round(px × 0.75 × 100)` (hundredths of a point).
- PDF page size 960×540 pt (px × 0.75), screen media, backgrounds printed, vector text.
- Deck selectors: `.slide`, then `[data-slide]`. Bare `section` is never a fallback. None found → `ProtocolError(.invalidArgs, "page has no slides")`.
- Notes: a direct child `<aside>` of a slide whose computed `display` is `none`. A visible `<aside>` stays content.
- Output: daemon always writes `<artifact>/.export/deck.<pptx|pdf>` (temp file + rename, overwritten). Call timeout 60 s. Design exports (`kind == .export`) → `invalidArgs` "design exports have no slides".
- `--out`: a terminal caller may only write under its own cwd (real path, symlinks resolved, `..` rejected); the app (admin token) may write anywhere. Otherwise `unauthorized` with "use collie access request" hint.
- Tests: run only the named test with `swift test --scratch-path .build/Collie-Main --filter <Name>`. Never the full suite.
- Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Commit only the hunks of your task (`git add` by path; `git diff <file>` first).

## Review Focus

1. Text with XML-invalid or special characters (`& < > "`, control chars U+0000–U+001F, emoji): the `.pptx` stays valid XML and shows the text (Task 5).
2. Text with newlines (`<br>`, `white-space: pre`): one paragraph per line, not one long line (Task 5).
3. Slide with zero/huge `w`/`h` or `NaN` values in the (untrusted) snapshot: no crash, no giant shapes; values clamped, shape dropped with a warning (Task 5).
4. A slide that stays `display:none` after isolation (no `.on` class convention): still exported, not an empty slide (Task 2).
5. `--out` that is an existing file, a symlink escaping the project, or `..`-relative: refused or overwritten atomically, never written through the link (Task 6).

---

### Task 1: ZipWriter

**Files:**
- Create: `Sources/CollieDaemonKit/Artifacts/ZipWriter.swift`
- Test: `Tests/CollieDaemonKitTests/ZipWriterTests.swift`

**Interfaces:**
- Produces:
  - `enum ZipWriter { static func crc32(_ data: Data) -> UInt32 ; static func archive(_ entries: [(name: String, data: Data)]) throws(ZipError) -> Data }`
  - `enum ZipError: Error, Equatable { case tooLarge }` (more than 65535 entries, or any size/offset above `UInt32.max`: no zip64)

- [ ] **Step 1: Write failing tests** in `ZipWriterTests`: `crcMatchesKnownVector` (`crc32(Data("123456789".utf8)) == 0xCBF43926`); `archiveReadsBackWithUnzip` (write 2 entries `a.txt`="hello", `dir/b.bin`=256 bytes 0…255 to a temp file; `/usr/bin/unzip -t` exit 0; `unzip -p … dir/b.bin` bytes equal); `tooManyEntriesThrows` (70 000 empty entries → `.tooLarge`); `emptyDataEntry` (entry with `Data()` passes `unzip -t`).
- [ ] **Step 2: Run** `swift test --scratch-path .build/Collie-Main --filter ZipWriterTests` → FAIL (type missing).
- [ ] **Step 3: Implement `ZipWriter`**: method 0 (stored), local header + data per entry, central directory, end record; `crc32` via `zlib.crc32`; UTF-8 names with general-purpose flag bit 11; fixed DOS date 2026-01-01.
- [ ] **Step 4: Run** the same filter → PASS.
- [ ] **Step 5: Commit** `feat: store-only ZipWriter for .pptx`.

### Task 2: Deck mode in the snapshot script

**Files:**
- Modify: `Sources/ColliePlugins/HTMLSnapshotScript.swift` (add `static let deckUserScript: String`; extend `source` with deck-only branches guarded by `const DECK = window.__collieDeck === true`)
- Modify: `Sources/CollieDaemonKit/Design/HTMLImport.swift` (DOMNode: `var list: DOMList? = nil`; new `struct DOMList: Decodable, Sendable { var kind: String; var index: Int; var depth: Int }`)
- Test: `Tests/ColliePluginsTests/HTMLSnapshotterTests.swift` (new tests, existing untouched)

**Interfaces:**
- Produces: `HTMLSnapshotScript.deckUserScript` posts JSON `{title, slides: [{index, w, h, background, notes, pseudo, root}], blocked, truncated}`. `root` has the usual node shape with slide-relative `x,y` (slide's top-left = 0,0). `li` nodes carry `list: {kind: "ul"|"ol", index (1-based), depth (0-based)}`. `svg` nodes also carry `image: {data (PNG base64), w, h, fit: "fill"}` (canvas raster at ≤2× the box, same caps as images) besides `svg`. `background`: the slide's computed `backgroundColor` (or first color stop of a `linear-gradient`), `pseudo`: count of elements in the slide whose `::before`/`::after` computed `content` is not `none`/`normal`.
- Slide isolation per slide: hide every other slide (`display:none !important`); if the slide's computed `display` is `none`, add class `on`, and if still `none` set inline `display:block`; then set inline `transform:none; left:0; top:0; margin:0; position:relative`. `w,h` = its `getBoundingClientRect()` after this. Hidden direct-child `<aside>` text → `notes` (removed from the snapshot); aside text is `textContent` trimmed.
- Fallback: no `.slide`/`[data-slide]` → script posts `{error: "no slides"}`.

- [ ] **Step 1: Write failing tests** (load an inline HTML via the existing test helper pattern in `HTMLSnapshotterTests`, calling `HTMLSnapshotter.snapshot(url:…, deck: true)` — Task 3 adds the `deck` parameter; here test through a helper that runs `deckUserScript` the same way the existing tests run `userScript`):
  - `deckTemplateSlidesAreIsolated`: 3 `.slide` sections, only first has class `on`, all scaled with inline `transform: translate(-50%,-50%) scale(.5)`; expect 3 slides, each `w == 1280`, `h == 720`, root `x == 0`.
  - `deckSlideWithoutOnClassIsStillExported` (Review Focus 4): slides default `display:none` with no `.on` rule → 2 slides with non-empty children.
  - `deckListInfo`: `<ul><li>a</li><li>b</li></ul><ol><li>c</li></ol>` → list `{ul,1,0}`, `{ul,2,0}`, `{ol,1,0}`; nested `ul` inside `li` has depth 1.
  - `deckNotesFromHiddenAside`: hidden `<aside>nota</aside>` → `notes == "nota"` and no `aside` node; a visible `<aside>` stays a node and `notes == nil`.
  - `deckSvgGetsPng`: inline `<svg>` → node has `svg` and `image.data` non-empty.
  - `deckPseudoCount`: `li::before{content:"x"}` on 2 items → `pseudo == 2`.
  - `deckNoSlidesIsAnError`: page without `.slide` → error text contains `no slides`.
  - `importOutputUnchanged`: existing `userScript` string has no `__collieDeck` reference.
- [ ] **Step 2: Run** `--filter HTMLSnapshotterTests` → new tests FAIL, old PASS.
- [ ] **Step 3: Implement** `deckUserScript` = same wrapper as `userScript` with `window.__collieDeck = true;` prepended; deck branch at the end of `source` loops over slides, calling the existing `walk(slide, null)` per slide (image jobs awaited per slide, counters shared) and builds the JSON above. List info is added in `walk` only when `DECK`. Add `DOMList`/`list` to `DOMNode`.
- [ ] **Step 4: Run** `--filter HTMLSnapshotterTests` → all PASS. Also `--filter ImportCaseTests` (decoder change) → PASS.
- [ ] **Step 5: Commit** `feat: per-slide DOM snapshot mode for deck export`.

### Task 3: App host commands `deck.snapshot` and `deck.pdf`

**Files:**
- Create: `Sources/ColliePlugins/DeckExporter.swift`
- Modify: `Sources/ColliePlugins/HTMLSnapshotter.swift` (extract `static func hardenedConfiguration(artifactsRoot: URL, libs: URL?) async throws(ProtocolError) -> WKWebViewConfiguration` from `snapshot`; add `deck: Bool = false` to `snapshot(url:artifactsRoot:width:timeout:libs:)` choosing `deckUserScript`; extract `nonisolated static func extractPayloads(_ root: JSONValue, images: inout Int, svgs: inout Int) -> (JSONValue, [(String, Data)])` out of `store`'s inner `external`, `store` calls it)
- Modify: `Sources/CollieApp/CollieApp.swift:337` (route `deck.snapshot`/`deck.pdf` to `DeckExporter.handle`)
- Test: `Tests/ColliePluginsTests/DeckExporterTests.swift`

**Interfaces:**
- Consumes: Task 2's `deckUserScript`; `HTMLSnapshotter.importFolder`-style folder check.
- Produces: `@MainActor enum DeckExporter { static let exportDir = ".export"; static func handle(command: String, args: [String: JSONValue], artifactsRoot: URL, timeoutSeconds: Double) async throws(ProtocolError) -> JSONValue }`.
  - `deck.snapshot {id, url, width?}` → writes `.export/slides.json` (`{title, slides, blocked, truncated}` with `image.data`/`svg` moved to `img-N.png`/`svg-N.svg` via `extractPayloads`) → reply `{file: ".export/slides.json", slides: <count>, blocked: <count>, truncated}`.
  - `deck.pdf {id, url}` → writes `.export/deck-app.pdf` (one 960×540 pt page per slide, merged with PDFKit) → reply `{file: ".export/deck-app.pdf", slides: <count>}`. Implementation: load with `hardenedConfiguration`, run JS to list slides and isolate slide *i* (same isolation as Task 2, exposed as `HTMLSnapshotScript.isolateSlide(i)` JS snippet), `WKWebView.pdf(configuration:)` with rect `0,0,w,h`, page rescaled by 0.75.
  - Both: `id` must be an artifact UUID (as `html.snapshot`), `url` must be `collie-artifact://app/…`; `.export` replaced per run (0700), never through a symlink.

- [ ] **Step 1: Write failing tests** in `DeckExporterTests`: `snapshotWritesSlidesJson` (3-slide fixture page in a temp artifacts root → `slides.json` exists, decodes with 3 slides, `img-1.png` exists for a slide with an `<img>`); `pdfHasOnePagePerSlide` (`PDFDocument(url:)?.pageCount == 3`, first page bounds `960×540`, `page.string` contains the slide's text → selectable text); `rejectsBadId` (`ProtocolError.invalidArgs`); `rejectsForeignScheme` (`https://…` → `invalidArgs`); `noSlidesIsInvalidArgs` (message contains `no slides`).
- [ ] **Step 2: Run** `--filter DeckExporterTests` → FAIL.
- [ ] **Step 3: Implement** the refactors and `DeckExporter`. Map the script's `{error:"no slides"}` to `ProtocolError(.invalidArgs, "page has no slides")`.
- [ ] **Step 4: Run** `--filter DeckExporterTests`, then `--filter HTMLSnapshotterTests` → PASS (refactor safe).
- [ ] **Step 5: Commit** `feat: app-side deck snapshot and PDF`.

### Task 4: PPTXWriter — package, slides, text

**Files:**
- Create: `Sources/CollieDaemonKit/Artifacts/PPTXWriter.swift`, `Sources/CollieDaemonKit/Artifacts/DeckSnapshot.swift`
- Test: `Tests/CollieDaemonKitTests/PPTXWriterTests.swift`

**Interfaces:**
- Consumes: `ZipWriter.archive`, `DOMNode`, `DOMRun`.
- Produces:
  - `struct DeckSlide: Decodable, Sendable { var index: Int; var w: Double; var h: Double; var background: String?; var notes: String?; var pseudo: Int?; var root: DOMNode }`
  - `struct DeckSnapshot: Decodable, Sendable { var title: String; var slides: [DeckSlide]; var blocked: [String]; var truncated: Bool }`
  - `enum PPTXWriter { static func build(_ deck: DeckSnapshot, payloads: [String: Data]) throws(PPTXError) -> (data: Data, warnings: [String]) }`, `enum PPTXError: Error, Equatable { case noSlides, tooLarge }`
  - `enum CSSColor { static func parse(_ css: String) -> (hex: String, alpha: Int)? }` (`rgb(r, g, b)` / `rgba(r, g, b, a)`; alpha 0…100000; fully transparent → `nil`)
  - Units: `emu(_ px: Double, scale: Double) -> Int` clamps to ±(2^31−1); non-finite → 0.
- Package contents: `[Content_Types].xml`, `_rels/.rels`, `ppt/presentation.xml` (size above), `ppt/_rels/presentation.xml.rels`, one slide master + one blank layout, `ppt/slides/slide<N>.xml` with its `_rels`, `docProps/app.xml`, `docProps/core.xml` (title = deck title).
- Text mapping (leaf = node with `text`): one `p:sp` (`txBox="1"`) at the node's box; insets from `paddingTop/Right/Bottom/Left`; `wrap="square"`, no autofit, anchor top; one `a:p` per `\n` line; runs by `runs` UTF-16 offsets over the node's text, base props from `style` (`fontFamily` first family → `a:latin typeface`, `fontSize`, `fontWeight` ≥ 600 → `b="1"`, `fontStyle: italic`, `color`, `textDecorationLine` underline, `textAlign` → `algn` l/ctr/r/just), run overrides win; run `href` → `a:hlinkClick` with slide rel. `#text` nodes are text boxes the same way. Slide background → `p:bg` solid fill (`CSSColor`); a gradient (`linear-gradient(`) → first color stop plus warning `"slide <n>: gradient background → first color"`.
- Warnings built here: `"fonts not embedded: <A>, <B>"` (sorted unique first families, only when any), `"pseudo-element content dropped (<k> elements)"` when summed `pseudo` > 0.

- [ ] **Step 1: Write failing tests** in `PPTXWriterTests` using a small helper `unzip(_ data: Data) -> [String: Data]` (via `/usr/bin/unzip -p` per name from `unzip -Z1`): `buildsOneSlidePerSlide` (3 slides → `ppt/slides/slide1.xml…slide3.xml` exist, `presentation.xml` contains `cx="12192000" cy="6858000"`); `textBoxIsRealText` (leaf `"Olá mundo"`, 28 px → `<a:t>Olá mundo</a:t>` and `sz="2100"`); `runsKeepBoldAndColor` (run over "mundo": weight 700, color `rgb(110, 231, 183)` → `b="1"` and `srgbClr val="6EE7B7"`); `scaleFollowsSlideWidth` (slide `w=640` → a box at x=64 px has `a:off x="1219200"`, since 12192000 / 640 = 19050 EMU per px); `backgroundSolid` and `backgroundGradientWarns`; `fontsWarningListsFamilies`; `everyPartIsWellFormedXML` (parse each `.xml` with `XMLParser`, no error); `noSlidesThrows`.
- [ ] **Step 2: Run** `--filter PPTXWriterTests` → FAIL.
- [ ] **Step 3: Implement** types and `build`. XML escaping function `xmlEscape(_:)` is added here and also strips characters invalid in XML 1.0 (keeps `\t`, `\n`, `\r`, U+0020+ except surrogates/U+FFFE/U+FFFF). Content types for `png`, `xml`, `rels`.
- [ ] **Step 4: Run** `--filter PPTXWriterTests` → PASS.
- [ ] **Step 5: Commit** `feat: PPTXWriter with slides and editable text`.

### Task 5: PPTXWriter — shapes, pictures, lists, notes, hardening

**Files:**
- Modify: `Sources/CollieDaemonKit/Artifacts/PPTXWriter.swift`
- Test: `Tests/CollieDaemonKitTests/PPTXWriterTests.swift`

**Interfaces:**
- Consumes: Task 4 (`CSSColor.parse`, `emu`, `xmlEscape`, `build`).
- Produces: no new public names; `build` now handles all rows of the mapping table.
- Rules:
  - Shape: node with non-transparent `backgroundColor` or any side with `border*Width` > 0 and `borderTopStyle != none` → `p:sp` `prstGeom` `rect`, or `roundRect` with `adj = min(radius / min(w, h), 0.5) × 100000` (radius = `borderTopLeftRadius` px) ; fill with `a:alpha` when alpha < 100000; border `a:ln w=emu(borderTopWidth)` colour `borderTopColor`; non-uniform side widths → top width + warning `"non-uniform borders approximated (<k>)"`. A text leaf that also has fill/border emits the shape, then its text box on top.
  - Document order = z-order. `boxShadow`, `clipPath` non-empty → dropped, warnings `"box-shadow dropped (<k> elements)"`, `"clip-path dropped (<k> elements)"`. `overflow` hidden/clip with a child that exceeds the parent box → warning `"overflow:hidden ignored (<k>)"`.
  - Picture: `image.file` found in `payloads` → `p:pic` + `ppt/media/image<N>.png` (deduplicated by file name); `fit: cover` → `a:srcRect` crop (l/r or t/b, 1/1000 %) so the image fills the box at its aspect; `contain` → picture shrunk and centered in the box; `fill` → stretched. Missing payload → skip + warning `"image missing: <file>"`. Node with both `svg` and `image` uses the `image`.
  - Lists: leaf with `list` → paragraph with `a:buChar char="•"` (ul) or `a:buAutoNum type="arabicPeriod" startAt="<index>"` (ol); text box left edge extended by `1.5 × fontSize` px, `marL = round(1.5 × fontSize px in EMU)`, `indent = -marL`; nested depth adds `depth × marL`.
  - Notes: slide `notes` non-empty → `ppt/notesSlides/notesSlide<N>.xml` + one `notesMaster`, related from the slide.
  - Hardening: non-finite or `|value| > 1e6` coordinates are clamped; a node with `w <= 0` or `h <= 0` after clamp (and no children) is dropped with warning `"slide <n>: dropped <k> invalid boxes"`. Total node count over 20 000 → `PPTXError.tooLarge`. Payload PNG larger than 4 MiB is skipped (warning as missing).

- [ ] **Step 1: Write failing tests**: `roundedBoxHasAdj` (400×200 box, radius 20 → `prst="roundRect"`, `adj` val `10000`); `fillAlpha` (`rgba(255,255,255,0.5)` → `<a:alpha val="50000"/>`); `borderBecomesLine`; `coverImageIsCropped` (200×100 image into 100×100 box → `srcRect l="25000" r="25000"`); `containImageIsCentered`; `missingImageWarns`; `bulletsAndNumbers` (ul item → `buChar`, ol item index 3 → `startAt="3"`); `notesPartExists`; `shadowAndClipWarn`; **Review Focus** `xmlSpecialCharsStayValid` ("A & B <c> \u{0}😀" → every part parses with `XMLParser`; slide XML contains `A &amp; B &lt;c&gt;` and the emoji, no NUL); `newlinesBecomeParagraphs` ("l1\nl2" → two `a:p`); `invalidBoxesAreClampedOrDropped` (NaN/1e12 coordinates, `w = 0` → no crash, warning present, valid XML).
- [ ] **Step 2: Run** `--filter PPTXWriterTests` → new tests FAIL.
- [ ] **Step 3: Implement** the rules above in `PPTXWriter`.
- [ ] **Step 4: Run** `--filter PPTXWriterTests` → PASS.
- [ ] **Step 5: Commit** `feat: PPTX shapes, pictures, lists and notes`.

### Task 6: `artifact.export` command

**Files:**
- Create: `Sources/CollieDaemonKit/ArtifactExport.swift`
- Modify: `Sources/CollieProtocol/Plugins.swift` (artifact `acmd("export", …)` after `reexport`), `Sources/CollieDaemonKit/ArtifactCommands.swift` (`case "artifact.export"` next to `artifact.reexport`; keep it out of the app-only list so terminals may call it)
- Test: `Tests/CollieDaemonKitTests/ArtifactExportTests.swift`

**Interfaces:**
- Consumes: `host.callApp(command:args:timeout:)`, `artifacts.get(_:)`, `PPTXWriter.build`, `DeckSnapshot`.
- Produces:
  - spec: `acmd("export", "Export a slide-deck page as an editable PowerPoint (.pptx) or a PDF (needs the Collie app); returns {path, format, slides, warnings} (ignores --panel)", [artifactId, ParamSpec("format", .string, required: true, help: "pptx | pdf"), ParamSpec("out", .string, help: "Also copy the file here (a terminal: inside its project)")], timeout: 60)`
  - `extension CommandRouter { func exportDeck(_ id: UUID, format: String, out: String?, caller: TerminalRecord?, cwd: String?) async throws -> JSONValue }`
  - Flow: `artifacts.get`; `kind == .export` → `invalidArgs` "design exports have no slides"; unknown `format` → `invalidArgs` "format must be pptx|pdf"; url `collie-artifact://app/\(a.source ?? "\(a.folder)/source.html")`; pptx: `callApp("deck.snapshot")` → read `<folder>/.export/slides.json` + payloads off the pool without following links (same `openat`/`O_NOFOLLOW` pattern and caps as `readImport`; delete `.export` snapshot files after) → `PPTXWriter.build` → write `deck.pptx` temp + rename; pdf: `callApp("deck.pdf")` → rename `deck-app.pdf` to `deck.pdf`. Reply `{path: <absolute path>, format, slides, warnings: [String]}` (blocked URLs reported as warnings `"blocked: <url without query>"`). `out`: resolved against `cwd`; terminal callers must resolve under their cwd (Review Focus 5: `..`, symlinked parent escaping, `out` a directory → `invalidArgs`); copy via temp file + rename in the target directory (never writes through an existing symlink); reply `path` becomes the `out` path.

- [ ] **Step 1: Write failing tests** in `ArtifactExportTests` with a `FakeApp` like `ArtifactImportTests` (handles `deck.snapshot` by copying a fixture `Tests/Fixtures/deck-export/slides.json` (+ `img-1.png`) to `<id>/.export/`, and `deck.pdf` by writing a tiny valid PDF): `exportsPptxFromSnapshot` (adds an agent page via `artifact.add`, then `artifact.export --format pptx` → reply `slides == 2`, file at `path` unzips to `ppt/slides/slide2.xml`); `exportsPdf`; `rejectsDesignExport`; `rejectsBadFormat`; `outCopiesAndReplaces` (existing file replaced); **Review Focus** `terminalOutOutsideProjectIsRefused` (`out: "../x.pptx"` and a symlink pointing outside → error code `unauthorized`, no file written outside); `adminMayWriteAnywhere`; `noSlidesFromAppIsInvalidArgs` (fake app throws `invalidArgs "page has no slides"` → same code and message reach the caller); `blockedUrlsBecomeWarningsWithoutQuery`.
- [ ] **Step 2: Run** `--filter ArtifactExportTests` → FAIL.
- [ ] **Step 3: Implement** `exportDeck` and wire spec + router case. `swift test` for `CollieProtocolTests` that list command specs: run `--filter CollieProtocolTests` to catch spec-table assertions.
- [ ] **Step 4: Run** `--filter ArtifactExportTests` and `--filter CollieProtocolTests` → PASS.
- [ ] **Step 5: Commit** `feat: artifact.export (pptx, pdf)`.

### Task 7: Exportar menu in the Artifacts panel

**Files:**
- Modify: `Sources/ColliePlugins/ArtifactsPanel.swift` (model `export` next to `reexport` at ~301; `Menu("Exportar")` in the detail buttons next to "Abrir na Prévia" at ~633)
- Test: `Tests/ColliePluginsTests/ArtifactsPanelTests.swift`

**Interfaces:**
- Consumes: `artifact.export {id, format, out}`.
- Produces: `public func export(_ row: ArtifactRow, format: String, to url: URL) async -> String?` — returns the written path on success, `nil` and sets `error` otherwise. View: `Menu("Exportar") { Button("PowerPoint (.pptx)"); Button("PDF") }` shown when `!r.isExport`; each opens an `NSSavePanel` (`allowedContentTypes` pptx/pdf, name = sanitized title) and calls `export`; on success `NSWorkspace.shared.activateFileViewerSelecting([url])`. Busy state reuses `model.busy` (buttons already `.disabled(model.busy)`). A failure shows the daemon's message (e.g. "page has no slides") in the panel's existing error line.

- [ ] **Step 1: Write failing tests** (same fake `send` pattern as the existing `reexport` tests): `exportSendsIdFormatAndOut`; `exportReturnsPathOnSuccess`; `exportFailureSetsError` (fake returns nil/error "page has no slides" → `model.error` contains it, return `nil`); `exportKeepsBusyOffAfterwards`.
- [ ] **Step 2: Run** `--filter ArtifactsPanelTests` → FAIL.
- [ ] **Step 3: Implement** model method and the menu.
- [ ] **Step 4: Run** `--filter ArtifactsPanelTests` → PASS.
- [ ] **Step 5: Commit** `feat: Exportar menu in the Artifacts panel`.

### Task 8: Docs and real-deck check

**Files:**
- Modify: the project's command reference where `artifact reexport`/`artifact import` are documented (find with `grep -rn "artifact import" README.md docs Sources/CollieDaemonKit/CollieOrientation.swift`), adding `artifact export` with one example each for pptx and pdf and the list of known losses (gradients, shadows, clip-path, pseudo-elements, web fonts not embedded).
- Test: `Tests/CollieDaemonKitTests/` orientation/help test, if one pins the command list (run `--filter` on whichever test file `grep -rln "artifact.import" Tests` shows for orientation).

- [ ] **Step 1:** Add the docs.
- [ ] **Step 2: Manual check** with the app built from this branch: `collie artifact add docs/videos/…/deck` is not needed — add the Collie deck from the earlier session's HTML or the `deck` template (`collie artifact new deck demo`), then `collie artifact export <id> --format pptx --out /tmp/…` and `--format pdf`. Open the `.pptx` in PowerPoint and Keynote: text editable, slide count matches, notes present, warnings list shown. Record results (what looked wrong) in the PR description.
- [ ] **Step 3: Run** the orientation/help test from Task 8's file list → PASS.
- [ ] **Step 4: Commit** `docs: artifact export`.

---

## Self-review

- Spec coverage: command + panel menu (Tasks 6, 7), slide-per-`.slide`, notes, editable text/shapes/pictures/lists (Tasks 4–5), SVG as picture via PNG (Task 2), PDF 960×540 selectable (Task 3), snapshot extension behind a flag with byte-identical import (Tasks 2–3), output location/`--out`/rename (Task 6), deck detection and `no slides` error (Tasks 2, 6), 60 s timeout (Task 6 spec), warnings (Tasks 4–6), fonts listed not embedded (Task 4), docs/manual check (Task 8).
- One deviation from the spec: the spec says the Exportar menu shows only when the page has slides (a scan of `source.html`). The plan shows it for every agent page and lets the command return `page has no slides`, because scanning each source file on every `artifact.list` is costly with 200+ artifacts. Design exports (`kind == .export`) are excluded.
- Types used across tasks match: `DeckSnapshot`/`DeckSlide`/`DOMList` (Tasks 2, 4, 6), `DeckExporter.exportDir == ".export"` and the file names `slides.json`, `img-N.png`, `svg-N.svg`, `deck-app.pdf` (Tasks 3, 6), `PPTXWriter.build(_:payloads:)` (Tasks 4–6).
