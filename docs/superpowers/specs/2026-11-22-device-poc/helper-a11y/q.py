import socket, time, sys, re
s = socket.create_connection(("127.0.0.1", 7788), timeout=10); f = s.makefile("rwb")
for i in range(5):
    t0 = time.time(); f.write(b"dump\n"); f.flush()
    xml = f.readline().decode(); end = f.readline().decode().strip()
    print(f"dump {i}: wall {int((time.time()-t0)*1000)} ms, service {end}, {len(xml)} bytes, nodes={xml.count('<node')}")
labels = re.findall(r'text="([^"]+)"', xml)
print("labels:", labels[:12]); print("ids:", re.findall(r'resource-id="([^"]+)"', xml)[:6])
