import Foundation
import OrqCore
import OrqProtocol

/// `<dir>/<name>.jsonl` (0600): the work chat's newest messages, one JSON object per line, oldest first. Past `high`
/// the oldest go to `<dir>/<name>-archive.jsonl` (append-only) until `keep` remain; `clear` moves the whole file there.
/// Disk work runs on one serial queue, off the cooperative pool.
actor ChatLog {
    static let keep = 1_000, high = 1_200
    let dir: URL
    private let name: String
    private var all: [ChatMessage]?   // loaded on first use
    private let io = DispatchQueue(label: "orq.chat")

    init(dir: URL, name: String = "work-chat") { self.dir = dir; self.name = name }

    var file: URL { dir.appendingPathComponent("\(name).jsonl") }
    var archive: URL { dir.appendingPathComponent("\(name)-archive.jsonl") }

    func append(_ m: ChatMessage) async throws {
        var list = try await load()
        list.append(m)
        let f = file, a = archive
        // memory is updated before the write is queued (in order, on the serial queue): a concurrent append never loses this one
        if list.count > Self.high {
            let gone = try list.prefix(list.count - Self.keep).map(Self.line)
            let kept = Array(list.suffix(Self.keep))
            let data = try kept.reduce(into: Data()) { $0.append(try Self.line($1)) }
            all = kept
            // archive first: append-only, so a failure after it only duplicates lines on retry
            try await write { try WorkStore.append(gone, to: a); try DesignService.writePrivate(data, to: f) }
        } else {
            let line = try Self.line(m)
            all = list
            try await write { try WorkStore.append([line], to: f) }
        }
    }

    /// Newest first: the `limit` messages older than `before` (nil: the newest). An id not in the file: `notFound`.
    func page(before: UUID?, limit: Int) async throws -> [ChatMessage] {
        let list = try await load()
        var end = list.endIndex
        if let before {
            guard let i = list.firstIndex(where: { $0.id == before }) else {
                throw ProtocolError(code: .notFound, message: "Mensagem não encontrada.")
            }
            end = i
        }
        return Array(list[..<end].suffix(limit).reversed())
    }

    /// The file's bytes as they are (unreadable lines too) appended to the archive, then the file emptied.
    func clear() async throws {
        _ = try await load()
        all = []
        let f = file, a = archive
        try await write {
            let d: Data
            do { d = try Data(contentsOf: f) }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile { return }
            catch { throw ProtocolError(code: .internal, message: "chat: cannot read \(f.path)") }
            if !d.isEmpty { try WorkStore.append([d], to: a) }
            try WorkStore.truncate(f)
        }
    }

    /// Runs `body` while no chat write runs: the ones queued meanwhile wait (the backup copies `work/`).
    func withPaused<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let gate = DispatchSemaphore(value: 0)
        // the serial queue holds here (a dispatch thread, not the cooperative pool) until `body` is done
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in io.async { c.resume(); gate.wait() } }
        defer { gate.signal() }
        return try await body()
    }

    // MARK: disk

    private func load() async throws -> [ChatMessage] {
        if let all { return all }
        let f = file
        let loaded = try await onIO { () throws -> [ChatMessage] in
            let d: Data
            do { d = try Data(contentsOf: f) }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile { return [] }
            catch { throw ProtocolError(code: .internal, message: "chat: cannot read \(f.path)") }
            // ponytail: an unreadable line is skipped (not shown), never rewritten away until the next overflow or clear
            return d.split(separator: 0x0A).compactMap { try? Self.decoder.decode(ChatMessage.self, from: Data($0)) }
        }
        if all == nil { all = loaded }
        return all ?? loaded
    }

    /// A failed write drops the in-memory copy: the next call reads the disk again.
    private func write(_ body: @escaping @Sendable () throws -> Void) async throws {
        do { try await onIO(body) } catch { all = nil; throw error }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static func line(_ m: ChatMessage) throws(ProtocolError) -> Data {
        guard var d = try? encoder.encode(m) else { throw ProtocolError(code: .internal, message: "chat: cannot encode") }
        d.append(0x0A); return d
    }

    /// `body` on the serial queue; enqueued before this returns to the actor, so calls run in the order made.
    private func onIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await withCheckedThrowingContinuation { c in io.async { c.resume(with: Result { try body() }) } }
        } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
    }
}
