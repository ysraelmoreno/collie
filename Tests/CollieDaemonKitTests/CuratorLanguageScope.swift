import Testing
import CollieCore

/// Runs a test (or every test of a suite) under `L10n.$override`, whatever the process language: the curator suites compare
/// the daemon's texts, in Portuguese; `CuratorEnglishTests` runs under `.en`. Tasks the test starts inherit it.
struct CuratorLanguageScope: SuiteTrait, TestTrait, TestScoping {
    var lang: Lang
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$override.withValue(lang) { try await function() }
    }
}
extension Trait where Self == CuratorLanguageScope {
    static var curatorPT: Self { .init(lang: .pt) }
    static var curatorEN: Self { .init(lang: .en) }
}
