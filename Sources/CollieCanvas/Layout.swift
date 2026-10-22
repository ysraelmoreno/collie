import CoreGraphics
import Foundation
import CollieCore

/// Persisted as `<root>/workspaces/<id>/layout.json`; frames keyed by uuidString.
public struct LayoutFile: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var offset: CGPoint
    public var zoom: CGFloat
    public var frames: [UUID: CGRect]

    public init(offset: CGPoint, zoom: CGFloat, frames: [UUID: CGRect]) {
        self.offset = offset; self.zoom = zoom; self.frames = frames
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, offset, zoom, frames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        offset = try c.decode(CGPoint.self, forKey: .offset)
        zoom = try c.decode(CGFloat.self, forKey: .zoom)
        guard zoom.isFinite, zoom > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .zoom, in: c, debugDescription: "invalid zoom")
        }
        let raw = try c.decode([String: CGRect].self, forKey: .frames)
        frames = Dictionary(raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(offset, forKey: .offset)
        try c.encode(zoom, forKey: .zoom)
        try c.encode(Dictionary(uniqueKeysWithValues: frames.map { ($0.key.uuidString, $0.value) }), forKey: .frames)
    }
}

/// Debouncing (500 ms) is the caller's job.
public enum LayoutStore {
    public static func load(_ url: URL) -> LayoutFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayoutFile.self, from: d)
    }

    public static func save(_ f: LayoutFile, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try e.encode(f).write(to: url, options: .atomic)
    }
}

/// A partitura's frames laid out with their union's top-left corner at `anchor` (canvas point). Sizes are clamped
/// again to what a partitura may carry (the daemon validates them; a terminal's size becomes its PTY's).
public func placeFrames(_ rel: [UUID: CGRect], anchor: CGPoint) -> [UUID: CGRect] {
    let minX = rel.values.map(\.minX).min() ?? 0, minY = rel.values.map(\.minY).min() ?? 0
    let r = PartituraFormat.panelSize
    func c(_ v: CGFloat) -> CGFloat { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound }
    return rel.mapValues { f in
        CGRect(x: f.minX - minX + anchor.x, y: f.minY - minY + anchor.y, width: c(f.width), height: c(f.height))
    }
}

/// A Maestro's application: everything but the Maestro itself (`skipping`), 80 pt right of its frame, top-aligned.
public func placeFrames(_ rel: [UUID: CGRect], rightOf maestro: CGRect, skipping id: UUID?) -> [UUID: CGRect] {
    placeFrames(rel.filter { $0.key != id }, anchor: CGPoint(x: maestro.maxX + 80, y: maestro.minY))
}
