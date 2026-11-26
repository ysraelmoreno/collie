import Testing
import CollieCore

/// The app's curator and open-panel suites compare texts: run them under `L10n.$override`, whatever the process language.
struct AppCuratorLanguageScope: SuiteTrait, TestTrait, TestScoping {
    var lang: Lang
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$override.withValue(lang) { try await function() }
    }
}
extension Trait where Self == AppCuratorLanguageScope {
    static var appCuratorPT: Self { .init(lang: .pt) }
    static var appCuratorEN: Self { .init(lang: .en) }
}
