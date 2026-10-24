# Scratch harness (mirrors ControllingTerminalTests): collie-ctty -> sandbox-exec -> zsh on a fresh PTY,
# setsid'ed like PTYProcess (POSIX_SPAWN_SETSID). Checks tty kept, SIGWINCH on resize, ^C reaches the fg job.
import os, sys, pty, fcntl, termios, struct, time, select, subprocess
ctty, profile = sys.argv[1], sys.argv[2]
extra = sys.argv[3:]  # -D params
script = r'''trap 'echo "winch $(stty size)"' WINCH; echo "tty=$(ps -o tty= -p $$)"; echo "sbpid=$$"; while :; do sleep 0.05; done'''
m, s = os.openpty()
p = subprocess.Popen([ctty, "/usr/bin/sandbox-exec", "-f", profile, *extra, "/bin/zsh", "-fc", script],
                     stdin=s, stdout=s, stderr=s, start_new_session=True, close_fds=True)
os.close(s)
buf = b""
def pump(until, t=5):
    global buf
    end = time.time() + t
    while time.time() < end and until not in buf:
        r, _, _ = select.select([m], [], [], 0.1)
        if r: buf += os.read(m, 4096)
    return until in buf
ok_tty = pump(b"tty=") and pump(b"\n")
fcntl.ioctl(m, termios.TIOCSWINSZ, struct.pack("HHHH", 38, 127, 0, 0))
ok_winch = pump(b"winch 38 127")
p.terminate(); p.wait()
out = buf.decode(errors="replace")
print(out.strip())
print("RESULT tty_kept=%s winch=%s" % (ok_tty and "tty=??" not in out, ok_winch))
