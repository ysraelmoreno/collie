import Darwin

// `collie-ctty <executable> [args…]`: makes the terminal on fd 0 this session's controlling terminal, then becomes
// <executable>. A process posix_spawn'ed with POSIX_SPAWN_SETSID onto a PTY replica gets none on macOS (bash
// happens to take one by reopening its tty; zsh doesn't), and without it a resize sends no SIGWINCH and ^C reaches
// no foreground job. Kept to Darwin calls: it runs once per terminal, before the real command.
guard CommandLine.argc > 1, let exe = CommandLine.unsafeArgv[1] else { exit(127) }
_ = ioctl(0, TIOCSCTTY, 0)
execv(exe, CommandLine.unsafeArgv + 1)
perror("collie-ctty"); exit(127)
