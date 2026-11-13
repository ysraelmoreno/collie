# Deck export (PPTX editable + PDF) — design

Date: 2026-11-13. Status: draft for approval.

## Intent and why

Collie already has the `deck` artifact kind (`ArtifactTemplates.swift`: HTML, `<section class="slide">` at 1280×720, keyboard nav). Agents also hand in their own HTML decks (`artifact add`). A deck cannot leave Collie today. The user wants to open it in PowerPoint (and Keynote, which opens `.pptx`) and **edit the text there**, and also get a PDF.

## Goals

- `collie artifact export <id> --format pptx|pdf [--out <path>]` and an **Exportar** menu in the Artifacts panel (kind deck / any agent page that has `.slide` sections).
- PPTX: one slide per `.slide`, 16:9. Text is real text (editable runs: bold, italic, colour, size, link, bullets), boxes are real shapes (fill, border, corner radius), images are pictures, SVG becomes a picture. Speaker notes (`<aside>` inside a slide) become the slide notes.
- PDF: one page per slide at 1280×720 CSS px, vector text.
- Works for any deck written with `.slide` sections (also hand-written ones), not only the template.

## Non-goals

- Round trip (PPTX → HTML). One way only.
- Pixel-perfect CSS: gradients, shadows, filters, transforms, animations/transitions are approximated or dropped. A per-export `warnings` list says what was dropped.
- Keynote's native `.key`. PowerPoint file opened in Keynote is enough.
- A new structured deck format (approach B, rejected).

## Anti-goals

- Slides that are one flat screenshot inside a PPTX (not editable) — failure even if it opens.
- Network access during export (the existing snapshot web view already blocks http/https/ws/ftp; keep that).
- A new third-party dependency or an external runtime (python-pptx etc.).

## Constraints

- `collied` is headless: no WebKit. Rendering lives in the app and is reached through `host.callApp` (`HostTarget.importer`), exactly like `html.snapshot` in `ArtifactImport.swift`.
- Host channel replies cap at 1 MiB: results go to files under `<artifactsRoot>/<id>/.export/` and the reply carries paths (same pattern as `.import/`).
- `Package.swift` has no zip library. Write a small store-only ZIP writer (CRC32 + local headers + central directory) in `CollieDaemonKit`; PPTX does not need deflate.
- Writes stay inside the project/app data dir; `--out` goes through the existing sandbox/access rules (`collie access request` on a blocked write).
- Tests: only changed/created tests via `--filter`; never the full suite.

## Approaches

- **A. Convert the rendered HTML (chosen).** Reuse the offscreen WKWebView and DOM snapshot, one snapshot per slide, map nodes to PPTX shapes. Works with every deck, no format change. Trade-off: CSS fidelity is approximate.
- **B. Structured slide model (JSON/Markdown).** Cleaner PPTX, but breaks existing HTML decks and takes layout freedom from agents. Rejected.
- **C. External tool (python-pptx, pptxgenjs).** Needs a runtime on the user's Mac and the Collie sandbox blocks it. Rejected.

## Design

### Pieces

1. **App: `deck.snapshot` host command** (`ColliePlugins`, next to `HTMLSnapshotter`). Loads the artifact page like `html.snapshot` (same lockdown rules), finds `.slide` elements (fallback: `section`, `[data-slide]`; none found → error `no slides`). For each slide: force it visible alone (`display` restored, others hidden, `transform` cleared, size 1280×720), run `HTMLSnapshotScript` on that subtree, save `slide-<n>.json` plus images/SVG PNGs into `.export/`. Collects `<aside>` text per slide as notes (excluded from the snapshot).
2. **App: `deck.pdf` host command.** Same loader; uses `WKWebView.createPDF` per slide with a 1280×720 rect, merges pages with PDFKit (`PDFDocument`), writes `.export/deck.pdf`.
3. **Daemon: `PPTXWriter`** (`CollieDaemonKit/Artifacts/`): pure Swift, no AppKit. Input: array of slide snapshots. Output: `.pptx` bytes. Parts: `[Content_Types].xml`, `_rels`, `presentation.xml` (slide size 12192000×6858000 EMU = 1280×720 px at 9525 EMU/px), slide master/layout (one blank layout), `slides/slideN.xml`, `media/`, `notesSlides` when notes exist.
4. **Daemon: `ZipWriter`** (store-only), unit-tested against `unzip -t` in a test and by a read-back parser.
5. **Command:** `artifact.export {id, format, out?}` → `{path, slides, warnings[]}`. Admin or terminal token, like `artifact.get`. Added to `Commands.swift` specs, `ArtifactCommands.swift`, CLI help, MCP tool.
6. **UI:** Artifacts panel row/detail gets **Exportar ▾** (PowerPoint, PDF) → save panel → calls the command → reveals the file. Menu shown only if the page has slides (cheap check on `source.html` for `class="slide"`).

### Node → shape mapping

| DOM | PPTX |
|---|---|
| element with background colour / border / radius | `p:sp` rect or `roundRect` (`adj` from radius), solid fill with alpha, `a:ln` border |
| element with text runs | `p:sp` text box, `a:p`/`a:r` per run (`b`, `i`, `u`, `sz` px→pt ×0.75, `solidFill`, `hlinkClick`) |
| `<ul>/<ol>` `li` | paragraph with `a:buChar` / `a:buAutoNum` |
| `<img>`, snapshot PNG | `p:pic` (`object-fit` cover/contain → crop via `a:srcRect`) |
| inline `<svg>` | `p:pic` from the PNG the snapshot already produces |
| slide background | `p:bg` solid fill (gradient → first stop, warning) |
| everything else (shadow, filter, gradient on non-slide, transform) | dropped, one warning per kind |

Fonts: the family name goes into `a:latin typeface`; PowerPoint falls back if absent. Text boxes get `wrap="square"` and no autofit, sized from the measured box so lines break where the browser broke them (small risk of different wrapping in PowerPoint; documented in warnings).

### Errors

`notFound` (no artifact), `invalidArgs` (format), `unavailable` (app not running/lockdown), `timeout`, `internal` with reason `no slides` when none found. Partial results are never written: temp file then rename.

### Testing

- `PPTXWriterTests`: known snapshot fixtures → unzip, XML well-formed, slide count, text runs, notes present.
- `ZipWriterTests`: CRC32 vectors, `unzip -t` passes.
- Snapshot script test for slide isolation (hidden slides, scaled transform cleared) in `ColliePluginsTests`.
- Command test `artifact.export` with a fake host reply.
- Manual: export the Collie deck (11 slides) and open it in PowerPoint and Keynote.

## Left to the builder

Exact EMU/px rounding, slide master XML boilerplate, panel layout details of the menu, warning wording, choice of CRC32 table vs `zlib`'s `crc32` (both fine, `zlib` is on macOS).

## Calls I made (check these)

- PowerPoint only, no `.key`.
- Gradient backgrounds fall back to the first colour with a warning.
- **Snapshot extension.** `HTMLSnapshotScript` already gives per-node rect (x, y, w, h), computed style, runs (colour, weight, style, decoration, `href`), image file and svg file. It lacks list info (tag `ul`/`ol`, ordinal, depth). Add that under an opt-in `mode: "deck"` flag; the design-import output stays byte-identical (existing import tests must pass unchanged). `PPTXWriter` takes the same node JSON plus a per-slide wrapper `{index, notes, background, nodes}`; fixtures use that shape.
- **Fragments and fonts.** Export the state the page has on load (reveals/build steps not applied). `::before`/`::after` content and CSS counters are not in the DOM and are dropped, with one warning; list markers come from the snapshot's list info, not from CSS. Fonts are not embedded: the family goes into `a:latin`, and the export lists the families used in `warnings` so the user can install them.
- **Shape tree.** Document order = z-order. An element with a background/border becomes a shape; text becomes its own text box on top (text is not merged into the shape). `overflow: hidden` is ignored (warning when a child exceeds its parent). Wrapped text keeps the browser's measured box; PowerPoint may wrap differently.
- **PDF.** Screen media with backgrounds printed; one page per slide, page size 960×540 pt (1280×720 px × 0.75). Text stays selectable and searchable (vector from `createPDF`).
- **Output location.** The daemon always writes `<artifact>/.export/deck.<ext>` (overwritten on each export) via temp file + rename. With `--out`, the daemon then copies it there; a terminal caller goes through the existing access rules (`access request` on a blocked write), the app (admin token) copies where the save panel says.
- **What counts as a deck.** `.slide` elements, then `[data-slide]`. Bare `section` is not a fallback. No slides → `invalidArgs` "page has no slides". The Exportar menu uses the same selectors on `source.html`.
- **Notes.** A direct child `<aside>` of a slide that is hidden (computed `display: none`) is the notes and is excluded from the snapshot. A visible `<aside>` stays slide content.
- **Time.** Export uses a 60 s call timeout and no progress; the UI shows a busy state and no cancel. Images are read from the snapshot's files, not re-rendered.
