import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// DX backlog 8: a memory about one platform (android, ios, mac, windows, web) is injected only when the prompt names that
/// platform or names none (an Android CA pitfall on an iPhone question was noise).
@Suite struct PlatformFilterTests {
    private func service(_ recs: [MemoryRecord]) async throws -> (MemoryService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-platform-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mem = MemoryService(globalDir: dir)
        try await mem.global.run { m in for r in recs { try m.store.write(r) } }
        return (mem, root)
    }
    private func rec(_ title: String, _ body: String) -> MemoryRecord {
        MemoryRecord(kind: .pitfall, scope: .project, subject: title, title: title, body: body)
    }

    @Test func platforms() {
        #expect(MemoryService.platforms("Emulador Android: CA via adb") == ["android"])
        #expect(MemoryService.platforms("Simulador do iPhone com simctl") == ["ios"])
        #expect(MemoryService.platforms("macOS e Windows; página web") == ["mac", "windows", "web"])
        #expect(MemoryService.platforms("machine webpack windowsill").isEmpty, "whole words only")
    }

    @Test func anotherPlatformsMemoryIsNotInjected() async throws {
        let android = rec("Emulador Android: CA no store do sistema", "adb root e mitmproxy no emulador")
        let plain = rec("Emulador lento: feche os outros", "o emulador fica lento com muitos processos")
        let (mem, root) = try await service([android, plain])
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory").path
        let ios = await mem.relevant(for: UUID(), cwd: dir, prompt: "o emulador do iPhone não abre")
        #expect(!ios.contains(android.title) && ios.contains(plain.title), "\(ios)")
        #expect(await mem.relevant(for: UUID(), cwd: dir, prompt: "o emulador android não abre").contains(android.title))
        #expect(await mem.relevant(for: UUID(), cwd: dir, prompt: "o emulador não abre").contains(android.title), "no platform named: kept")
    }
}
