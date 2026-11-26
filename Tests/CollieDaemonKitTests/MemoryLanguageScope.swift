import Testing
import CollieCore

/// Runs a suite under `L10n.$override`: the memory/orientation/hook suites compare the daemon's texts in Portuguese;
/// `MemoryEnglishTests` runs under `.en`. Tasks a test starts inherit it.
struct MemoryLanguageScope: SuiteTrait, TestTrait, TestScoping {
    var lang: Lang
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$override.withValue(lang) { try await function() }
    }
}
extension Trait where Self == MemoryLanguageScope {
    static var memoryPT: Self { .init(lang: .pt) }
    static var memoryEN: Self { .init(lang: .en) }
}
