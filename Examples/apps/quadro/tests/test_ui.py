"""Static checks of the Quadro UI (ui/index.html, ui/app.js, ui/style.css).

Run from Examples/apps/quadro: python3 -m unittest tests.test_ui -v
"""
import os
import re
import shutil
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(os.path.dirname(HERE), "ui")
FILES = ("index.html", "app.js", "style.css")


def read(name):
    with open(os.path.join(UI, name), encoding="utf-8") as f:
        return f.read()


# Patterns forbidden in app.js and index.html (text must go in as text, never as markup or code).
FORBIDDEN_COMMON = [
    ("innerHTML", r"innerHTML"),
    ("outerHTML", r"outerHTML"),
    ("insertAdjacentHTML", r"insertAdjacentHTML"),
    ("document.write", r"document\s*\.\s*write"),
    ("eval", r"\beval\s*\("),
    ("new Function", r"\bnew\s+Function\b"),
    ("javascript:", r"javascript\s*:"),
]
FORBIDDEN_HTML = [("on* attribute", r"<[^>]*\son[a-z]+\s*=")]
FORBIDDEN_JS = [
    ("on* property", r"\.on[a-z]+\s*=(?!=)"),
    ("on* attribute", r"setAttribute\(\s*[\"']on[a-z]+"),
    ("string timer", r"set(?:Timeout|Interval)\(\s*[\"'`]"),
]


class UIFilesTest(unittest.TestCase):
    def test_files_exist(self):
        for name in FILES:
            self.assertTrue(os.path.isfile(os.path.join(UI, name)), name)

    def test_index_basics(self):
        html = read("index.html")
        self.assertRegex(html, r"<html[^>]*\slang=\"[a-zA-Z-]+\"")
        self.assertRegex(html, r"<meta[^>]+name=\"viewport\"")
        self.assertRegex(html, r"<title>[^<]+</title>")
        self.assertRegex(html, r"<script[^>]+src=\"app\.js\"")
        self.assertRegex(html, r"<link[^>]+href=\"style\.css\"")
        # relative paths only: no leading slash, no scheme
        for ref in re.findall(r"(?:src|href)=\"([^\"]*)\"", html):
            self.assertFalse(ref.startswith("/"), ref)
            self.assertNotRegex(ref, r"^[a-z]+:", ref)

    def test_no_forbidden_patterns(self):
        for name, extra in (("app.js", FORBIDDEN_JS), ("index.html", FORBIDDEN_HTML)):
            text = read(name)
            for label, rx in FORBIDDEN_COMMON + extra:
                m = re.search(rx, text, re.IGNORECASE if label == "javascript:" else 0)
                self.assertIsNone(m, "%s em %s: %r" % (label, name, m.group(0) if m else ""))

    def test_no_external_urls(self):
        for name in FILES:
            text = read(name)
            for url in re.findall(r"https?://[^\s\"')]+", text):
                self.assertTrue(url.startswith("http://www.w3.org/"), "%s em %s" % (url, name))

    def test_network_only_api(self):
        js = read("app.js")
        for call in re.findall(r"(?:fetch|EventSource|request|post)\(\s*\"([^\"]*)\"", js):
            self.assertTrue(call.startswith("api/"), call)
        self.assertIn('new EventSource("api/stream")', js)
        self.assertNotRegex(js, r"XMLHttpRequest|WebSocket|sendBeacon|importScripts")
        self.assertNotRegex(js, r"[\"']/api/")  # relative, so it works inside the Collie panel

    def test_api_paths_are_in_contract(self):
        contract = {"api/board", "api/cards", "api/card", "api/card/create", "api/card/update",
                    "api/card/move", "api/card/comment", "api/card/archive", "api/card/restore",
                    "api/events", "api/stream", "api/health"}
        for path in re.findall(r"\"(api/[a-z/]+)", read("app.js")):
            self.assertIn(path, contract)

    def test_node_check(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node não está instalado; sem checagem de sintaxe do app.js")
        r = subprocess.run([node, "--check", os.path.join(UI, "app.js")],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_ids_referenced_by_js_exist(self):
        html = read("index.html")
        js = read("app.js")
        ids_html = set(re.findall(r"\sid=\"([^\"]+)\"", html))
        ids_js = set(re.findall(r"(?:\$|getElementById)\(\s*\"([^\"]+)\"\s*\)", js))
        ids_js |= set(re.findall(r"\"(panel-[a-z-]+)\"", js))  # ids listed in arrays, then passed to $()
        self.assertTrue(ids_js, "nenhum id encontrado no app.js")
        created = set(re.findall(r"\.id\s*=\s*\"([^\"]+)\"", js))
        missing = sorted(i for i in ids_js if i not in ids_html and i not in created)
        self.assertEqual(missing, [], "ids usados no app.js sem elemento no HTML")
        # for="x" and aria-labelledby="x" in the HTML point at real ids
        for ref in re.findall(r"(?:for|aria-labelledby|aria-describedby)=\"([^\"]+)\"", html):
            self.assertIn(ref, ids_html)

    def test_aria_labels(self):
        html = read("index.html")
        for value in re.findall(r"aria-label=\"([^\"]*)\"", html):
            self.assertTrue(value.strip(), "aria-label vazio no HTML")
        js = read("app.js")
        calls = re.findall(r"setAttribute\(\s*\"aria-label\"\s*,\s*([^;]+)\)", js)
        self.assertTrue(calls, "app.js não dá aria-label aos controles que cria")
        for arg in calls:
            self.assertNotRegex(arg.strip(), r"^\"\"$", "aria-label vazio no app.js")
        # keyboard move: buttons to the previous / next column, labelled
        self.assertIn("anterior", js)
        self.assertIn("seguinte", js)
        self.assertIn("para a coluna", js)
        # every button in the HTML has a name
        for tag in re.findall(r"<button[^>]*>", html):
            self.assertIn("aria-label=", tag)

    def test_live_and_drag(self):
        js = read("app.js")
        for word in ("dragstart", "dragover", "drop", "api/card/move", "index", "reconectando"):
            self.assertIn(word, js)
        self.assertRegex(js, r"window\.collie")

    def test_css_themes_and_motion(self):
        css = read("style.css")
        self.assertRegex(css, r"@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)")
        self.assertRegex(css, r"@media\s*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)")
        self.assertRegex(css, r":root\s*\{[^}]*--[a-z-]+\s*:")
        self.assertIn("focus-visible", css)
        self.assertRegex(css, r"overflow-x\s*:\s*auto")
        self.assertNotRegex(css, r"@import|url\(")


if __name__ == "__main__":
    unittest.main()
