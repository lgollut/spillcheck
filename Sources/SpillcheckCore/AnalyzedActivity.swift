import Foundation

/// Days and volume of content that was actually analyzed. A day without analyzed content is not
/// evidence that nothing happened, and analyzed days do not prove continuous coverage.
public struct AnalyzedActivity: Sendable {
    public let window: DateInterval
    public let messageCount: Int
    public let conversationCount: Int
    private let days: [SessionProfile: Set<Date>]
    private let conversations: [SessionProfile: Int]

    private struct SessionProfile: Hashable, Sendable {
        let provider: AgentProvider
        let profileID: String?
    }

    public init(snapshot: InventorySnapshot, window: DateInterval, calendar: Calendar = .current) {
        self.window = window
        var days: [SessionProfile: Set<Date>] = [:]
        var sessions: [SessionProfile: Set<SessionIdentity>] = [:]
        var messages = 0
        for (source, time) in snapshot.sourceTimes where window.contains(time) {
            messages += 1
            let session = source.session
            let day = calendar.startOfDay(for: time)
            for key in [SessionProfile(provider: session.provider, profileID: session.profileID),
                        SessionProfile(provider: session.provider, profileID: nil)] {
                days[key, default: []].insert(day)
                sessions[key, default: []].insert(session)
            }
        }
        self.days = days
        self.conversations = sessions.mapValues(\.count)
        messageCount = messages
        conversationCount = Set(sessions.filter { $0.key.profileID == nil }.values.flatMap { $0 }).count
    }

    /// Start-of-day dates with analyzed content. A nil profile includes every profile of the provider.
    public func analyzedDays(provider: AgentProvider, profileID: String? = nil) -> Set<Date> {
        days[SessionProfile(provider: provider, profileID: profileID)] ?? []
    }

    public func conversationCount(provider: AgentProvider, profileID: String? = nil) -> Int {
        conversations[SessionProfile(provider: provider, profileID: profileID)] ?? 0
    }

    /// The seven calendar days ending today, matching recent-history catch-up.
    public static func recentWindow(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        return DateInterval(start: start, end: max(start, now))
    }
}
