import Foundation

/// Reserved `call` targets on `ui.host` that are the app itself, not a panel.
public enum HostTarget {
    /// The HTML importer (`html.snapshot`).
    public static let importer = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
}
