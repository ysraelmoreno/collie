#!/usr/bin/env python3
"""Android corpus evaluation of the OCR fallback (spec docs/superpowers/specs/2026-11-22-device-ocr-fallback-design.md, O2).

For each screen of the corpus (Helpers/android-device/corpus.json: [{name, class: good|poor, launch: [adb shell args],
gt: [texts] | null, dark: bool}]):
  1. opens it (`adb shell <launch>`), waits for a STABLE screen: two equal reads of the tree
     (`collie device ui --all --timing --panel <p>`) before AND after the screenshot; a screen that does not settle is
     discarded (reported as unstable);
  2. reads the nodes with bounds from the device helper (`dump` over an own `adb forward`; uiautomator when the helper does
     not answer), the same source the daemon's trigger reads;
  3. runs the macOS OCR (docs/superpowers/specs/2026-11-22-device-poc/ocr/ocr2.swift, compiled into a temporary directory);
  4. asks the daemon's real trigger (`collie device screen --timing --json`: timingMs.trigger / ocrMs);
  5. computes labelled nodes, coverage (area of labelled or clickable nodes in the content area, below the bars), OCR text
     recall against gt (or against the tree's labels when gt is null), right position (an OCR item matching a tree label
     whose centre falls inside the item's box, +-10 px) and latency.
Output: <out>/report.json and <out>/report.md (table per screen and the CALIBRATION summary: labelled/coverage of good and
poor, how many poor the trigger caught, false fires on good, and the coverageMin / minLabeled limits that would separate the
two classes in the corpus). Screenshots go to <out>/<name>.png.

Pure functions are tested by scripts/test-android-ocr-eval.py (no device).
"""
import argparse, difflib, json, os, re, socket, statistics, subprocess, sys, tempfile, time
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OCR_SRC = os.path.join(ROOT, "docs/superpowers/specs/2026-11-22-device-poc/ocr/ocr2.swift")
# Same knobs as Sources/CollieDevice/OCR.swift (barsShare, minConfidence, minTextLength).
BARS_SHARE, MIN_CONF, MIN_LEN, POS_SLACK = 0.12, 0.5, 2, 10


# ---------- pure ----------

def norm(s):
    return re.sub(r"\s+", " ", re.sub(r"[^\w ]", "", s.lower())).strip()


def close(a, b):
    a, b = norm(a), norm(b)
    return bool(a) and bool(b) and (a in b or b in a or difflib.SequenceMatcher(None, a, b).ratio() >= 0.85)


_LINE = re.compile(r'^(\s*)\[(\w+)\] (\S+)(?: "(.*)")?(?: id=(\S+))? \((-?[\d.]+),(-?[\d.]+)\)( clickable)?$')


def parse_tree(text):
    """`device ui` tree lines -> [{ref, cls, label, cx, cy, clk}]."""
    out = []
    for line in (text or "").splitlines():
        m = _LINE.match(line)
        if m:
            out.append(dict(ref=m[2], cls=m[3], label=m[4] or "", cx=float(m[6]), cy=float(m[7]), clk=bool(m[8])))
    return out


def helper_nodes(dump):
    """Helper `dump` JSON -> [{label, clk, box:(l,t,r,b), cls}]."""
    out = []
    for n in dump.get("nodes", []):
        b = n.get("b") or [0, 0, 0, 0]
        out.append(dict(label=n.get("text") or n.get("desc") or "", clk=bool(n.get("clk")), box=tuple(b), cls=n.get("cls", "")))
    return out


def xml_nodes(xml):
    """uiautomator XML -> the same shape as helper_nodes."""
    out = []
    for e in ET.fromstring(xml).iter("node"):
        m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", e.get("bounds", ""))
        if m:
            out.append(dict(label=e.get("text") or e.get("content-desc") or "", clk=e.get("clickable") == "true",
                            box=tuple(map(int, m.groups())), cls=e.get("class", "")))
    return out


def union_area(boxes):
    """Area of the union of (l,t,r,b) boxes, overlaps once (coordinate compression; fine for a few hundred nodes)."""
    boxes = [b for b in boxes if b[2] > b[0] and b[3] > b[1]]
    xs = sorted({x for b in boxes for x in (b[0], b[2])})
    area = 0
    for x0, x1 in zip(xs, xs[1:]):
        spans = sorted((b[1], b[3]) for b in boxes if b[0] <= x0 and b[2] >= x1)
        cov, end = 0, None
        for t, b in spans:
            if end is None or t > end:
                cov += b - t; end = b
            elif b > end:
                cov += b - end; end = b
        area += cov * (x1 - x0)
    return area


def content_box(w, h):
    return (0, h * BARS_SHARE, w, h)


def clip(b, c):
    return (max(b[0], c[0]), max(b[1], c[1]), min(b[2], c[2]), min(b[3], c[3]))


def coverage(nodes, w, h):
    """Rule 2: share of the content area (below the bars) covered by labelled or clickable nodes."""
    c = content_box(w, h)
    area = (c[2] - c[0]) * (c[3] - c[1])
    return union_area([clip(n["box"], c) for n in nodes if n["label"] or n["clk"]]) / area if area > 0 else 0.0


def labeled(nodes, h):
    """Rule 1 (without the toolbar exclusion): labelled nodes centred below the bars."""
    return sum(1 for n in nodes if n["label"] and (n["box"][1] + n["box"][3]) / 2 >= h * BARS_SHARE)


def ocr_items(d, w, h):
    """ocr2 JSON (normalised x,y top-left,w,h) -> kept items in pixels {t, c, box}."""
    out = []
    for i in d.get("items", []):
        if i["c"] >= MIN_CONF and len(i["t"].strip()) >= MIN_LEN:
            out.append(dict(t=i["t"], c=i["c"], box=(i["x"] * w, i["y"] * h, (i["x"] + i["w"]) * w, (i["y"] + i["h"]) * h)))
    return out


def recall(expected, items):
    """(hits, total, missed) of expected texts found in the OCR items."""
    exp = [e for e in expected if norm(e)]
    missed = [e for e in exp if not any(close(e, i["t"]) for i in items)]
    return len(exp) - len(missed), len(exp), missed


def position(items, tree):
    """(right, checked): items whose text matches a tree label, and those whose box holds that label's centre."""
    right = checked = 0
    for i in items:
        lab = [n for n in tree if n["label"] and close(n["label"], i["t"])]
        if not lab:
            continue
        checked += 1
        l, t, r, b = i["box"]
        right += any(l - POS_SLACK <= n["cx"] <= r + POS_SLACK and t - POS_SLACK <= n["cy"] <= b + POS_SLACK for n in lab)
    return right, checked


def stable_capture(read, shot, tries=10, pause=lambda: time.sleep(0.7)):
    """Two equal reads, the screenshot, a third equal read. Returns (tree, png) or None when the screen never settles."""
    for _ in range(tries):
        a, b = read(), read()
        if a == b and a:
            png = shot()
            if read() == a:
                return a, png
        pause()
    return None


def png_size(png):
    return int.from_bytes(png[16:20], "big"), int.from_bytes(png[20:24], "big")


def best_limit(good, poor):
    """Smallest-error limit L with 'poor when value < L'. Returns {limit, errors, separates} (None limit: no values)."""
    vals = sorted(set(good) | set(poor))
    if not vals:
        return dict(limit=None, errors=0, separates=False)
    # candidates: midpoints between neighbours plus one past each end
    cands = [vals[0]] + [(x + y) / 2 for x, y in zip(vals, vals[1:])] + [vals[-1] + 1]
    best = None
    for c in cands:
        err = sum(v < c for v in good) + sum(v >= c for v in poor)
        if best is None or err < best[1]:
            best = (c, err)
    return dict(limit=best[0], errors=best[1], separates=best[1] == 0)


def dist(vals):
    return dict(n=len(vals), min=min(vals), median=statistics.median(vals), max=max(vals)) if vals else dict(n=0)


def summarize(rows):
    """The CALIBRATION summary over the rows that settled."""
    ok = [r for r in rows if r.get("stable")]
    good = [r for r in ok if r["class"] == "good"]; poor = [r for r in ok if r["class"] == "poor"]
    rec = [r for r in ok if r["recall"][1]]
    lim_lab = best_limit([r["labeled"] for r in good], [r["labeled"] for r in poor])
    if lim_lab["limit"] is not None:
        lim_lab["limit"] = int(-(-lim_lab["limit"] // 1))  # labelled counts are integers: ceil keeps the same split
    return dict(
        screens=len(rows), stable=len(ok), unstable=[r["name"] for r in rows if not r.get("stable")],
        labeled=dict(good=dist([r["labeled"] for r in good]), poor=dist([r["labeled"] for r in poor])),
        coverage=dict(good=dist([r["coverage"] for r in good]), poor=dist([r["coverage"] for r in poor])),
        poorCaught=sum(1 for r in poor if r.get("trigger")), poorTotal=len(poor),
        falseFires=[r["name"] for r in good if r.get("trigger")], goodTotal=len(good),
        minLabeled=lim_lab, coverageMin=best_limit([r["coverage"] for r in good], [r["coverage"] for r in poor]),
        recall=dict(hit=sum(r["recall"][0] for r in rec), total=sum(r["recall"][1] for r in rec)),
        position=dict(right=sum(r["position"][0] for r in ok), checked=sum(r["position"][1] for r in ok)),
        ocrMsMedian=statistics.median([r["ocrMs"] for r in ok]) if ok else None,
    )


def markdown(rows, s):
    def f(v, p=2):
        return "-" if v is None else (f"{v:.{p}f}" if isinstance(v, float) else str(v))
    out = ["# Corpus Android: gatilho e OCR", "",
           "| tela | classe | escuro | estável | rotulados | cobertura | gatilho | ocrMs daemon | recall | posição | OCR ms | árvore ms |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if not r.get("stable"):
            out.append(f"| {r['name']} | {r['class']} | {'sim' if r.get('dark') else 'não'} | não | - | - | - | - | - | - | - | - |")
            continue
        out.append(f"| {r['name']} | {r['class']} | {'sim' if r.get('dark') else 'não'} | sim | {r['labeled']} | {f(r['coverage'])} | "
                   f"{r.get('trigger') or '-'} | {f(r.get('daemonOcrMs'))} | {r['recall'][0]}/{r['recall'][1]}"
                   f"{'' if r.get('gt') else ' (árvore)'} | {r['position'][0]}/{r['position'][1]} | {f(r['ocrMs'], 0)} | {f(r.get('treeMs'))} |")
    lab, cov = s["minLabeled"], s["coverageMin"]

    def sep(x):
        return "separa" if x["separates"] else "%d erro(s)" % x["errors"]
    out += ["", "## Calibração", "",
            f"- Telas: {s['screens']}, estáveis {s['stable']}" + (f" (descartadas: {', '.join(s['unstable'])})" if s["unstable"] else ""),
            f"- Rotulados: boas {s['labeled']['good']}, pobres {s['labeled']['poor']}",
            f"- Cobertura: boas {s['coverage']['good']}, pobres {s['coverage']['poor']}",
            f"- Pobres que o gatilho pegou: {s['poorCaught']}/{s['poorTotal']}",
            f"- Falsos disparos nas boas: {len(s['falseFires'])}/{s['goodTotal']}" + (f" ({', '.join(s['falseFires'])})" if s["falseFires"] else ""),
            f"- minLabeled que separaria: {f(lab['limit'])} ({sep(lab)})",
            f"- coverageMin que separaria: {f(cov['limit'], 3)} ({sep(cov)})",
            f"- Recall do OCR: {s['recall']['hit']}/{s['recall']['total']}; posição certa {s['position']['right']}/{s['position']['checked']}",
            f"- OCR mediana: {f(s['ocrMsMedian'], 0)} ms", ""]
    return "\n".join(out)


# ---------- device ----------

class Device:
    """adb, the collie CLI and the helper, through `run` (a subprocess.run lookalike; tests pass a fake)."""

    def __init__(self, adb, serial, collie, panel, port, run=subprocess.run):
        self.a, self.ser, self.c, self.panel, self.port, self.run = adb, serial, collie, panel, port, run

    def adb(self, *a):
        return self.run([self.a, *(["-s", self.ser] if self.ser else []), *a], capture_output=True).stdout

    def collie(self, *a):
        p = self.run([self.c, "--json", *a, "--panel", self.panel], capture_output=True)
        try:
            return json.loads(p.stdout or b"{}")
        except ValueError:
            return {}

    def tree(self):
        return self.collie("device", "ui", "--all", "--timing")

    def nodes(self):
        """Nodes with bounds: the helper's dump (own forward), else uiautomator."""
        try:
            self.adb("forward", f"tcp:{self.port}", "localabstract:collie-helper")
            with socket.create_connection(("127.0.0.1", self.port), timeout=3) as s:
                f = s.makefile("rwb"); f.write(b'{"op":"dump","id":1}\n'); f.flush()
                d = json.loads(f.readline() or b"{}")
            if d.get("nodes"):
                return helper_nodes(d), "helper"
        except (OSError, ValueError):
            pass
        x = self.adb("exec-out", "uiautomator", "dump", "/dev/tty").decode("utf-8", "replace")
        x = x[x.find("<?xml"):x.rfind("</hierarchy>") + len("</hierarchy>")] if "<hierarchy" in x else ""
        return (xml_nodes(x), "uiautomator") if x else ([], "none")


def evaluate(screen, dev, ocr, out, tries=10):
    """One corpus screen -> its row. `ocr(png_path) -> ocr2 JSON`."""
    row = dict(name=screen["name"], **{"class": screen["class"]}, dark=bool(screen.get("dark")), gt=screen.get("gt"))
    dev.adb("shell", *screen["launch"])
    time.sleep(screen.get("settle", 1.5))
    last = {}

    def read():
        last["ui"] = dev.tree()
        return last["ui"].get("tree", "")
    got = stable_capture(read, lambda: dev.adb("exec-out", "screencap", "-p"), tries)
    if not got:
        row["stable"] = False
        return row
    tree_text, png = got
    row["stable"] = True
    w, h = png_size(png)
    path = os.path.join(out, f"{screen['name']}.png")
    with open(path, "wb") as f:
        f.write(png)
    nodes, row["nodesSource"] = dev.nodes()
    tree = parse_tree(tree_text)
    row.update(width=w, height=h, labeled=labeled(nodes, h), coverage=round(coverage(nodes, w, h), 4),
               treeMs=(last["ui"].get("timingMs") or {}).get("total"))
    d = ocr(path)
    items = ocr_items(d, w, h)
    runs = d.get("runsMs") or [0]
    row["ocrMs"] = statistics.median(runs[1:] or runs)
    expected = screen.get("gt") or [n["label"] for n in tree if n["label"]]
    hit, total, missed = recall(expected, items)
    row.update(recall=[hit, total], missed=missed[:12], position=list(position(items, tree)), ocrItems=len(items))
    t = dev.collie("device", "screen", "--timing").get("timingMs") or {}
    row.update(trigger=t.get("trigger"), daemonOcrMs=t.get("ocrMs"))
    return row


def compile_ocr(tmp):
    exe = os.path.join(tmp, "ocr2")
    subprocess.run(["swiftc", "-O", OCR_SRC, "-o", exe], check=True)
    return exe


def main(argv=None):
    p = argparse.ArgumentParser(description="Android corpus evaluation of the OCR fallback: trigger and OCR on real apps "
                                            "(see the module docstring).")
    p.add_argument("--panel", required=True, help="device panel the collie CLI reads (collie device ... --panel)")
    p.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"), help="adb serial (default: ANDROID_SERIAL or adb's only device)")
    p.add_argument("--corpus", default=os.path.join(ROOT, "Helpers/android-device/corpus.json"))
    p.add_argument("--out", default="android-ocr-eval-out", help="directory for report.json, report.md and the PNGs")
    p.add_argument("--only", nargs="*", help="evaluate only these screen names")
    p.add_argument("--adb", default=os.environ.get("ADB") or os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"))
    p.add_argument("--collie", default=os.environ.get("COLLIE", "collie"))
    p.add_argument("--port", type=int, default=7791, help="local port for the helper forward")
    p.add_argument("--mode", choices=("fast", "accurate"), default="accurate", help="OCR level (the fallback uses accurate)")
    p.add_argument("--runs", type=int, default=3, help="OCR runs per screen (the first warms up)")
    p.add_argument("--tries", type=int, default=10, help="stability attempts before discarding a screen")
    a = p.parse_args(argv)
    screens = json.load(open(a.corpus))
    if a.only:
        screens = [s for s in screens if s["name"] in a.only]
    os.makedirs(a.out, exist_ok=True)
    dev = Device(a.adb, a.serial, a.collie, a.panel, a.port)
    with tempfile.TemporaryDirectory() as tmp:
        exe = compile_ocr(tmp)

        def ocr(path):
            r = subprocess.run([exe, path, a.mode, "1.0", str(a.runs)], capture_output=True, text=True)
            return json.loads(r.stdout or "{}")
        rows = []
        for s in screens:
            r = evaluate(s, dev, ocr, a.out, a.tries)
            print(json.dumps(r, ensure_ascii=False), file=sys.stderr)
            rows.append(r)
    s = summarize(rows)
    json.dump(dict(screens=rows, summary=s), open(os.path.join(a.out, "report.json"), "w"), ensure_ascii=False, indent=2)
    open(os.path.join(a.out, "report.md"), "w").write(markdown(rows, s))
    print(markdown(rows, s))


if __name__ == "__main__":
    main()
