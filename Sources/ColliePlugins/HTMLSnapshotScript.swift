import Foundation

/// The DOM snapshot for `html.snapshot`, run as a document-end user script in the isolated `.defaultClient` world.
/// Waits for `load`, `document.fonts.ready` + 300 ms, walks the page and posts the snapshot as a JSON string to the
/// `collieSnapshot` handler (`{error}` if it threw). Keys: `{title, width, height, truncated, blocked, root}`; nodes in
/// HTMLSnapshotter.swift.
enum HTMLSnapshotScript {
    static let userScript = wrap(source)
    /// Deck mode (deck export): `source`'s walk run once per slide (`.slide`, else `[data-slide]`; none → error
    /// "no slides"), each slide isolated by `isolateSlide`. Posts `{title, slides: [{index, w, h, background, notes?,
    /// pseudo, root}], blocked, truncated}`; `root` coordinates are slide-relative, `li` nodes add `list {kind, index,
    /// depth}`, svg nodes add a PNG `image` beside `svg`. Built from `source` by text so `userScript` stays unchanged.
    static let deckUserScript = "window.__collieDeck = true;\n" + wrap(deckSource)

    static func wrap(_ body: String) -> String {
        """
        (async () => {
        if (document.readyState !== "complete") await new Promise(r => addEventListener("load", r, { once: true }));
        // media queries see width + gap, as in a real browser with a classic scrollbar
        const gap = innerWidth - document.documentElement.clientWidth;
        if (gap > 0) await new Promise(r => {   // the host widens the view by the scrollbar's width; resize (or 2 s) continues
          addEventListener("resize", r, { once: true }); setTimeout(r, 2000);
          window.webkit.messageHandlers.collieSnapshot.postMessage({ gap });
        });
        \(body)
        })().then(s => window.webkit.messageHandlers.collieSnapshot.postMessage(s),
                  e => window.webkit.messageHandlers.collieSnapshot.postMessage({ error: String(e) }));
        """
    }
    static let source = #"""
    await document.fonts.ready;
    await new Promise(r => setTimeout(r, 300));
    const NODE_CAP = 3000, IMG_CAP = 4 << 20, IMG_TOTAL = 24 << 20, SVG_CAP = 256 << 10, MAX_H = 20000;
    const SKIP = new Set(["script", "style", "noscript", "template", "head", "meta", "link"]);
    const PROPS = ["display", "position", "flexDirection", "flexWrap", "justifyContent", "alignItems", "rowGap", "columnGap",
      "gridTemplateColumns", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft", "backgroundColor", "backgroundImage",
      "color", "fontFamily", "fontSize", "fontWeight", "fontStyle", "lineHeight", "letterSpacing", "textAlign",
      "textDecorationLine", "textTransform", "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
      "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor", "borderTopStyle", "borderTopLeftRadius",
      "borderTopRightRadius", "borderBottomRightRadius", "borderBottomLeftRadius", "boxShadow", "opacity", "overflow", "objectFit",
      "clipPath"];
    // inherited: on nodes without text they repeat the parent's value, so there "default" is the parent's value
    const INHERITED = new Set(["color", "fontFamily", "fontSize", "fontWeight", "fontStyle", "lineHeight", "letterSpacing",
      "textAlign", "textTransform"]);
    const REMOTE = /^(https?|wss?|ftp):/i;
    // CSS initial values as this engine prints them
    const probe = document.createElement("div");
    probe.style.all = "initial";
    document.documentElement.appendChild(probe);
    const pc = getComputedStyle(probe), INITIAL = {};
    for (const p of PROPS) INITIAL[p] = pc[p];
    probe.remove();

    const blocked = [], seen = new Set();
    const block = u => { if (u && REMOTE.test(u) && !seen.has(u)) { seen.add(u); blocked.push(u); } };
    for (const e of performance.getEntriesByType("resource")) {
      if (e.transferSize === 0 && e.decodedBodySize === 0) block(e.name);
    }
    for (const el of document.querySelectorAll("img[src], script[src], link[href]")) {
      if (el.tagName === "LINK" && !/stylesheet|preload|icon/i.test(el.rel)) continue;
      block(el.src || el.href);
    }

    let count = 0, truncated = false, imageBytes = 0;
    const jobs = [];
    const fit = v => v === "cover" || v === "contain" ? v : "fill";

    function styleOf(cs, parentCS, textual) {
      const s = {};
      for (const p of PROPS) {
        const v = cs[p];
        const base = INHERITED.has(p) && !textual && parentCS ? parentCS[p] : INITIAL[p];
        if (v !== base) s[p] = v;
      }
      // a border color is currentColor by default: noise where that side has no border
      for (const side of ["Top", "Right", "Bottom", "Left"]) {
        if (cs["border" + side + "Width"] === "0px") delete s["border" + side + "Color"];
      }
      return s;
    }

    function box(el) {
      const r = el.getBoundingClientRect();
      return { x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height };
    }

    const isInline = el => getComputedStyle(el).display === "inline";
    function isTextLeaf(el) {
      for (const d of el.querySelectorAll("*")) {
        if (d.tagName === "IMG" || d.tagName.toLowerCase() === "svg" || !isInline(d)) return false;
      }
      return !!(el.innerText && el.innerText.trim());
    }

    const RUN_KEYS = { color: "color", fontWeight: "fontWeight", fontStyle: "fontStyle", decoration: "textDecorationLine" };
    function runProps(el, leaf) {
      const cs = getComputedStyle(el), lcs = getComputedStyle(leaf), o = {};
      for (const [k, p] of Object.entries(RUN_KEYS)) if (cs[p] !== lcs[p]) o[k] = cs[p];
      const a = el.closest("a[href]");
      if (a && a !== leaf && leaf.contains(a)) o.href = a.getAttribute("href");
      return o;
    }
    // HTML whitespace only (innerText keeps U+00A0)
    const collapse = t => t.replace(/[ \t\n\r\f]+/g, " ").replace(/^ | $/g, "");
    const utf8 = t => new TextEncoder().encode(t).length;
    // Runs: text nodes walked with whitespace collapsed, then located in `text` (innerText) in order; the search
    // ignores case (text-transform) without changing lengths, so offsets stay `text`'s.
    function runsOf(leaf, text) {
      const raw = [];
      const walker = document.createTreeWalker(leaf, NodeFilter.SHOW_TEXT);
      for (let t = walker.nextNode(); t; t = walker.nextNode()) {
        const piece = collapse(t.data);
        if (piece) raw.push({ piece, props: runProps(t.parentElement, leaf) });
      }
      const runs = [];
      let cursor = 0;
      for (const { piece, props } of raw) {
        const re = new RegExp(piece.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi");
        re.lastIndex = cursor;
        const m = re.exec(text);
        if (!m) continue;   // ponytail: a piece innerText rewrote (e.g. ::before content) loses its run
        const i = m.index;
        cursor = i + m[0].length;
        const key = JSON.stringify(props), last = runs[runs.length - 1];
        if (key === "{}") continue;
        if (last && last.key === key && !collapse(text.slice(last.end, i))) last.end = cursor;
        else runs.push({ start: i, end: cursor, key, props });
      }
      return runs.map(r => ({ start: r.start, end: r.end, ...r.props }));
    }

    // drawn at most at 2× its box (a photo at natural size outgrows IMG_CAP); `keep`: same aspect (cover/contain)
    function drawSize(nw, nh, bw, bh, keep) {
      const cw = Math.max(1, Math.ceil(bw * 2)), ch = Math.max(1, Math.ceil(bh * 2));
      if (!keep) return [Math.min(nw, cw), Math.min(nh, ch)];
      const s = Math.min(1, Math.max(cw / nw, ch / nh));
      return [Math.max(1, Math.round(nw * s)), Math.max(1, Math.round(nh * s))];
    }
    function canvasPNG(img, w, h) {
      try {
        const c = document.createElement("canvas");
        c.width = w; c.height = h;
        c.getContext("2d").drawImage(img, 0, 0, w, h);
        const data = c.toDataURL("image/png").slice("data:image/png;base64,".length);
        const bytes = Math.floor(data.length * 3 / 4) - (data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0);
        if (bytes > IMG_CAP || imageBytes + bytes > IMG_TOTAL) return null;
        imageBytes += bytes;
        return data;
      } catch (e) { return null; }   // tainted (cross-origin) or undecodable
    }
    function local(u) { try { return !REMOTE.test(new URL(u, location.href).href); } catch (e) { return false; } }

    async function imageJob(node, src, objectFit, keep) {
      if (!local(src)) { block(new URL(src, location.href).href); return; }
      if (/\.svg(\?|#|$)/i.test(new URL(src, location.href).pathname)) {
        try {
          const text = await (await fetch(src)).text();
          if (text.includes("<svg")) {
            const svg = text.slice(text.indexOf("<svg"));
            if (utf8(svg) <= SVG_CAP) { node.svg = svg; return; }
          }
        } catch (e) {}
      }
      const img = new Image();
      img.src = src;
      try { await img.decode(); } catch (e) { return; }
      if (!img.naturalWidth || !img.naturalHeight) return;
      const [w, h] = drawSize(img.naturalWidth, img.naturalHeight, node.w, node.h, keep);
      const data = canvasPNG(img, w, h);
      if (data) node.image = { data, w, h, fit: fit(objectFit) };
    }

    // a clone with fill/stroke/stop-color/flood-color resolved (currentColor → the computed color) and a size
    function svgMarkup(el, b) {
      const clone = el.cloneNode(true), orig = [el, ...el.querySelectorAll("*")], copy = [clone, ...clone.querySelectorAll("*")];
      orig.forEach((o, i) => {
        const c = copy[i], cs = getComputedStyle(o);
        for (const [p, attr] of [["fill", "fill"], ["stroke", "stroke"], ["stopColor", "stop-color"], ["floodColor", "flood-color"]]) {
          const v = cs[p];
          if (v && !/^url\(/.test(v)) c.setAttribute(attr, v);
        }
        for (const a of [...c.attributes]) {
          if (/currentcolor/i.test(a.value)) c.setAttribute(a.name, a.value.replace(/currentcolor/gi, cs.color));
        }
      });
      if (!clone.getAttribute("width")) clone.setAttribute("width", String(b.w));
      if (!clone.getAttribute("height")) clone.setAttribute("height", String(b.h));
      return clone.outerHTML;
    }
    // input types whose value is text; the rest (checkbox, radio, range, file…) are plain boxes
    const TEXTY = new Set(["text", "search", "email", "url", "tel", "number", "password"]);

    function walk(el, parentCS) {
      const tag = el.tagName.toLowerCase();
      if (SKIP.has(tag)) return null;
      const cs = getComputedStyle(el);
      if (cs.display === "none" || cs.visibility === "hidden") return null;
      if (count >= NODE_CAP) { truncated = true; return null; }
      count++;
      const isSvg = tag === "svg";
      const field = tag === "textarea" || (tag === "input" && TEXTY.has(el.type));
      const leaf = !isSvg && (field || isTextLeaf(el));
      const node = { tag, ...box(el), style: styleOf(cs, parentCS, leaf || isSvg), children: [] };
      if (el.id) node.id = el.id;
      if (el.classList && el.classList.length) node.cls = el.classList[0];
      if (tag === "a" && el.hasAttribute("href")) node.href = el.getAttribute("href");
      if (tag === "img" && el.hasAttribute("alt")) node.alt = el.getAttribute("alt");
      if (isSvg) {
        const svg = svgMarkup(el, node);
        if (utf8(svg) <= SVG_CAP) node.svg = svg;
      } else if (field) {
        node.text = el.type === "password" && el.value ? "\u2022".repeat(el.value.length) : el.value || el.placeholder || "";
      } else if (leaf) {
        node.text = el.innerText;
        const runs = runsOf(el, node.text);
        if (runs.length) node.runs = runs;
      } else {
        for (const c of el.childNodes) {
          if (truncated) break;
          if (c.nodeType === Node.TEXT_NODE) {
            if (!collapse(c.data)) continue;   // loose text beside elements: a node of its own
            const r = document.createRange();
            r.selectNodeContents(c);
            const b = r.getBoundingClientRect();
            if (!b.width || !b.height) continue;
            if (count >= NODE_CAP) { truncated = true; break; }
            count++;
            node.children.push({ tag: "#text", x: b.left + scrollX, y: b.top + scrollY, w: b.width, h: b.height,
                                 style: styleOf(cs, null, true), children: [], text: collapse(c.data) });
          } else if (c.nodeType === Node.ELEMENT_NODE) {
            const n = walk(c, cs);
            if (n) node.children.push(n);
          }
        }
      }
      if ((node.w === 0 || node.h === 0) && !node.children.length) { count--; return null; }
      // only kept nodes spend the image budget
      const src = tag === "img" && (el.currentSrc || el.src);
      if (src) jobs.push(imageJob(node, src, cs.objectFit, fit(cs.objectFit) !== "fill"));
      const bg = /url\(["']?([^"')]+)["']?\)/.exec(cs.backgroundImage);
      if (bg) jobs.push(imageJob(node, bg[1], cs.backgroundSize, true));
      return node;
    }

    const root = walk(document.documentElement, null);
    await Promise.all(jobs);
    return JSON.stringify({
      title: document.title, width: document.documentElement.clientWidth,
      height: Math.min(document.documentElement.scrollHeight, MAX_H),
      truncated, blocked, root
    });
    """#

    /// `source` up to its page walk, with list info on `li` nodes, then the per-slide loop.
    static let deckSource: String = {
        let alt = #"if (tag === "img" && el.hasAttribute("alt")) node.alt = el.getAttribute("alt");"#
        guard let cut = source.range(of: "const root = walk(document.documentElement, null);"), source.contains(alt) else {
            preconditionFailure("HTMLSnapshotScript.source changed: update deckSource's anchors")
        }
        return String(source[..<cut.lowerBound])
            .replacingOccurrences(of: alt, with: alt + #" if (tag === "li") node.list = listInfo(el);"#) + isolateFunction + deckTail
    }()

    /// Shows slide `i` of `slides` alone, unscaled at its parent's origin. Also for the PDF pass (one slide per page).
    static let isolateFunction = #"""
    function isolateSlide(slides, i) {
      slides.forEach((s, j) => { if (j !== i) s.style.setProperty("display", "none", "important"); });
      const s = slides[i];
      if (getComputedStyle(s).display === "none") s.classList.add("on");
      if (getComputedStyle(s).display === "none") s.style.setProperty("display", "block", "important");
      // transition: none, or the rect would be read mid-way from the old transform
      for (const [p, v] of [["transform", "none"], ["left", "0"], ["top", "0"], ["margin", "0"], ["position", "relative"],
                            ["transition", "none"], ["visibility", "visible"], ["opacity", "1"]]) s.style.setProperty(p, v, "important");
    }

    """#

    static let deckTail = #"""
    function listInfo(li) {
      const p = li.parentElement, kind = p && p.tagName.toLowerCase();
      if (kind !== "ul" && kind !== "ol") return undefined;
      let index = 1, depth = 0;
      for (let s = li.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === "LI") index++;
      for (let a = p.parentElement; a; a = a.parentElement) if (a.tagName === "UL" || a.tagName === "OL") depth++;
      return { kind, index, depth };
    }
    const eachNode = (n, f) => { f(n); for (const c of n.children) eachNode(c, f); };
    // svg markup (inline or a fetched .svg file) drawn to a PNG at 2× its box, under the image caps
    async function svgPNG(node) {
      const markup = /^<svg[^>]*\sxmlns=/.test(node.svg) ? node.svg : node.svg.replace("<svg", '<svg xmlns="http://www.w3.org/2000/svg"');
      const img = new Image();
      img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(markup);
      try { await img.decode(); } catch (e) { return; }
      const w = Math.max(1, Math.ceil(node.w * 2)), h = Math.max(1, Math.ceil(node.h * 2));
      const data = canvasPNG(img, w, h);
      if (data) node.image = { data, w, h, fit: "fill" };
    }

    let slides = [...document.querySelectorAll(".slide")];
    if (!slides.length) slides = [...document.querySelectorAll("[data-slide]")];
    if (!slides.length) throw "no slides";
    const saved = slides.map(s => [s.getAttribute("style"), s.getAttribute("class")]);
    const restore = () => slides.forEach((s, j) => {
      saved[j].forEach((v, k) => { const a = k ? "class" : "style"; v === null ? s.removeAttribute(a) : s.setAttribute(a, v); });
    });
    const out = [];
    for (let i = 0; i < slides.length; i++) {
      restore();
      isolateSlide(slides, i);
      const slide = slides[i], b = box(slide), cs = getComputedStyle(slide);
      // notes: hidden direct-child asides (walk skips them, being display: none)
      const notes = [...slide.children].filter(c => c.tagName === "ASIDE" && getComputedStyle(c).display === "none")
        .map(c => c.textContent.trim()).join("\n");
      const grad = /linear-gradient/.test(cs.backgroundImage) && /rgba?\([^)]*\)/.exec(cs.backgroundImage);
      let pseudo = 0;
      for (const e of [slide, ...slide.querySelectorAll("*")]) {
        if (["::before", "::after"].some(p => !["none", "normal"].includes(getComputedStyle(e, p).content))) pseudo++;
      }
      // never null (node cap hit, empty or zero-size slide): a bare box, so every slide decodes
      const root = walk(slide, slide.parentElement && getComputedStyle(slide.parentElement))
        || { tag: slide.tagName.toLowerCase(), x: b.x, y: b.y, w: b.w, h: b.h, style: {}, children: [] };
      await Promise.all(jobs);
      jobs.length = 0;
      const svgs = [];
      eachNode(root, n => { if (typeof n.svg === "string" && !n.image) svgs.push(svgPNG(n)); });
      await Promise.all(svgs);
      eachNode(root, n => { n.x -= b.x; n.y -= b.y; });
      out.push({ index: i, w: b.w, h: b.h, background: grad ? grad[0] : cs.backgroundColor, notes: notes || undefined, pseudo, root });
    }
    restore();
    return JSON.stringify({ title: document.title, slides: out, blocked, truncated });
    """#
}
