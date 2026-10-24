import Darwin

// `collie-ctty [--sandbox <profile>] <executable> [args…]`: makes the terminal on fd 0 this session's controlling
// terminal, then becomes <executable> (with `--sandbox`: through `sandbox-exec -f <profile>`, which applies the
// profile and execs it in the same pid, so the session and controlling terminal survive). A process posix_spawn'ed
// with POSIX_SPAWN_SETSID onto a PTY replica gets none on macOS (bash happens to take one by reopening its tty; zsh
// doesn't), and without it a resize sends no SIGWINCH and ^C reaches no foreground job. Kept to Darwin calls: it runs
// once per terminal, before the real command. Never falls back to running unsandboxed.
var argv = CommandLine.unsafeArgv + 1, argc = Int(CommandLine.argc) - 1
var profile: UnsafeMutablePointer<CChar>?
if argc > 0, let a = argv[0], String(cString: a) == "--sandbox" {
    guard argc > 2 else { exit(127) }
    profile = argv[1]; argv += 2; argc -= 2
}
guard argc > 0, let exe = argv[0] else { exit(127) }
_ = ioctl(0, TIOCSCTTY, 0)
if let profile {
    let sx = strdup("/usr/bin/sandbox-exec"), f = strdup("-f")
    var args: [UnsafeMutablePointer<CChar>?] = [sx, f, profile]
    for i in 0..<argc { args.append(argv[i]) }
    args.append(nil)
    execv("/usr/bin/sandbox-exec", &args)
} else {
    execv(exe, argv)
}
perror("collie-ctty"); exit(127)
