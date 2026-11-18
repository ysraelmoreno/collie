import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct BoundedProcessTimeoutTests {
    /// A leader that dies on the timeout's SIGTERM signals its exit once: the wait after the grace period must not wait
    /// for it a second time (it hung forever: a work loop's check past its timeout never came back).
    @Test func timeoutReturnsWhenTheLeaderDiesOnSigterm() async throws {
        final class Box: @unchecked Sendable { let lock = NSLock(); var result: Bool? }
        let box = Box()
        Task.detached {   // unstructured: a hung run must not hang the test
            var ok = false
            do {
                _ = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", "sleep 1.2; false"],
                                                 in: URL(fileURLWithPath: "/tmp"), env: [:], timeout: .seconds(1))
            } catch { ok = (error as? ProtocolError)?.code == .timeout }
            box.lock.withLock { box.result = ok }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, box.lock.withLock({ box.result }) == nil { try await Task.sleep(for: .milliseconds(50)) }
        let done = box.lock.withLock { box.result } ?? false
        #expect(done, "BoundedProcess did not return a timeout within 10 s")
    }
}
