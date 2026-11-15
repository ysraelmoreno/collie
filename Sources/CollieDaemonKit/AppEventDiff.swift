import CollieProtocol

/// app adopt (spec 2026-11-15): a stream that sends its whole document on each change (`eventDiff`) becomes one event
/// per new item of the array at `key`. One per connection: a reconnect starts a new baseline.
struct AppEventDiff {
    let key: String
    private var base: [JSONValue]?
    static let cap = 100

    init(key: String) { self.key = key }

    /// The items of `doc[key]` not seen in the previous document; the first call only sets the baseline. The base's
    /// last item found again (right to left): what follows it. Not found (log cleared or rotated): the new array is the
    /// base, its items new only if it is not shorter than the old one. Missing or not an array: nothing, base kept.
    /// At most `cap`, the newest.
    // ponytail: identity is deep equality of the last item; two identical items in a row look like one
    mutating func newItems(in doc: JSONValue) -> [JSONValue] {
        guard case .object(let o) = doc, case .array(let now)? = o[key] else { return [] }
        defer { base = now }
        guard let old = base else { return [] }
        let fresh: ArraySlice<JSONValue>
        if let last = old.last, let i = now.lastIndex(of: last) {
            fresh = now[(i + 1)...]
        } else {
            fresh = now.count >= old.count ? now[...] : []
        }
        return Array(fresh.suffix(Self.cap))
    }
}
