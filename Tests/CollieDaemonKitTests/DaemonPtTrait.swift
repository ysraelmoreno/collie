import Testing
import CollieCore

/// Runs a suite's tests under the Portuguese texts (the daemon speaks the user's language; these suites compare pt).
struct DaemonPt: SuiteTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$override.withValue(.pt) { try await function() }
    }
}
extension Trait where Self == DaemonPt { static var daemonPt: DaemonPt { DaemonPt() } }
