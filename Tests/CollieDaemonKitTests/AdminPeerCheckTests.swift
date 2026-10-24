import Testing
import Foundation
import Darwin
import os
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let collieBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collie").path
private let appOnly = Daemon.notAppMessage

/// The app's identity, faked: only this test process is "the app".
private struct OnlyMe: AdminPeerCheck {
    func allows(_ peer: Peer) async -> Bool { peer.pid == getpid() }
}

/// Absolute path of this process's executable (the test runner).
private func selfExecutable() -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _ = _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: realpath(buf, nil)))
}

@Suite struct AdminPeerCheckTests {
    /// The app (here: the test process) keeps admin; any other peer with the admin token is refused, even from outside
    /// every terminal session; a terminal's own token still works from inside its terminal.
    @Test func adminOnlyFromTheApp() async throws {
        try await withDaemon(configure: { $0.adminPeerCheck = OnlyMe() }) { d, p in
            _ = try await spawn(d, p, "B")
            let snap = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(snap.ok, "\(snap)")
            // the user's own shell (not in any terminal) with the admin token file: refused
            let pr = Process(), err = Pipe()
            pr.executableURL = URL(fileURLWithPath: collieBin); pr.arguments = ["admin", "leash", "A", "B"]
            pr.environment = ["COLLIE_SOCKET": p.socket.path, "COLLIE_ADMIN_TOKEN_FILE": p.adminTokenFile.path]
            pr.standardError = err; pr.standardOutput = Pipe()
            try pr.run(); pr.waitUntilExit()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(pr.terminationStatus == 1 && text.contains(appOnly), "\(text)")
            // the CLI's admin fallback for paddock.* outside a terminal: refused too
            let sh = Process(), out = Pipe()
            sh.executableURL = URL(fileURLWithPath: collieBin); sh.arguments = ["paddock", "list"]
            sh.environment = ["COLLIE_SOCKET": p.socket.path, "COLLIE_ADMIN_TOKEN_FILE": p.adminTokenFile.path]
            sh.standardError = out; sh.standardOutput = Pipe()
            try sh.run(); sh.waitUntilExit()
            #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(appOnly))
            // a terminal token from inside its terminal: unaffected
            let a = try await spawn(d, p, "A", preset: "custom", command: "'\(collieBin)' list; echo RC=$?; exec sleep 300")
            let id = UUID(uuidString: a.id)!
            #expect(await waitFor(10) { await d.scrollbackText(id).contains("RC=") })
            let screen = await d.scrollbackText(id)
            #expect(screen.contains("RC=0"), "\(screen)")
        }
    }

    /// The Security.framework check, end to end through the socket's audit token: the expected executable's
    /// signature passes; one that can't be read refuses everyone (fail closed).
    @Test func signedAppCheck() async throws {
        try await withDaemon(configure: { $0.adminPeerCheck = SignedAppCheck(app: selfExecutable()) }) { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(r.ok, "\(r)")
        }
        try await withDaemon(configure: { $0.adminPeerCheck = SignedAppCheck(app: URL(fileURLWithPath: "/nonexistent/Collie")) }) { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(!r.ok && r.error?.code == .unauthorized && r.error?.message == appOnly, "\(r)")
        }
        // a different signed executable is not the app
        try await withDaemon(configure: { $0.adminPeerCheck = SignedAppCheck(app: URL(fileURLWithPath: "/bin/ls")) }) { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(!r.ok && r.error?.message == appOnly, "\(r)")
        }
    }

    /// A flood of refused admin requests (500 connections open at once from one process, and 20 distinct processes)
    /// neither wedges the daemon nor delays a terminal-token request sent in the middle of it. The flood comes from a
    /// child process: 500 client threads in this process would starve the other suites running alongside.
    @Test func refusedFloodDoesNotStarveTheDaemon() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-app-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try makeApp(in: dir, name: "X").appendingPathComponent("Contents/MacOS/Collie").path
        let check = Gate(SignedAppCheck(app: URL(fileURLWithPath: "/bin/ls")))
        try await withDaemon(configure: { $0.adminPeerCheck = check }) { d, p in
            let a = try await spawn(d, p, "A", preset: "custom", command: "exec sleep 300")
            check.open.withLock { $0 = false }
            let tid = try #require(UUID(uuidString: a.id)), tok = await d.router.auth.issue(for: tid)
            let start = ContinuousClock.now
            try await withThrowingTaskGroup(of: String.self) { g in
                g.addTask { try await runOffPool(client, [p.socket.path, d.adminToken, "flood", "500"]) }
                for _ in 0..<20 {   // distinct processes: one Security check each, all on the check's own queue
                    g.addTask { try await runOffPool(client, [p.socket.path, d.adminToken]) }
                }
                try await Task.sleep(for: .milliseconds(100))
                // a connect can still meet a full listen backlog (128): retried; timed from the attempt that got through
                var r: Response?, took = Duration.zero
                for _ in 0..<50 where r == nil {
                    let t0 = ContinuousClock.now
                    r = try? await send(p, Request(id: "t", terminalId: a.id, token: tok, command: "list"))
                    took = ContinuousClock.now - t0
                    if r == nil { try? await Task.sleep(for: .milliseconds(20)) }
                }
                #expect(r?.ok == true && took < .seconds(2), "\(String(describing: r)) after \(took)")
                var outs: [String] = []
                for try await o in g { outs.append(o) }
                #expect(outs.contains("refused=500 ok=0\n"), "\(outs.filter { $0.hasPrefix("refused=") })")
                #expect(outs.filter { $0.contains(Daemon.notAppMessage) }.count == 20)
            }
            #expect(ContinuousClock.now - start < .seconds(20), "flood took \(ContinuousClock.now - start)")
        }
    }

    /// The real path: a hardened-runtime, ad-hoc-signed X.app whose Contents/MacOS/Collie connects over the socket.
    /// Accepted from the bundle; refused as a copy outside the bundle and as a one-byte-modified, re-signed build.
    @Test func realAppBundle() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-app-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = try makeApp(in: dir, name: "X")
        try await withDaemon(configure: { $0.adminPeerCheck = SignedAppCheck(app: x.appendingPathComponent("Contents/MacOS/Collie")) }) { d, p in
            let ok = try await runOffPool(x.appendingPathComponent("Contents/MacOS/Collie").path, [p.socket.path, d.adminToken])
            #expect(ok.contains("\"ok\":true"), "\(ok)")
            let loose = dir.appendingPathComponent("Collie")
            try FileManager.default.copyItem(at: x.appendingPathComponent("Contents/MacOS/Collie"), to: loose)
            let out = try await runOffPool(loose.path, [p.socket.path, d.adminToken])
            #expect(!out.contains("\"ok\":true"), "\(out)")
            let y = dir.appendingPathComponent("Y.app"), exe = y.appendingPathComponent("Contents/MacOS/Collie")
            try FileManager.default.copyItem(at: x, to: y)
            var bin = try Data(contentsOf: exe)
            let r = try #require(bin.range(of: Data("COLLIE-TEST-MARK".utf8)))
            bin[r.upperBound - 1] = UInt8(ascii: "X")
            try bin.write(to: exe)
            _ = try await runOffPool("/usr/bin/codesign", ["--force", "--deep", "-s", "-", "--options", "runtime", y.path])
            let mod = try await runOffPool(exe.path, [p.socket.path, d.adminToken])
            #expect(mod.contains(Daemon.notAppMessage), "\(mod)")
        }
    }

    /// An app not valid yet (mid-copy of an update: executable in place, seal still missing) is not remembered as
    /// unreadable under its final stat: read again a second later.
    @Test func unreadableAppIsReadAgain() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-app-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = try makeApp(in: dir, name: "X"), z = dir.appendingPathComponent("Z.app")
        let exe = z.appendingPathComponent("Contents/MacOS/Collie")
        try await withDaemon(configure: { $0.adminPeerCheck = SignedAppCheck(app: exe) }) { d, p in
            // the executable is in place (its final stat) but the bundle seal isn't copied yet
            let seal = dir.appendingPathComponent("seal")
            try FileManager.default.copyItem(at: x, to: z)
            try FileManager.default.moveItem(at: z.appendingPathComponent("Contents/_CodeSignature"), to: seal)
            let before = try await runOffPool(x.appendingPathComponent("Contents/MacOS/Collie").path, [p.socket.path, d.adminToken])
            #expect(before.contains(Daemon.notAppMessage), "\(before)")
            try FileManager.default.moveItem(at: seal, to: z.appendingPathComponent("Contents/_CodeSignature"))
            try await Task.sleep(for: .milliseconds(1100))
            let after = try await runOffPool(exe.path, [p.socket.path, d.adminToken])
            #expect(after.contains("\"ok\":true"), "\(after)")
        }
    }

    /// Which check a daemon runs with, by where its executable sits and which root it serves.
    @Test func checkForDaemon() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-app-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = try makeApp(in: dir, name: "X", helper: true)
        let def = dir.appendingPathComponent("Collie"), link = dir.appendingPathComponent("Orq"), other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: def, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: def)
        let collied = x.appendingPathComponent("Contents/Helpers/collied")
        #expect(SignedAppCheck.forDaemon(executable: collied, root: other, defaultRoot: def).note.hasPrefix("admin only from"))
        // outside a bundle: off on another root; refuse-all on the default root, however it is spelled
        let loose = URL(fileURLWithPath: collieBin)
        #expect(SignedAppCheck.forDaemon(executable: loose, root: other, defaultRoot: def).check == nil)
        let viaPrivate = URL(fileURLWithPath: "/private" + def.path)
        let viaFirmlink = URL(fileURLWithPath: "/System/Volumes/Data" + SignedAppCheck.realPath(def))
        for root in [def, link, viaPrivate, viaFirmlink] {
            let (check, note) = SignedAppCheck.forDaemon(executable: loose, root: root, defaultRoot: def)
            #expect(check != nil && note.contains("refused"), "\(root.path): \(note)")
        }
        // the bundle shape alone is not enough: an unsigned collied in it is not trusted
        let fake = dir.appendingPathComponent("F.app/Contents"), fakeD = fake.appendingPathComponent("Helpers/collied")
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: fakeD, atomically: true, encoding: .utf8); chmod(fakeD.path, 0o755)
        try FileManager.default.copyItem(at: x.appendingPathComponent("Contents/MacOS/Collie"), to: fake.appendingPathComponent("MacOS/Collie"))
        #expect(SignedAppCheck.forDaemon(executable: fakeD, root: def, defaultRoot: def).note.contains("refused"))
    }
}

/// A check the test can open (to set up terminals with admin) before closing it to the real one.
private final class Gate: AdminPeerCheck {
    let open = OSAllocatedUnfairLock(initialState: true)
    let real: SignedAppCheck
    init(_ real: SignedAppCheck) { self.real = real }
    func allows(_ peer: Peer) async -> Bool { open.withLock { $0 } ? true : await real.allows(peer) }
}

private let clientSource = """
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static const char mark[] = "COLLIE-TEST-MARK";
static int dial(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    return fd;
}
static int ask(int fd, const char *token) {
    char req[512];
    int n = snprintf(req, sizeof req, "{\\"v\\":1,\\"id\\":\\"%s\\",\\"token\\":\\"%s\\",\\"command\\":\\"ui.snapshot\\",\\"args\\":{}}\\n", mark, token);
    return write(fd, req, n) == n;
}
static ssize_t answer(int fd, char *buf, size_t cap) {
    size_t got = 0; ssize_t r;
    while (got < cap - 1 && (r = read(fd, buf + got, cap - 1 - got)) > 0) got += r;
    buf[got] = 0; return got;
}
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    alarm(30);   // a wedged daemon must not leave this client behind
    static char buf[65536];
    if (argc > 4 && strcmp(argv[3], "flood") == 0) {   // `flood N`: N connections open at once, then all answers
        int n = atoi(argv[4]), refused = 0, ok = 0;
        struct rlimit rl = { 4096, 4096 }; setrlimit(RLIMIT_NOFILE, &rl);
        int *fds = calloc(n, sizeof(int));
        for (int i = 0; i < n; i++) {
            for (int t = 0; t < 500 && (fds[i] = dial(argv[1])) < 0; t++) usleep(10000);   // full backlog: retry
            if (fds[i] < 0 || !ask(fds[i], argv[2])) { perror("flood"); return 3; }
        }
        for (int i = 0; i < n; i++) {
            answer(fds[i], buf, sizeof buf);
            if (strstr(buf, "\\"ok\\":true")) ok++;
            else if (strstr(buf, "only accepted from the Collie app")) refused++;
            close(fds[i]);
        }
        printf("refused=%d ok=%d\\n", refused, ok);
        return 0;
    }
    int fd = -1;
    for (int t = 0; t < 500 && (fd = dial(argv[1])) < 0; t++) usleep(10000);   // full backlog: retry
    if (fd < 0) { perror("connect"); return 2; }
    if (!ask(fd, argv[2])) return 2;
    answer(fd, buf, sizeof buf);
    fputs(buf, stdout);
    return 0;
}
"""

/// `<dir>/<name>.app` like bundle-app.sh: the client as Contents/MacOS/Collie (and, with `helper`, a copy as
/// Contents/Helpers/collied), a resource, ad-hoc signed with the hardened runtime.
private func makeApp(in dir: URL, name: String, helper: Bool = false) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app"), c = app.appendingPathComponent("Contents")
    for sub in ["MacOS", "Resources", "Helpers"] {
        try FileManager.default.createDirectory(at: c.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    let src = dir.appendingPathComponent("client.c")
    try clientSource.write(to: src, atomically: true, encoding: .utf8)
    _ = try run("/usr/bin/cc", ["-O0", "-o", c.appendingPathComponent("MacOS/Collie").path, src.path])
    try "res".write(to: c.appendingPathComponent("Resources/data.txt"), atomically: true, encoding: .utf8)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Collie</string>
    <key>CFBundleIdentifier</key><string>dev.collie.test.\(name)</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """.write(to: c.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    if helper {
        let h = c.appendingPathComponent("Helpers/collied")
        try FileManager.default.copyItem(at: c.appendingPathComponent("MacOS/Collie"), to: h)
        _ = try run("/usr/bin/codesign", ["--force", "-s", "-", "--options", "runtime", h.path])
    }
    _ = try run("/usr/bin/codesign", ["--force", "--deep", "-s", "-", "--options", "runtime", app.path])
    return app
}

/// Runs `exe` to completion; stdout + stderr.
@discardableResult private func run(_ exe: String, _ args: [String]) throws -> String {
    let pr = Process(), out = Pipe()
    pr.executableURL = URL(fileURLWithPath: exe); pr.arguments = args
    pr.standardOutput = out; pr.standardError = out
    try pr.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    pr.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// `run` on its own thread: a child waited on from the cooperative pool would starve the in-process daemon.
private func runOffPool(_ exe: String, _ args: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { c in
        Thread { c.resume(with: Result { try run(exe, args) }) }.start()
    }
}
