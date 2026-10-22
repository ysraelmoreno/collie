import Foundation

/// Polls `cond` until it holds (true) or `seconds` pass (false).
@MainActor func pollUntil(_ seconds: Double = 5, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return await cond()
}
