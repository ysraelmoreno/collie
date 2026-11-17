import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

struct MaintenanceTests {
    @Test func enterLeave() async throws {
        let m = Maintenance()
        #expect(await m.active == nil)
        try await m.enter("update")
        #expect(await m.active == "update")
        await m.leave("update")
        #expect(await m.active == nil)
    }

    @Test func secondEnterConflicts() async throws {
        let m = Maintenance()
        try await m.enter("backup")
        do { try await m.enter("update"); Issue.record("expected a conflict") }
        catch { #expect(error.code == .conflict); #expect(error.message == "backup em andamento") }
        await m.leave("update")   // not the holder: no effect
        #expect(await m.active == "backup")
    }

    @Test func backupEntersMaintenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let m = Maintenance()
        try await m.enter("update")
        let server = FigcraftServer(engine: { nil }, dataDir: root.appendingPathComponent("design/server"), runDir: root)
        do {
            _ = try await DataBackup.export(root: root, to: root.appendingPathComponent("b.colliebackup"), server: server,
                                            version: "t", maintenance: m)
            Issue.record("expected a conflict")
        } catch { #expect(error.code == .conflict) }
        do {
            _ = try await DataBackup.stage(root: root, from: root.appendingPathComponent("none.colliebackup"), dryRun: true, maintenance: m)
            Issue.record("expected a conflict")
        } catch { #expect(error.code == .conflict) }
        await m.leave("update")
        #expect(await m.active == nil)   // a refused backup never holds it
    }
}
