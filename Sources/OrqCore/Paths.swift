import Foundation

public struct Paths: Sendable {
    public var root: URL
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orq")
    }
    public init(root: URL = Paths.defaultRoot) { self.root = root }
    public var runDir: URL { root.appendingPathComponent("run") }
    public var socket: URL { runDir.appendingPathComponent("orqd.sock") }
    public var adminTokenFile: URL { root.appendingPathComponent("admin.token") }
    public func workspaceDir(_ id: UUID) -> URL {
        root.appendingPathComponent("workspaces").appendingPathComponent(id.uuidString)
    }
}
