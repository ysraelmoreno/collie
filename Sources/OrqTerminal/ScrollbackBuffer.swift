import Foundation

public final class ScrollbackBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let cap: Int
    private let spillCap: Int
    private var spillFd: Int32 = -1   // closed on process exit / removal / cap; guarded by lock
    private var spilled = 0
    public let spillURL: URL?
    private var chunks: [Data] = []
    private var head = 0          // first live chunk; compacted lazily
    private var mem = 0
    private var total = 0         // absolute bytes ever written

    /// `spillCapBytes`: disk history per launch; beyond it the spill stops (memory tail keeps working).
    public init(memoryCapBytes: Int = 1_048_576, spillURL: URL?, spillCapBytes: Int = 128 * 1_048_576) {
        cap = memoryCapBytes
        spillCap = spillCapBytes
        self.spillURL = spillURL
        if let url = spillURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            spillFd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        }
    }

    deinit { if spillFd >= 0 { close(spillFd) } }

    /// Releases the spill fd (process exited); `deleting` also removes the file (terminal removed).
    public func closeSpill(deleting: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if spillFd >= 0 { close(spillFd); spillFd = -1 }
        if deleting, let u = spillURL { try? FileManager.default.removeItem(at: u) }
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if spillFd >= 0 {
            let n = min(data.count, spillCap - spilled)
            // ponytail: short/failed writes to a regular file are dropped (disk full), like the old try?
            if n > 0 { _ = data.withUnsafeBytes { write(spillFd, $0.baseAddress, n) } }
            spilled += n
            if spilled >= spillCap { close(spillFd); spillFd = -1 }
        }
        chunks.append(data)
        mem += data.count
        total += data.count
        while mem > cap {
            let excess = mem - cap
            let first = chunks[head]
            if first.count <= excess {
                chunks[head] = Data()
                head += 1
                mem -= first.count
            } else {
                chunks[head] = Data(first.suffix(first.count - excess))  // re-base indices
                mem = cap
            }
        }
        if head > 64 && head * 2 > chunks.count {  // ponytail: amortized compaction
            chunks.removeFirst(head)
            head = 0
        }
    }

    public var totalBytesWritten: Int { lock.lock(); defer { lock.unlock() }; return total }
    public var memoryBytes: Int { lock.lock(); defer { lock.unlock() }; return mem }
    public func mark() -> Int { totalBytesWritten }

    public func text(since mark: Int) -> (text: String, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        let base = total - mem
        let skip = max(0, mark - base)
        return (ANSI.strip(decode(skipping: skip)), mark < base)
    }

    /// Raw in-memory bytes (escapes kept); `truncated` when older output was evicted.
    public func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (chunks[head...].reduce(into: Data(capacity: mem)) { $0.append($1) }, total > mem)
    }

    public func tail(lines: Int) -> (text: String, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        var s = Substring(ANSI.strip(decode(skipping: 0)))
        if s.last == "\n" { s = s.dropLast() }
        let all = s.split(separator: "\n", omittingEmptySubsequences: false)
        let n = max(0, lines)
        let text = all.suffix(n).joined(separator: "\n")
        return (text, total > mem && all.count <= n)
    }

    private func decode(skipping skip: Int) -> String {
        var bytes = Data(capacity: max(0, mem - skip))
        var left = skip
        for c in chunks[head...] {
            if left >= c.count { left -= c.count; continue }
            bytes.append(c.dropFirst(left))
            left = 0
        }
        return String(decoding: bytes, as: UTF8.self)  // lossy
    }
}
