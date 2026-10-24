# Stand-in daemon: listens on <dir>/daemon.sock and <dir>/other.sock, answers "ok".
import socket, os, sys, select
ss = []
for n in ("daemon.sock", "other.sock"):
    s = socket.socket(socket.AF_UNIX); s.bind(os.path.join(sys.argv[1], n)); s.listen(8); ss.append(s)
while True:
    for s in select.select(ss, [], [])[0]:
        c, _ = s.accept(); c.send(b"ok\n"); c.close()
