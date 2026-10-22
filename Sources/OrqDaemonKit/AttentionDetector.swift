import Foundation
import OrqCore

/// Spots "the agent is waiting for you" prompts in a terminal's ANSI-stripped output.
/// Keeps only a short tail between feeds, so memory is bounded and a prompt split across two feeds is still found.
struct AttentionDetector {
    // ponytail: English-only, short list; extend per preset when a real prompt is missed
    private static let generic = ["(y/n)", "[y/n]", "press enter to continue"]
    private static let claude = ["do you trust the files in this folder", "trust this folder"]
    /// Claude Code's tool-permission dialog (checked against 2.1.307's bundle): a line "Do you want to proceed?" /
    /// "… make this edit to x?" / "… create x?" / "… overwrite x?", then within 3 lines the numbered option "1. Yes".
    // ponytail: the dialog's shape, not its whole text; an agent reply quoting such a dialog verbatim would match too
    nonisolated(unsafe) private static let menu = /^[ \t│|]*(do you want to [^\n?]{1,200}\?)[ \t]*\n(?:[^\n]*\n){0,3}?[ \t│|]*(?:❯|>)?[ \t]*1\.[ \t]+yes\b/
        .ignoresCase().anchorsMatchLineEndings()
    private static let menuTail = 1024

    // ponytail: a shell echoing the user's own typed "(y/n)" can false-positive; the post-input quiet window in Fanout mostly hides it
    private let patterns: [String]
    private let isClaude: Bool
    private var tail = ""
    private(set) var lastReason = ""

    init(preset: Preset) {
        isClaude = preset == .claude
        patterns = (isClaude ? Self.claude : []) + Self.generic
    }

    /// The reason (the matched pattern, or Claude's question as printed) when `text` completes a prompt; the buffer is
    /// cleared then, so one prompt fires once.
    mutating func feed(_ text: String) -> String? {
        let buf = tail + text, low = buf.lowercased()
        if let hit = patterns.first(where: low.contains) { tail = ""; lastReason = hit; return hit }
        if isClaude, low.contains("1."), low.contains("do you want to"), let m = buf.firstMatch(of: Self.menu) {
            tail = ""; lastReason = String(m.1); return lastReason
        }
        tail = String(buf.suffix(isClaude ? Self.menuTail : patterns.map(\.count).max()! - 1))
        return nil
    }

    /// How a prompt found for `reason` is answered.
    static func kind(_ reason: String) -> ApprovalKind {
        switch reason {
        case "(y/n)", "[y/n]": .yesNo
        case "press enter to continue": .enter
        case QuietDetector.overflowReason: .unknown
        default: .menu   // the trust dialog and the permission dialogs: numbered options, Enter = "Yes"
        }
    }
}

/// `AttentionDetector` minus input echoes: output within `Fanout.inputQuiet` of an input (its echo, a TUI redraw) is not
/// matched at once but held, and scanned with a fresh detector when the window ends, so a prompt drawn right after an
/// input (the next dialog, once the user answered one) is still found. Only output after the input is held, so the
/// prompt the input answered does not match again; the echo of a written prompt (`input(echo:)`) is taken out first.
/// The owner calls `feed("")` once the window is over (`windowEnd`), and `overflowCheck()` once more `Fanout.inputQuiet`
/// later when `overflowArmed`.
struct QuietDetector {
    static let overflowReason = "saída demais para conferir"
    static let heldCap = 64 * 1024
    private let preset: Preset
    private let now: @Sendable () -> ContinuousClock.Instant
    private var detector: AttentionDetector
    private var lastInput: ContinuousClock.Instant
    private var held: String?   // non-nil: a window is open (or ended and not scanned yet)
    private var overflowed = false
    private var echo: String?
    private(set) var lastReason = ""
    /// The text the window held, set by the `feed` that ended (and scanned) it; nil after any other `feed`.
    private(set) var ended: String?
    /// An overflowed window ended with output stopped and nothing found in what was kept: `overflowCheck` decides.
    private(set) var overflowArmed = false
    /// `now`: tests drive the clock.
    init(preset: Preset, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.preset = preset; self.now = now; detector = AttentionDetector(preset: preset); lastInput = now() - .seconds(60)
    }
    var inWindow: Bool { now() - lastInput < Fanout.inputQuiet }
    /// A window is open, or over but not scanned yet: what the terminal shows is not known.
    var unscanned: Bool { held != nil }
    /// What the open window holds has a line break: the input it follows was answered, not ignored.
    var heldHasNewline: Bool { held?.contains("\n") == true }

    /// `echo`: the text this input wrote (an injected prompt), which the terminal may print back.
    mutating func input(echo: String? = nil) {
        lastInput = now(); detector = AttentionDetector(preset: preset); held = ""; overflowed = false; overflowArmed = false
        self.echo = echo
    }

    /// The reason when a prompt completes; inside the window always nil (the text is held).
    mutating func feed(_ text: String) -> String? {
        ended = nil
        if !text.isEmpty { overflowArmed = false }   // output goes on: a waiting prompt would be in what follows
        guard var h = held else { return hit(detector.feed(text)) }
        h += text
        if inWindow {
            if h.utf8.count > 2 * Self.heldCap { h = String(h.suffix(Self.heldCap)); overflowed = true }
            held = h
            return nil
        }
        held = nil; ended = h
        let found = scanHeld(h)
        // a prompt may hide in what was cut: fail safe, but only once the output stopped (the timer ended the window,
        // `text` is empty) and stays stopped (`overflowCheck`); a build that keeps printing is scanned as it goes
        // (not for a plain shell, where `cat bigfile` right after typing is everyday)
        if found == nil, overflowed, text.isEmpty, preset != .shell { overflowArmed = true }
        return found
    }

    /// `Fanout.inputQuiet` after an armed window end: still no output, so the cut part can't be checked.
    mutating func overflowCheck() -> String? {
        guard overflowArmed else { return nil }
        overflowArmed = false
        return hit(Self.overflowReason)
    }

    private mutating func scanHeld(_ held: String) -> String? {
        var h = held
        guard let echo else { return hit(detector.feed(h)) }
        let raw = h
        for line in echo.split(whereSeparator: \.isNewline) {   // the echo as typed back
            let l = line.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty, let r = h.range(of: l, options: .caseInsensitive) { h.removeSubrange(r) }
        }
        guard let why = detector.feed(h) else { return nil }
        // an echo the terminal wrapped or decorated: a match the prompt itself accounts for is not a prompt
        // ponytail: ceiling — a program that does not echo and then asks with the prompt's own reason (prompt has
        // "(y/n)", program prints "(y/n)") is taken for the echo inside the window; the hub's badge misses it too
        func count(_ s: String) -> Int { s.lowercased().components(separatedBy: why.lowercased()).count - 1 }
        return count(echo) >= count(raw) ? nil : hit(why)
    }

    private mutating func hit(_ why: String?) -> String? {
        if let why { lastReason = why }
        return why
    }

    /// When the window ends: the owner schedules `feed("")` then (a dialog drawn inside it may print nothing more).
    static var windowEnd: DispatchTime { .now() + quietSeconds + 0.02 }
    /// When an armed overflow is checked.
    static var overflowEnd: DispatchTime { .now() + quietSeconds }
    private static var quietSeconds: Double {
        let q = Fanout.inputQuiet.components
        return Double(q.seconds) + Double(q.attoseconds) / 1e18
    }
}
