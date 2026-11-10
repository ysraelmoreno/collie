#!/usr/bin/env python3
"""Gera demo-only.html (sem a cena de fecho) a partir de index.html. Rode antes de renderizar a variante."""
import re
s = open("index.html").read()
s = re.sub(r'\n      <div id="outro".*?</div>\n    </div>\n\n?    <script>', '\n    </div>\n\n    <script>', s, flags=re.S)
s = re.sub(r'\n      // cena 4.*?\n\n', '\n\n', s, flags=re.S)
s = re.sub(r'\n      tl\.set\("#app".*?\n', '\n', s)
s = s.replace('data-duration="26"', 'data-duration="21"')
open("demo-only.html", "w").write(s)
