public enum ANSI {
    /// Removes CSI, OSC, simple ESC sequences and carriage returns.
    public static func strip(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            switch c.value {
            case 0x0D: continue
            case 0x1B:
                guard let n = it.next() else { return String(out) }
                if n == "[" {  // CSI: until final byte 0x40...0x7E
                    while let x = it.next(), !(0x40...0x7E).contains(x.value) {}
                } else if n == "]" {  // OSC: until BEL or ESC \
                    var prevEsc = false
                    while let x = it.next() {
                        if x.value == 0x07 || (prevEsc && x == "\\") { break }
                        prevEsc = x.value == 0x1B
                    }
                } else if (0x20...0x2F).contains(n.value) {  // ESC + intermediates + final
                    while let x = it.next(), !(0x30...0x7E).contains(x.value) {}
                }  // else: two-byte ESC sequence, already consumed
            default: out.append(c)
            }
        }
        return String(out)
    }
}
