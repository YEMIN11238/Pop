import Foundation

/// All windows and installed-model sessions share one clock. Waiting callers do
/// not reserve future slots, so cancelling or invalidating a job cannot leave an
/// artificial delay behind it. A slot records the beginning of actual work.
actor SystemTranslationCooldown {
    static let shared = SystemTranslationCooldown()
    private let clock = ContinuousClock()
    private var lastStarted: ContinuousClock.Instant?
    private var lastSpacing: Duration = .zero

    func wait(seconds: Double, whileCurrent isCurrent: @escaping @Sendable () async -> Bool = { true }) async throws {
        guard seconds.isFinite, (0...3600).contains(seconds) else {
            throw PopError.message("系统翻译冷却时间须在 0–3600 秒之间。")
        }
        let spacing = Duration.seconds(seconds)
        while true {
            try Task.checkCancellation()
            if let deadline = deadline(spacing: spacing), clock.now < deadline {
                try await clock.sleep(until: deadline)
                continue
            }
            guard await isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
            // Calling back to MainActor is an await point. Another window may
            // have started while this caller checked its generation; recheck.
            let now = clock.now
            if let deadline = deadline(spacing: spacing), now < deadline { continue }
            lastStarted = now
            lastSpacing = spacing
            return
        }
    }

    private func deadline(spacing: Duration) -> ContinuousClock.Instant? {
        lastStarted.map { $0.advanced(by: max(lastSpacing, spacing)) }
    }

    fileprivate func startSnapshot() -> ContinuousClock.Instant? { lastStarted }
}

/// Real async scheduling against an isolated gate; no translations or user data.
enum SystemTranslationCooldownSelfCheck {
    static func run() async throws -> [String] {
        let gate = SystemTranslationCooldown()
        try await gate.wait(seconds: 0.06)
        guard let first = await gate.startSnapshot() else { throw PopError.message("冷却自检：首个请求未启动。") }
        let second = Task { try await gate.wait(seconds: 0.06) }
        let third = Task { try await gate.wait(seconds: 0.06) }
        try await second.value
        try await third.value
        guard let last = await gate.startSnapshot(), first.duration(to: last) >= .milliseconds(115) else {
            throw PopError.message("冷却自检：并发调用没有遵守共享间隔。")
        }

        let cancellationGate = SystemTranslationCooldown()
        try await cancellationGate.wait(seconds: 0.2)
        let previous = await cancellationGate.startSnapshot()
        let pending = Task { try await cancellationGate.wait(seconds: 0.2) }
        try await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        do { try await pending.value; throw PopError.message("冷却自检：等待任务取消未传播。") }
        catch is CancellationError { }
        guard await cancellationGate.startSnapshot() == previous else { throw PopError.message("冷却自检：取消的请求占用了时间槽。") }

        let staleGate = SystemTranslationCooldown()
        do {
            try await staleGate.wait(seconds: 0, whileCurrent: { false })
            throw PopError.message("冷却自检：过期请求被放行。")
        } catch is CancellationError { }
        guard await staleGate.startSnapshot() == nil else { throw PopError.message("冷却自检：过期请求占用了时间槽。") }
        return ["系统翻译冷却：真实并发任务按共享时钟间隔启动，跨调用不同时放行。", "系统翻译冷却：等待取消及过期generation拒绝，不预占后续时间槽（未调用真实翻译）。"]
    }
}
