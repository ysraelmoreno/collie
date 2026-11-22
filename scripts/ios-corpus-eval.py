#!/usr/bin/env python3
"""Mede o corpus iOS do fixture (Helpers/ios-device/fixture): árvore (collie device ui), OCR (Vision) e latências.

Uso: scripts/ios-corpus-eval.py [--udid UDID] [--panel NOME] [--out resultados.json] [--runs 5]

- Sem painel de device alcançável, a parte da árvore e das latências é marcada n/a; o OCR roda sobre `simctl io screenshot`.
- Não instala o Collie nem mexe em paddocks. Só usa o Simulator já ligado e o app já instalado (fixture/build.sh).
- O OCR usa docs/superpowers/specs/2026-11-22-device-poc/ocr/ocr2.swift (compilado fora do repositório).
"""
import argparse, difflib, json, os, re, statistics, subprocess, sys, tempfile, time

BUNDLE = "com.collie.fixture.ios"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OCR_SRC = os.path.join(ROOT, "docs/superpowers/specs/2026-11-22-device-poc/ocr/ocr2.swift")

# Gabarito: todo texto visível (e só ele) em cada tela, sem a barra de status. "icon" = rótulo só de ícone (não conta no recall de texto).
LIST_ROWS = [f"Produto {i:03d}" for i in range(1, 13)]
GT = {
    "normal": ["Painel de Vendas", "Total do mês: R$ 1.234,56 em 42 pedidos", "Confirmar pedido", "Atualizado às 14:35. Versão 2.0.1"],
    "canvas": ["Relatório Anual", "Receita: R$ 1.234,56 · 42 pedidos", "Exportar dados", "Configurações", "Rodapé: atualizado às 14:35"],
    "game": ["SCORE: 12.450", "Vidas: 3", "Nível 7", "JOGAR"],
    "webcanvas": ["Gráfico de Vendas", "Total: R$ 1.234,56", "Região Sul · 42 pedidos", "Baixar relatório", "Rodapé: atualizado às 14:35"],
    "hidden": ["Área Restrita", "Saldo: R$ 1.234,56", "Entrar agora", "Termos de uso, versão 3"],
    "photo": ["Férias em Floripa", "A partir de R$ 1.234,56 por pessoa", "Reserve até 30/12 e ganhe desconto", "Condições sujeitas a alteração"],
    "list": ["Catálogo", "Favoritos"] + LIST_ROWS,
    "form": ["Cadastro", "Nome completo", "E-mail", "Receber novidades", "Mensal", "Anual", "Vitalício", "Enviar cadastro", "Ver termos"],
}
POOR = {"canvas", "game", "webcanvas", "hidden", "photo"}   # árvore pobre esperada; as demais são boas
SETTLE_S = 5.0                                               # o webcanvas leva ~5 s para desenhar
STATUS_RE = re.compile(r"^\d{1,2}[:.]\d{2}$")

def norm(s): return re.sub(r"\s+", " ", re.sub(r"[^\w ]", "", s.lower())).strip()
def close(a, b):
    a, b = norm(a), norm(b)
    return bool(a) and bool(b) and (a in b or b in a or difflib.SequenceMatcher(None, a, b).ratio() >= 0.85)

def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k)

class Collie:
    def __init__(self, panel): self.p = ["--panel", panel] if panel else []
    def run(self, *a):
        t0 = time.perf_counter(); r = sh("collie", "device", *a, *self.p)
        return r.returncode == 0, r.stdout, (time.perf_counter() - t0) * 1000
    def available(self): return self.run("ui")[0]

def stable_tree(c):
    """Duas leituras iguais seguidas; None se não estabilizar em 10 tentativas."""
    prev = None
    for _ in range(10):
        ok, out, _ = c.run("ui", "--all")
        if not ok: return None
        if out == prev: return out
        prev = out; time.sleep(0.6)
    return None

def tree_info(out):
    try: j = json.loads(out)
    except Exception: return out, None
    return (j.get("tree") if isinstance(j.get("tree"), str) else json.dumps(j.get("tree"), ensure_ascii=False)), j.get("nodes")

def median_ms(c, runs, *a):
    v = []
    for _ in range(runs):
        ok, _, ms = c.run(*a)
        if ok: v.append(ms)
    return round(statistics.median(v)) if v else None

def build_ocr(tmp):
    exe = os.path.join(tmp, "ocr2")
    r = sh("swiftc", "-O", "-o", exe, OCR_SRC)
    if r.returncode: sys.exit("falhou ao compilar ocr2.swift: " + r.stderr[-400:])
    return exe

def ocr(exe, png):
    d = json.loads(sh(exe, png, "accurate", "1.0", "4").stdout)
    return [i for i in d["items"] if i["c"] >= 0.5 and len(i["t"].strip()) >= 2], statistics.median(d["runsMs"][1:])

def recall(gt, texts):
    hit = [g for g in gt if any(close(g, t) for t in texts)]
    return len(hit), len(gt), [g for g in gt if g not in hit]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid"); ap.add_argument("--panel"); ap.add_argument("--out"); ap.add_argument("--runs", type=int, default=5)
    a = ap.parse_args()
    udid = a.udid or next(d["udid"] for v in json.loads(sh("xcrun", "simctl", "list", "devices", "booted", "-j").stdout)["devices"].values() for d in v)
    c = Collie(a.panel); has_tree = c.available()
    if not has_tree: print("AVISO: nenhum painel de device alcançável; árvore e latências ficam n/a (só OCR).", file=sys.stderr)
    tmp = tempfile.mkdtemp(); exe = build_ocr(tmp); rows = []
    for theme in ("light", "dark"):
        for name, gt in GT.items():
            sh("xcrun", "simctl", "terminate", udid, BUNDLE)
            sh("xcrun", "simctl", "launch", udid, BUNDLE, "--screen", name, *(["--dark"] if theme == "dark" else []))
            time.sleep(SETTLE_S)
            row = dict(screen=name, theme=theme, poor=name in POOR, gt=len(gt))
            tree = None
            if has_tree:
                tree = stable_tree(c)
                if tree is None: row["discarded"] = "árvore não estabilizou"; rows.append(row); continue
            png = os.path.join(tmp, f"{name}_{theme}.png"); sh("xcrun", "simctl", "io", udid, "screenshot", png)
            items, ocr_ms = ocr(exe, png)
            texts = [i["t"] for i in items]; h, n, miss = recall(gt, texts)
            real = sum(1 for i in items if any(close(g, i["t"]) or close(i["t"], g) for g in gt) or STATUS_RE.match(i["t"].strip()) or i["y"] + i["h"] / 2 < 0.07)
            row.update(ocr_recall=round(h / n, 3), ocr_missed=miss, ocr_items=len(items), ocr_precision=round(real / max(1, len(items)), 3), ocr_ms=round(ocr_ms))
            if has_tree:
                text, nodes = tree_info(tree); th, _, tmiss = recall(gt, re.split(r"[\n\"]", text))
                row.update(tree_nodes=nodes, tree_recall=round(th / n, 3), tree_missed=tmiss,
                           trigger=(nodes is not None and nodes < 3))   # gatilho O2.1 (poucos rótulos); cobertura/classes opacas não medidas aqui
                r = a.runs
                row["ms"] = dict(ui=median_ms(c, r, "ui"), screen=median_ms(c, r, "screen"), find=median_ms(c, r, "find", gt[0]),
                                 tap_text=median_ms(c, r, "tap", "--text", gt[0]), wait_stable=median_ms(c, r, "wait", "--stable"))
            rows.append(row)
            print(json.dumps(row, ensure_ascii=False), flush=True)
    if a.out: json.dump(rows, open(a.out, "w"), ensure_ascii=False, indent=1)
    ok = [r for r in rows if "ocr_recall" in r]
    for label, sel in (("pobres", [r for r in ok if r["poor"]]), ("boas", [r for r in ok if not r["poor"]])):
        if sel: print(f"{label}: n={len(sel)} recall OCR médio {statistics.mean(r['ocr_recall'] for r in sel):.0%}, precisão {statistics.mean(r['ocr_precision'] for r in sel):.0%}, OCR mediana {statistics.median(r['ocr_ms'] for r in sel):.0f} ms")
    if has_tree:
        for label, flag in (("pobres", True), ("boas", False)):
            sel = [r for r in ok if r["poor"] == flag and "trigger" in r]
            if sel: print(f"gatilho em {label}: {sum(r['trigger'] for r in sel)}/{len(sel)}")

if __name__ == "__main__": main()
