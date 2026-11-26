import Testing
import CollieCore

/// The suites compare texts: run them under `L10n.$override`, whatever the process language.
struct ThemePTScope: SuiteTrait, TestTrait, TestScoping {
    var lang: Lang
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$override.withValue(lang) { try await function() }
    }
}
extension Trait where Self == ThemePTScope {
    static var themePT: Self { .init(lang: .pt) }
    static var themeEN: Self { .init(lang: .en) }
}
