import Foundation
import SwiftTerm

/// A terminal's output replayed into a headless emulator of its size: the screen as it is drawn now.
public enum ScreenRenderer {
    /// Rows right-trimmed, trailing blank rows dropped.
    public static func render(_ data: Data, cols: Int, rows: Int) -> String {
        let sink = Sink()
        let t = Terminal(delegate: sink, options: TerminalOptions(cols: max(cols, 2), rows: max(rows, 1), scrollback: 0))
        // ponytail: replays the whole in-memory tail (≤ 1 MiB) on every call; a live mirror per terminal if this gets hot
        t.feed(byteArray: [UInt8](data))
        var lines = (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Replies the emulator would send back (device attributes, cursor reports) go nowhere: the real terminal answered them.
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
}
