import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let collieBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collie").path
private let appOnly = "admin commands are only accepted from the Collie app"

/// The app's identity, faked: only this test process is "the app".
private struct OnlyMe: AdminPeerCheck {
    func allows(_ peer: Peer) -> Bool { peer.pid == getpid() }
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
}
