import json, subprocess, glob, os, re, difflib, statistics
def norm(s): return re.sub(r"\s+", " ", re.sub(r"[^\w ]", "", s.lower())).strip()
def close(a, b): a, b = norm(a), norm(b); return bool(a) and bool(b) and (a in b or b in a or difflib.SequenceMatcher(None, a, b).ratio() >= 0.85)
W, H = 720, 1280
for mode in ("fast", "accurate"):
    T = dict(gt=0, hit=0, desc=0, items=0, matched=0, extra=0, pos=0, poshit=0); ms = []; miss = []; ex = []
    for png in sorted(glob.glob("corpus/*.png")):
        name = os.path.basename(png)[:-4]; gt = json.load(open(f"corpus/{name}.json"))
        d = json.loads(subprocess.run(["./ocr2", png, mode, "1.0", "4"], capture_output=True, text=True).stdout); ms.append(statistics.median(d["runsMs"][1:]))
        items = [i for i in d["items"] if i["c"] >= 0.5 and len(i["t"].strip()) >= 2]
        for g in gt:
            if g["kind"] != "text": T["desc"] += 1; continue
            T["gt"] += 1
            if any(close(g["label"], i["t"]) or close(i["t"], g["label"]) for i in items): T["hit"] += 1
            else: miss.append((name, g["label"][:30]))
        for i in items:
            T["items"] += 1; cx, cy = (i["x"] + i["w"] / 2) * W, (i["y"] + i["h"] / 2) * H
            lab = [g for g in gt if close(g["label"], i["t"]) or close(i["t"], g["label"])]
            if lab:
                T["matched"] += 1; T["pos"] += 1
                T["poshit"] += any(g["box"][0]-10 <= cx <= g["box"][2]+10 and g["box"][1]-10 <= cy <= g["box"][3]+10 for g in lab)
            else: T["extra"] += 1; ex.append((name, i["t"][:25], round(i["c"], 2)))
    print(f"\n[{mode}] text-recall {T['hit']}/{T['gt']} = {100*T['hit']/max(1,T['gt']):.0f}% | items={T['items']} matched={T['matched']} extra(not in tree)={T['extra']} | position-hit {T['poshit']}/{T['pos']} | median {statistics.median(ms):.0f} ms, max {max(ms):.0f} ms | icon-only labels in tree: {T['desc']}")
    print("  missed:", miss[:12]); print("  extra:", ex[:14])
