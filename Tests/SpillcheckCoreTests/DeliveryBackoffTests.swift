import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor Delivery {
    private(set) var attempts: [Date] = []
    private(set) var gaps: [CoverageGap] = []
    var failing = true
    /// The date of the pass in progress, for calls that carry none, such as the authority lookup.
    private var clock = start
    /// When set, the first attempt waits for cancellation before failing, as a store call can.
    var holdFirstAttempt = false
    func tick(_ date: Date) { clock = date }
    func attempt(at date: Date) async throws {
        attempts.append(date)
        if holdFirstAttempt, attempts.count == 1 { try? await Task.sleep(for: .seconds(60)) }
        if failing { throw StorageError.monitoringPaused }
    }
    func lookupAttempt() async throws { try await attempt(at: clock) }
    func fail() { failing = true }
    func gap(_ gap: CoverageGap) { gaps.append(gap) }
    func recover() { failing = false }
    func holdFirst() { holdFirstAttempt = true }
    var deliveryGaps: [Date] { gaps.filter { $0.reason == .deliveryUncertain }.compactMap(\.observedAt) }
}

private let start = Date(timeIntervalSince1970: 1_791_676_800)

/// Polls every `step` seconds for `span` seconds, as the monitors' loops do.
private func drive(_ span: TimeInterval, step: TimeInterval, from first: Date,
                   poll: (Date) async throws -> Void) async -> Date {
    var now = first
    while now < first.addingTimeInterval(span) {
        try? await poll(now)
        now = now.addingTimeInterval(step)
    }
    return now
}

@Suite struct DeliveryBackoffTests {
    @Test func delayDoublesFromTheCadenceAndIsCapped() {
        let delays = (1...9).map { DeliveryBackoff.delay(base: 0.25, failures: $0) }
        #expect(delays == [0.25, 0.5, 1, 2, 4, 8, 16, 30, 30])
        #expect(DeliveryBackoff.delay(base: 1, failures: 100) == 30)
        // A source slower than the cap keeps its own cadence.
        #expect(DeliveryBackoff.delay(base: 60, failures: 5) == 60)
    }

    @Test func claudeSourceThatKeepsFailingIsRetriedWithBackoffAndRecordsFewGaps() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-backoff-\(UUID()).jsonl")
        try Data("{}\n".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let delivery = Delivery()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test",
            sources: [.init(sessionID: "s", transcriptURL: file)],
            enqueue: { _, date in try await delivery.attempt(at: date) }, onGap: { await delivery.gap($0) })
        // Four passes a second for two minutes.
        var now = await drive(120, step: 0.25, from: start) { _ = try await monitor.pollOnce(at: $0) }
        let attempts = await delivery.attempts
        #expect(attempts.count <= 12, "attempts: \(attempts.count)")
        let gaps = await delivery.deliveryGaps
        #expect(gaps == [start])
        // The gap between retries grows, up to the cap.
        let intervals = zip(attempts, attempts.dropFirst()).map { $1.timeIntervalSince($0) }
        #expect(intervals == intervals.sorted() && intervals.max() == 30)
        // Still failing after five minutes: one more gap.
        now = await drive(240, step: 0.25, from: now) { _ = try await monitor.pollOnce(at: $0) }
        let later = await delivery.deliveryGaps
        #expect(later.count == 2 && later[1].timeIntervalSince(start) >= 300 && later[1].timeIntervalSince(start) < 331)
        // Once the cause clears, the next retry delivers and later changes are polled at once.
        await delivery.recover()
        now = await drive(31, step: 0.25, from: now) { _ = try await monitor.pollOnce(at: $0) }
        let before = await delivery.attempts.count
        #expect(try await monitor.pollOnce(at: now) == 0)
        try Data("{}\n{}\n".utf8).write(to: file)
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(0.25)) == 1)
        #expect(await delivery.attempts.count == before + 1)
        #expect(await delivery.deliveryGaps.count == 2)
        // A later outage starts afresh: its gap is recorded at once and its first retry is quick.
        await delivery.fail()
        let relapse = now.addingTimeInterval(1)
        try Data("{}\n{}\n{}\n".utf8).write(to: file)
        _ = try? await monitor.pollOnce(at: relapse)
        #expect(await delivery.deliveryGaps.last == relapse)
        _ = try? await monitor.pollOnce(at: relapse.addingTimeInterval(0.25))
        #expect(await delivery.attempts.suffix(2) == [relapse, relapse.addingTimeInterval(0.25)])
    }

    @Test(arguments: [true, false]) func codexSourceThatKeepsFailingIsRetriedWithBackoffAndRecordsFewGaps(transcript: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-backoff-\(UUID()).jsonl")
        try Data("{}\n".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let delivery = Delivery()
        let source = try CodexActiveSource(threadID: "thread", interface: .t3,
            authority: transcript ? .nativeRolloutTranscript : .publicNativeItems, transcriptURL: transcript ? file : nil)
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [source],
            enqueue: { _, date in try await delivery.attempt(at: date) }, onGap: { await delivery.gap($0) })
        try await monitor.addSource(source, at: start)
        var now = await drive(120, step: 1, from: start) { _ = try await monitor.pollOnce(at: $0) }
        let attempts = await delivery.attempts
        #expect(attempts.count <= 10, "attempts: \(attempts.count)")
        #expect(await delivery.deliveryGaps == [start])
        let intervals = zip(attempts, attempts.dropFirst()).map { $1.timeIntervalSince($0) }
        #expect(intervals == intervals.sorted() && intervals.max() == 30)
        now = await drive(240, step: 1, from: now) { _ = try await monitor.pollOnce(at: $0) }
        let later = await delivery.deliveryGaps
        #expect(later.count == 2 && later[1].timeIntervalSince(start) >= 300 && later[1].timeIntervalSince(start) < 331)
        await delivery.recover()
        now = await drive(31, step: 1, from: now) { _ = try await monitor.pollOnce(at: $0) }
        let before = await delivery.attempts.count
        #expect(before > attempts.count)
        if transcript {
            #expect(try await monitor.pollOnce(at: now) == 0)
            #expect(await delivery.attempts.count == before)
        }
        #expect(await delivery.deliveryGaps.count == 2)
        if transcript {
            await delivery.fail()
            let relapse = now.addingTimeInterval(1)
            try Data("{}\n{}\n".utf8).write(to: file)
            _ = try? await monitor.pollOnce(at: relapse)
            #expect(await delivery.deliveryGaps.last == relapse)
            _ = try? await monitor.pollOnce(at: relapse.addingTimeInterval(1))
            #expect(await delivery.attempts.suffix(2) == [relapse, relapse.addingTimeInterval(1)])
        }
    }

    @Test func aSourceWhoseAuthorityLookupKeepsFailingIsRetriedWithBackoffAndRecordsFewGaps() async throws {
        let delivery = Delivery()
        let source = try CodexActiveSource(threadID: "thread", interface: .t3, authority: .publicNativeItems)
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [source],
            enqueue: { _, _ in }, authorityLookup: { _ in try await delivery.lookupAttempt(); return nil },
            onGap: { await delivery.gap($0) })
        let poll: (Date) async throws -> Void = { date in
            await delivery.tick(date)
            _ = try await monitor.pollOnce(at: date)
        }
        var now = await drive(120, step: 1, from: start, poll: poll)
        let attempts = await delivery.attempts
        #expect(attempts.count <= 10, "lookups: \(attempts.count)")
        #expect(await delivery.deliveryGaps == [start])
        let intervals = zip(attempts, attempts.dropFirst()).map { $1.timeIntervalSince($0) }
        #expect(intervals == intervals.sorted() && intervals.max() == 30)
        now = await drive(240, step: 1, from: now, poll: poll)
        let later = await delivery.deliveryGaps
        #expect(later.count == 2 && later[1].timeIntervalSince(start) >= 300 && later[1].timeIntervalSince(start) < 331)
        // Once the lookup works again the source is polled normally, and a relapse starts afresh.
        await delivery.recover()
        now = await drive(31, step: 1, from: now, poll: poll)
        #expect(await delivery.deliveryGaps.count == 2)
        await delivery.fail()
        let relapse = now.addingTimeInterval(1)
        try? await poll(relapse)
        #expect(await delivery.deliveryGaps.last == relapse)
        try? await poll(relapse.addingTimeInterval(1))
        #expect(await delivery.attempts.suffix(2) == [relapse, relapse.addingTimeInterval(1)])
    }

    @Test func claudeCancelledEnqueueIsNotAFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-backoff-\(UUID()).jsonl")
        try Data("{}\n".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let delivery = Delivery()
        await delivery.holdFirst()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test",
            sources: [.init(sessionID: "s", transcriptURL: file)],
            enqueue: { _, date in try await delivery.attempt(at: date) }, onGap: { await delivery.gap($0) })
        let pass = Task { try await monitor.pollOnce(at: start) }
        while await delivery.attempts.isEmpty { await Task.yield() }
        pass.cancel()
        _ = try? await pass.value
        #expect(await delivery.gaps.isEmpty)
        // No backoff was entered: the next pass at the same time tries the source again.
        _ = try? await monitor.pollOnce(at: start)
        #expect(await delivery.attempts == [start, start])
        #expect(await delivery.deliveryGaps == [start])
    }

    @Test(arguments: [false, true]) func codexCancelledCallIsNotAFailure(inLookup: Bool) async throws {
        let delivery = Delivery()
        await delivery.holdFirst()
        let source = try CodexActiveSource(threadID: "thread", interface: .t3, authority: .publicNativeItems)
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [source],
            enqueue: { _, date in if !inLookup { try await delivery.attempt(at: date) } },
            authorityLookup: { _ in if inLookup { try await delivery.lookupAttempt() }; return nil },
            onGap: { await delivery.gap($0) })
        let pass = Task { try await monitor.pollOnce(at: start) }
        while await delivery.attempts.isEmpty { await Task.yield() }
        pass.cancel()
        _ = try? await pass.value
        #expect(await delivery.gaps.isEmpty)
        _ = try? await monitor.pollOnce(at: start)
        #expect(await delivery.attempts == [start, start])
        #expect(await delivery.deliveryGaps == [start])
    }

    @Test func aSuccessResetsASourceSoItsNextOutageStartsAfresh() {
        var backoff = DeliveryBackoff()
        let first = backoff.recordFailure("a", base: 1, at: start)
        let second = backoff.recordFailure("a", base: 1, at: start.addingTimeInterval(1))
        #expect(first && !second)
        #expect(backoff.isWaiting("a", at: start.addingTimeInterval(2)))
        backoff.recordSuccess("a")
        #expect(!backoff.isWaiting("a", at: start.addingTimeInterval(2)))
        // Within the gap interval of the earlier outage's gap, and at the base delay again.
        let again = backoff.recordFailure("a", base: 1, at: start.addingTimeInterval(3))
        #expect(again)
        #expect(backoff.isWaiting("a", at: start.addingTimeInterval(3.5)))
        #expect(!backoff.isWaiting("a", at: start.addingTimeInterval(4)))
    }
}
