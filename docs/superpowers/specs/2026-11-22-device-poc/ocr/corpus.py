import socket, subprocess, time, re, json, sys, os, difflib
A = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"); SER = ["-s", "emulator-5554"]
def adb(*a, **k): return subprocess.run([A, *SER, *a], capture_output=True, **k)
s = socket.create_connection(("127.0.0.1", 7788), timeout=15); f = s.makefile("rwb")
def dump():
    f.write(b"dump\n"); f.flush(); x = f.readline().decode(); f.readline(); return x
def op(line): f.write(line.encode() + b"\n"); f.flush(); return f.readline().decode().strip()
def nodes(x):
    out = []
    for m in re.finditer(r'<node [^>]*?text="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?clickable="(\w+)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x):
        t, d, c, l, tp, r, b = m.groups(); lab = t or d
        if lab and int(r) > int(l) and int(b) > int(tp) and int(l) < 720 and int(tp) < 1280:
            out.append(dict(kind="text" if t else "desc", label=lab.replace("&amp;", "&").replace("&quot;", '"'), clk=c == "true", box=(int(l), int(tp), int(r), int(b))))
    return out
def sig(x): return [(n["label"], n["box"]) for n in nodes(x)]
def capture(name):
    time.sleep(1.5)
    for _ in range(10):
        d1 = dump(); time.sleep(0.5); d2 = dump()
        if sig(d1) == sig(d2) and sig(d1):
            png = adb("exec-out", "screencap", "-p").stdout; d3 = dump()
            if sig(d3) == sig(d1):
                open(f"corpus/{name}.png", "wb").write(png); json.dump(nodes(d3), open(f"corpus/{name}.json", "w")); return len(sig(d3))
        time.sleep(0.7)
    return -1
plan = []
n = capture("bees_combos"); plan.append(("bees_combos", n))
op("back"); n = capture("bees_2"); plan.append(("bees_2", n))
op("back"); n = capture("bees_3"); plan.append(("bees_3", n))
# FAB quick actions
x = dump(); m = re.search(r'resource-id="configuration_fab"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x)
if m:
    l, t, r, b = map(int, m.groups()); op(f"tap {(l+r)//2} {(t+b)//2}"); n = capture("bees_quick"); plan.append(("bees_quick", n)); op("back")
adb("shell", "input", "keyevent", "KEYCODE_HOME"); n = capture("launcher"); plan.append(("launcher", n))
adb("shell", "am", "start", "-a", "android.settings.SETTINGS"); n = capture("settings"); plan.append(("settings", n))
adb("shell", "am", "start", "-a", "android.settings.WIFI_SETTINGS"); n = capture("settings_wifi"); plan.append(("settings_wifi", n))
adb("shell", "am", "start", "-a", "android.settings.APPLICATION_SETTINGS"); n = capture("settings_apps"); plan.append(("settings_apps", n))
adb("shell", "am", "start", "-a", "android.settings.DISPLAY_SETTINGS"); n = capture("settings_display"); plan.append(("settings_display", n))
print(plan)
