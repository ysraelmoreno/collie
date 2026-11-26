import Foundation

/// Polls `cond` until it holds (true) or `seconds` pass (false).
@MainActor func pollUntil(_ seconds: Double = 5, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return await cond()
}

import CollieCore
import Testing

/// Suites whose assertions compare Portuguese texts run under `.pt` (the daemon language is per task).
struct PortugueseScope: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$override.withValue(.pt) { try await function() }
    }
}
extension Trait where Self == PortugueseScope { static var pt: PortugueseScope { .init() } }
