import CollieProtocol

public extension RestartHint {
    /// The hint in the active language (CollieProtocol can't see `tr`).
    static var localized: String { tr(text, textEn) }
}
