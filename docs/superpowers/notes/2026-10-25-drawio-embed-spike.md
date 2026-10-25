# draw.io embed spike (plan 2Q Diagram, Task 1)

Build: draw.io v32.6.1 (commit 84487b4891cbc0f32d7e30f34cf878c87cb1f414), `scripts/build-drawio.sh`.
Harness (throwaway, not committed): an offscreen `WKWebView` with a `collie-diagram://` scheme handler serving
`vendor/drawio/web`, a `WKContentRuleList` blocking `^https?://`, `^wss?://` and `^ftp://`, and user scripts in every frame
logging any http(s)/ws URL passed to fetch, XHR or `src`/`href`. Host page `collie-diagram://app/host.html` holds an
`<iframe src="index.html?embed=1&proto=json&offline=1&stealth=1&pwa=0&lang=pt-br&spin=1">` and bridges `message` events
to a `WKScriptMessageHandler`; Swift sends with `frame.contentWindow.postMessage(JSON.stringify(msg), '*')`.

## Answers

- **Host shape.** Embed mode posts to `window.parent`, so the editor must sit in an iframe of a host page on the same scheme
  (a top-level page would get its own outgoing messages back). Same origin, so the host can also reach the iframe's globals.
- **Network.** Nothing: no blocked or logged http(s)/ws request during init, load, autosave, merge, export and Mermaid.
  Only 14 files are fetched for that flow (index.html, styles/grapheditor.css, styles/high-contrast.css, js/bootstrap.js,
  js/main.js, js/PreConfig.js, js/PostConfig.js, js/app.min.js, js/extensions.min.js, js/stencils.min.js,
  js/shapes-14-6-5.min.js, mxgraph/css/common.css, resources/dia_pt-br.txt, images/github-logo.svg — still fetched by
  the now-detached link element, harmless); none missing.
- **WKContentRuleList:** `url-filter` has no disjunctions (`^(https?|wss?)://` fails to compile), so one rule per scheme.
- **init → load round-trip: works.** `{event:"init"}` ~1.5–2 s after load. `{action:"load", xml, autosave:1}` answers
  `{event:"load", xml, bounds, modelBounds, page, scale, translate, containerSize, currentPage, pageVisible}`. The UI is pt-BR
  with `lang=pt-br` (page "Página-1").
- **autosave: works, carries the full XML** (`{event:"autosave", xml, message, …}`, `<mxfile host="app">`, pretty-printed).
  Fires on model changes after load (tested via `{action:"merge", xml}` → `{event:"merge"}`, then autosave with the change).
  Note: after a `load` of a descriptor, an `autosave` arrives *before* its `load` event; a panel must not take that autosave
  as a user edit.
- **export: works offline.** `{action:"export", format:"png"}` → `{event:"export", format, data:"data:image/png;base64,…", xml}`;
  `"svg"` → `data:image/svg+xml;base64,…`; `"xmlpng"` → PNG with the diagram embedded. No export server involved
  (`EXPORT_URL` is null in PreConfig.js).
- **Mermaid → editable shapes: YES, offline.** `{action:"load", descriptor:{format:"mermaid", data:"<mermaid>"}}` converts
  locally (native drawio-mermaid parser in extensions.min.js) and replies `{event:"load", xml}`. Flowchart (4 lines) → 3
  vertices + 3 edges, real labels ("Decisão"), no `shape=image`; sequence and ER diagrams also become shapes.
  `wrap:true` wraps the result in a re-openable Mermaid group (`mermaidData` attribute, 4 vertices). `image:true` would
  give a static image instead (not needed).
  - It **replaces the whole diagram** (it is a `load`). For inserting into an existing diagram, the iframe's global
    `mxMermaidToDrawio.parseText(text)` returns `<mxGraphModel>` XML synchronously (tested from the host via
    `frame.contentWindow`), which Task 3 can splice in; it does not throw on bad input (EditorUi adds the checks below).
  - **Errors:** `{event:"load", error:"…"}` with no xml, and draw.io also shows an error dialog in the editor.
    "isto não é mermaid" → `Unsupported diagram type: isto`; `sequenceDiagram\n Alice->>: oi` →
    `Nothing to draw: the diagram is empty or its statements were not recognized`. **No line numbers** in errors, and the
    parser is lenient: `A[aberto --> B` and `B -->> C ]]` load without error. Task 3's "first bad line" needs its own
    check or must report draw.io's message as is.
- **Size:** `vendor/drawio/web` = 34 MB (34764 KiB): js 19.9 MB, img 5.2 MB (Azure and MS cloud icon sets left out,
  6.4 MB), images 6.6 MB (mostly "Mais formas" previews), shapes 2.4 MB. With them it was 40.2 MiB, over the target.
- **Branding (patches/drawio/0001-collie-branding.patch):** the page bar's GitHub link (github.com/jgraph/drawio) removed,
  the offline Help menu reduced to the version item (the shortcut sheet it opened is draw.io-branded), title "Diagrama",
  splash logo removed. Menus still hold actions that open drawio.com links (e.g. language help); the panel's navigation
  policy must cancel non-`collie-diagram` navigations, as DesignPanel does.
