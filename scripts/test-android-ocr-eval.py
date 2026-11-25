#!/usr/bin/env python3
"""Tests of scripts/android-ocr-eval.py without a device (fake adb/collie runner, fake OCR)."""
import importlib.util, json, os, subprocess, sys, tempfile, unittest
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ev", os.path.join(HERE, "android-ocr-eval.py"))
ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
W, H = 1000, 2000


def node(label="", clk=False, box=(0, 0, 0, 0)):
    return dict(label=label, clk=clk, box=box, cls="View")


def png(w, h):
    return b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + w.to_bytes(4, "big") + h.to_bytes(4, "big") + b"rest"


class Pure(unittest.TestCase):
    def test_union_area_counts_overlap_once(self):
        self.assertEqual(ev.union_area([(0, 0, 10, 10), (5, 5, 15, 15)]), 175)
        self.assertEqual(ev.union_area([(0, 0, 10, 10), (0, 0, 10, 10)]), 100)
        self.assertEqual(ev.union_area([(0, 0, 0, 10)]), 0)

    def test_coverage_only_labelled_or_clickable_below_bars(self):
        content = W * H * (1 - ev.BARS_SHARE)
        full = [node("x", box=(0, 0, W, H))]
        self.assertAlmostEqual(ev.coverage(full, W, H), 1.0)
        self.assertEqual(ev.coverage([node(box=(0, 0, W, H))], W, H), 0.0)   # neither labelled nor clickable
        bar = [node("status", box=(0, 0, W, 240))]                             # all inside the bars
        self.assertEqual(ev.coverage(bar, W, H), 0.0)
        half = [node(clk=True, box=(0, 240, W // 2, H))]
        self.assertAlmostEqual(ev.coverage(half, W, H), (W // 2) * (H - 240) / content)

    def test_labeled_skips_bars(self):
        ns = [node("clock", box=(0, 0, 100, 50)), node("a", box=(0, 500, 100, 600)), node(clk=True, box=(0, 500, 100, 600))]
        self.assertEqual(ev.labeled(ns, H), 1)

    def test_recall_and_position(self):
        items = ev.ocr_items({"items": [
            {"t": "Entrar", "c": 0.9, "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.05},
            {"t": "Criar  conta!", "c": 0.9, "x": 0.5, "y": 0.5, "w": 0.2, "h": 0.05},
            {"t": "x", "c": 0.9, "x": 0, "y": 0, "w": 0.1, "h": 0.1},          # too short
            {"t": "Esqueci", "c": 0.3, "x": 0, "y": 0, "w": 0.1, "h": 0.1}]}, W, H)  # low confidence
        self.assertEqual(len(items), 2)
        hit, total, missed = ev.recall(["Entrar", "Criar conta", "Esqueci a senha", ""], items)
        self.assertEqual((hit, total, missed), (2, 3, ["Esqueci a senha"]))
        tree = ev.parse_tree('[e1] FrameLayout (500,1000)\n  [e2] Button "Entrar" id=go (200,250) clickable\n'
                             '  [e3] TextView "Criar conta" (10,10)')
        self.assertEqual([n["label"] for n in tree], ["", "Entrar", "Criar conta"])
        self.assertTrue(tree[1]["clk"])
        self.assertEqual(ev.position(items, tree), (1, 2))   # Entrar in its box, Criar conta far off

    def test_stable_capture(self):
        reads = iter(["a", "b", "b", "b", "b"])
        # try 1: a,b differ; try 2: b,b equal, shot, b equal -> settled
        self.assertEqual(ev.stable_capture(lambda: next(reads), lambda: b"png", tries=2, pause=lambda: None), ("b", b"png"))
        changing = iter(["a", "a", "b"] * 5)   # moves during the screenshot each time
        self.assertIsNone(ev.stable_capture(lambda: next(changing), lambda: b"", tries=5, pause=lambda: None))
        self.assertIsNone(ev.stable_capture(lambda: "", lambda: b"", tries=2, pause=lambda: None))   # empty tree never counts

    def test_best_limit(self):
        self.assertEqual(ev.best_limit([5, 6], [1, 1]), dict(limit=3.0, errors=0, separates=True))
        r = ev.best_limit([0.4, 0.1], [0.05, 0.2])
        self.assertFalse(r["separates"]); self.assertEqual(r["errors"], 1)
        self.assertIsNone(ev.best_limit([], [])["limit"])

    def test_summarize_and_markdown(self):
        rows = [dict(name="normal", **{"class": "good"}, stable=True, labeled=6, coverage=0.5, trigger=None, recall=[4, 4], position=[3, 4], ocrMs=40, gt=["x"]),
                dict(name="settings", **{"class": "good"}, stable=True, labeled=9, coverage=0.12, trigger="coverage", recall=[8, 10], position=[8, 8], ocrMs=60, gt=None),
                dict(name="canvas", **{"class": "poor"}, stable=True, labeled=1, coverage=0.02, trigger="labels", recall=[6, 7], position=[0, 0], ocrMs=50, gt=["y"]),
                dict(name="game", **{"class": "poor"}, stable=False)]
        s = ev.summarize(rows)
        self.assertEqual((s["stable"], s["unstable"], s["poorCaught"], s["poorTotal"], s["falseFires"]), (3, ["game"], 1, 1, ["settings"]))
        self.assertEqual(s["minLabeled"], dict(limit=4, errors=0, separates=True))
        self.assertTrue(s["coverageMin"]["separates"]); self.assertLess(s["coverageMin"]["limit"], 0.12)
        self.assertEqual(s["recall"], dict(hit=18, total=21))
        md = ev.markdown(rows, s)
        self.assertIn("## Calibração", md); self.assertIn("| game | poor | não | não |", md); self.assertIn("(árvore)", md)
        self.assertIn("Falsos disparos nas boas: 1/2 (settings)", md)


class FakeDevice(unittest.TestCase):
    """evaluate() end to end with a fake adb/collie runner (no device) and a fake OCR."""

    def test_evaluate_row(self):
        calls = []
        tree = '[e1] FrameLayout (500,1000)\n  [e2] TextView "Olá" (200,1000)'
        xml = ('junk<?xml version="1.0"?><hierarchy><node text="Olá" content-desc="" clickable="false" class="TextView" '
               'bounds="[0,900][1000,1100]"/></hierarchy>')

        def run(cmd, capture_output=True):
            calls.append(cmd)
            if "screencap" in cmd: out = png(W, H)
            elif "uiautomator" in cmd: out = xml.encode()
            elif "ui" in cmd: out = json.dumps({"tree": tree, "timingMs": {"total": 12}}).encode()
            elif "screen" in cmd: out = json.dumps({"timingMs": {"trigger": "labels", "ocrMs": 88}}).encode()
            else: out = b""
            return SimpleNamespace(stdout=out, returncode=0)
        dev = ev.Device("adb", "emu-1", "collie", "p1", 1, run)   # port 1: the helper never answers -> uiautomator
        ocr = lambda path: {"runsMs": [300, 40, 50], "items": [{"t": "Olá", "c": 0.9, "x": 0.1, "y": 0.47, "w": 0.3, "h": 0.06}]}
        old = ev.time.sleep; ev.time.sleep = lambda s: None
        try:
            with tempfile.TemporaryDirectory() as out:
                r = ev.evaluate({"name": "x", "class": "poor", "launch": ["am", "start", "-n", "a/.B"], "gt": None}, dev, ocr, out)
                self.assertTrue(os.path.exists(os.path.join(out, "x.png")))
        finally:
            ev.time.sleep = old
        self.assertEqual(calls[0], ["adb", "-s", "emu-1", "shell", "am", "start", "-n", "a/.B"])
        self.assertIn(["collie", "--json", "device", "ui", "--all", "--timing", "--panel", "p1"], calls)
        self.assertEqual((r["stable"], r["width"], r["height"], r["nodesSource"], r["labeled"]), (True, W, H, "uiautomator", 1))
        self.assertEqual((r["recall"], r["position"], r["ocrMs"], r["trigger"], r["daemonOcrMs"], r["treeMs"]),
                         ([1, 1], [1, 1], 45, "labels", 88, 12))
        self.assertAlmostEqual(r["coverage"], round(200 * 1000 / (W * H * (1 - ev.BARS_SHARE)), 4))


class Cli(unittest.TestCase):
    def test_help_exits_zero(self):
        p = subprocess.run([sys.executable, os.path.join(HERE, "android-ocr-eval.py"), "--help"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0); self.assertIn("--panel", p.stdout)

    def test_corpus_shape(self):
        c = json.load(open(os.path.join(HERE, "..", "Helpers/android-device/corpus.json")))
        names = {s["name"] for s in c}
        for n in ("canvas", "surface", "webcanvas", "photo", "hidden", "normal"):
            self.assertIn(n, names); self.assertIn(n + "_dark", names)
        for s in c:
            self.assertIn(s["class"], ("good", "poor")); self.assertIsInstance(s["launch"], list); self.assertIsInstance(s["dark"], bool)
        self.assertTrue(any(s["gt"] is None for s in c))


if __name__ == "__main__":
    unittest.main()
