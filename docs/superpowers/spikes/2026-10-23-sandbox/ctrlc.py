# ^C on the PTY reaches the foreground job (kernel tty signal), with and without sandbox-exec in the chain.
import os, sys, subprocess, time, select
ctty, pre = sys.argv[1], sys.argv[2:]
m, s = os.openpty()
p = subprocess.Popen([ctty, *pre, "/bin/zsh", "-fc", "trap 'echo got-int' INT; /bin/sleep 30; echo after-sleep-rc=$?"],
                     stdin=s, stdout=s, stderr=s, start_new_session=True)
os.close(s); time.sleep(1); os.write(m, b"\x03"); buf=b""; end=time.time()+5
while time.time()<end and b"after-sleep" not in buf:
    if select.select([m],[],[],0.1)[0]: buf+=os.read(m,4096)
print(buf.decode(errors="replace").strip().replace("\r\n"," | ")); p.kill()
print("RESULT ctrl_c=%s" % (b"after-sleep-rc=130" in buf))
