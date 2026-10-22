import Foundation

public actor WorkspaceStore {
    private let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    private func file(_ id: UUID) -> URL { paths.workspaceDir(id).appendingPathComponent("workspace.json") }

    public func load(_ id: UUID) throws -> Workspace {
        try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file(id)))
    }

    public func save(_ ws: Workspace) throws {
        try FileManager.default.createDirectory(at: paths.workspaceDir(ws.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(ws).write(to: file(ws.id), options: .atomic)
    }
}
