import Testing
import Foundation
@testable import CollieCore

@Test func storeRoundTripsAtomically() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root)
    let a = TerminalRecord(id: UUID(), name: "A", preset: .claude, command: nil, cwd: "/x", isMaestro: true)
    let w = Workspace(id: UUID(), name: "w", terminals: [a], connections: [Connection(a: a.id, b: UUID())])
    let store = WorkspaceStore(paths: paths)
    try await store.save(w)
    #expect(FileManager.default.fileExists(atPath: paths.workspaceDir(w.id).appendingPathComponent("workspace.json").path))
    #expect(try await store.load(w.id) == w)
}

@Test func workspaceFieldsRoundTrip() throws {
    let old = #"{"schemaVersion":3,"id":"\#(UUID())","name":"w","terminals":[],"connections":[],"floors":[{"id":"\#(UUID())","name":"f","repoRoot":"/r","path":"/r/.collie/floors/f","branch":"collie/f","baseBranch":"main","status":"working"}],"panels":[]}"#
    let w = try JSONDecoder().decode(Workspace.self, from: Data(old.utf8))
    #expect(w.designSystem == nil && w.floors.first?.designSystem == nil)
    var w2 = w
    w2.designSystem = UUID(); w2.floors[0].designSystem = UUID()
    #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w2)) == w2)
}
