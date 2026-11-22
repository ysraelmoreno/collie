import socket, time, re
s = socket.create_connection(("127.0.0.1", 7788), timeout=10); f = s.makefile("rwb")
def dump():
    f.write(b"dump\n"); f.flush(); x = f.readline().decode(); f.readline(); return x
def sel(x): return re.findall(r'text="(Points|Combos)"[^>]*selected="(true|false)"', x)
before = dump(); print("before:", re.findall(r'selected="true"[^>]*bounds="([^"]+)"', before)[:3])
t0=time.time(); f.write(b"tap 524 512\n"); f.flush(); print(f.readline().decode().strip(), f"{int((time.time()-t0)*1000)} ms")
time.sleep(0.5)
t1=time.time(); after = dump(); print(f"dump after tap {int((time.time()-t1)*1000)} ms; selected:", re.findall(r'selected="true"[^>]*bounds="([^"]+)"', after)[:3])
print("labels:", re.findall(r'text="([^"]+)"', after)[:10])
