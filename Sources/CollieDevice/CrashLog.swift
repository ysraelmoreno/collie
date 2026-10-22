import Foundation

public struct CrashEvent: Equatable, Sendable { public var package: String?; public var text: String }

/// Groups `adb logcat` lines into crash events (Java FATAL EXCEPTION blocks and native "Fatal signal" lines).
public struct CrashLog: Sendable {
    private var lines: [String] = []
    private var package: String?
    private var size = 0
    private var open = false
    public init() {}

    public mutating func feed(line: String) -> [CrashEvent] {
        var out: [CrashEvent] = []
        if line.contains("FATAL EXCEPTION") {
            out += flush()
            open = true
        } else if open && !line.contains("AndroidRuntime") {
            out += flush()  // the block ended
        }
        if open {
            if package == nil, let m = line.firstMatch(of: /Process: ([^,\s]+)/) { package = String(m.1) }
            if size + line.utf8.count < 4096 { lines.append(line); size += line.utf8.count + 1 }  // ponytail: drops overflow lines, keeps head
        } else if line.contains("Fatal signal") {
            out.append(CrashEvent(package: line.firstMatch(of: /pid \d+ \(([^)]+)\)/).map { String($0.1) }, text: String(line.prefix(4096))))
        }
        return out
    }

    public mutating func flush() -> [CrashEvent] {
        defer { lines = []; package = nil; size = 0; open = false }
        return open ? [CrashEvent(package: package, text: lines.joined(separator: "\n"))] : []
    }
}
