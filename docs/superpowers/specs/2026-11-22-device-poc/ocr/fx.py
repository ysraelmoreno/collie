import subprocess, os, re, json, time, socket, difflib, statistics
A = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"); SER = ["-s", "emulator-5554"]
def adb(*a): return subprocess.run([A, *SER, *a], capture_output=True).stdout
s = socket.create_connection(("127.0.0.1", 7788), timeout=15); f = s.makefile("rwb")
def dump(): f.write(b"dump\n"); f.flush(); x = f.readline().decode(); f.readline(); return x
def labeled(x):
    n = 0; clickable = 0
    for m in re.finditer(r'<node [^>]*?text="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?clickable="(\w+)"', x):
        if m.group(1) or m.group(2): n += 1
        if m.group(3) == "true": clickable += 1
    return n, clickable, x.count("<node")
def norm(s): return re.sub(r"\s+", " ", re.sub(r"[^\w ]", "", s.lower())).strip()
def close(a, b): a, b = norm(a), norm(b); return bool(a) and bool(b) and (a in b or b in a or difflib.SequenceMatcher(None, a, b).ratio() >= 0.8)
GT = {
 "canvas": ["Configurações", "Olá, Ysrael! Bem-vindo de volta", "Texto pequeno de apoio, versão 2.4.1 (build 318)", "Entrar", "Criar conta", "Esqueci a senha", "Total: R$ 1.234,56"],
 "surface": ["SCORE 001240", "Vidas: 3", "Nível 7", "JOGAR", "Toque para continuar"],
 "webcanvas": ["Resumo do pedido", "Cerveja Pilsen 350ml x12", "Refrigerante Cola 2L x6", "Subtotal: R$ 189,90", "Finalizar pedido"],
 "hidden": ["Meus pedidos", "Pedido #48213 - Entregue", "Pedido #48210 - Em transporte", "Ver detalhes", "Atualizado há 3 minutos"],
 "photo": ["Promoção da semana", "Até 30% de desconto", "Válido até 30/11 ou enquanto durarem os estoques", "Aproveite agora"],
 "normal": ["Tela normal", "Todos os elementos têm acessibilidade", "Continuar", "Rodapé de exemplo"],
}
rows = []
for dark in (False, True):
    for name, gt in GT.items():
        adb("shell", "am", "force-stop", "com.collie.fixture")
        args = ["shell", "am", "start", "-n", "com.collie.fixture/.MainActivity", "--es", "screen", name] + (["--ez", "dark", "true"] if dark else [])
        adb(*args); time.sleep(2.5)
        x1 = dump(); png = adb("exec-out", "screencap", "-p"); x2 = dump(); tag = f"{name}{'_dark' if dark else ''}"
        open(f"fx/{tag}.png", "wb").write(png)
        n, clk, total = labeled(x2); row = dict(screen=tag, tree_labeled=n, tree_clickable=clk, tree_nodes=total)
        for mode in ("fast", "accurate"):
            d = json.loads(subprocess.run(["./ocr2", f"fx/{tag}.png", mode, "1.0", "3"], capture_output=True, text=True).stdout)
            items = [i["t"] for i in d["items"] if i["c"] >= 0.5 and len(i["t"].strip()) >= 2]
            hit = sum(any(close(g, t) for t in items) for g in gt)
            row[mode] = f"{hit}/{len(gt)} {int(statistics.median(d['runsMs'][1:]))}ms"
        rows.append(row); print(row)
