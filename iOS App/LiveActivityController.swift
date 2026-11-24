// LiveActivityController.swift
// MatchTracker

import ActivityKit
import Foundation
import HealthKit
import MatchTrackerKit

/// Keeps one Live Activity in step with the match on the watch.
///
/// **Starting.** ActivityKit only lets an app start one in the foreground, with one exception: when
/// the watch mirrors its workout session, HealthKit launches this app in the background and grants a
/// single start. So it begins either from `observeMirroredMatches()` with the phone locked in a bag,
/// or, if mirroring didn't get through, the first time the app is opened during the match.
///
/// **Updating** needs neither: each message from the watch wakes the app long enough. Nothing is
/// pushed from a server, so with the phone out of range the activity goes stale and says so.
///
/// **Ending** happens on the watch's last message, or on the finished record's arrival when that
/// message was lost, or — if neither came — the next time the app opens.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    typealias MatchActivity = Activity<MatchActivityAttributes>

    private static let metricsInterval: TimeInterval = 15
    private static let staleInterval: TimeInterval = 150
    /// With no word for this long the match is over, whatever the activity says.
    private static let abandonedInterval: TimeInterval = 45 * 60
    private static let summaryInterval: TimeInterval = 2 * 3600

    private var activity: MatchActivity?
    private var latest: LiveMatchState?
    private var lastSent: (state: LiveMatchState, date: Date)?
    /// Content changes are awaited one at a time, or a slow update could land after the end.
    private var queue: Task<Void, Never>?
    private var dismissalWatch: Task<Void, Never>?
    private var reportedStartFailure = false
    /// Mirroring stops if nobody holds the session.
    private var mirroredSession: HKWorkoutSession?
    private let healthStore = HKHealthStore()

    // MARK: Hooks

    /// Call before launch finishes: a mirrored session launches the app and then looks for this.
    func observeMirroredMatches() {
        healthStore.workoutSessionMirroringStartHandler = { session in
            Task { @MainActor in
                let controller = LiveActivityController.shared
                controller.mirroredSession = session
                let start = session.startDate ?? Date()
                MatchLog.info("mirrored match session began", category: "live")
                // The background grant is for this moment, so start on what's known: it has begun.
                controller.show(controller.latest ?? LiveMatchState(startDate: start))
            }
        }
    }

    /// Each update from the watch, after `LiveMatchStore` has taken it in.
    func show(_ state: LiveMatchState?) {
        guard let state else { return }
        latest = state
        adoptRunningActivity()
        if state.hasEnded {
            finish(with: state)
        } else if activity != nil {
            send(state)
        } else if Date().timeIntervalSince(state.updatedAt) < Self.staleInterval {
            start(state)
        }
    }

    func appBecameActive() {
        adoptRunningActivity()
        endAbandoned()
        reportedStartFailure = false
        if let latest, activity == nil, !latest.hasEnded { show(latest) }
    }

    /// The finished record: the last word on the score, and proof the match is over.
    func matchFinished(_ record: MatchRecord) {
        adoptRunningActivity()
        guard let activity,
              abs(activity.attributes.startDate.timeIntervalSince(record.startDate)) < 180
                || record.startDate...(record.endDate ?? Date()) ~= activity.attributes.startDate else { return }
        var state = latest ?? activity.content.state
        let end = record.endDate ?? state.updatedAt
        let us = record.events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = record.events.filter { $0.kind == .goalAgainstUs }.count
        if us + them > 0 {
            state.goalsUs = us
            state.goalsThem = them
        }
        if end > state.updatedAt, state.isClockRunning {
            state.elapsed += end.timeIntervalSince(state.updatedAt)
        }
        state.updatedAt = end
        state.hasEnded = true
        latest = state
        finish(with: state)
    }

    // MARK: Lifecycle

    private func start(_ state: LiveMatchState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, state.startDate > suppressedUntil else { return }
        do {
            let started = try MatchActivity.request(
                attributes: MatchActivityAttributes(startDate: state.startDate, units: .current),
                content: content(state), pushType: nil)
            MatchLog.info("live activity started", category: "live")
            follow(started)
            lastSent = (state, Date())
        } catch {
            // Expected in the background without a mirrored session; the next open tries again.
            guard !reportedStartFailure else { return }
            reportedStartFailure = true
            MatchLog.info("live activity not started: \(error.localizedDescription)", category: "live")
        }
    }

    private func send(_ state: LiveMatchState) {
        guard let activity else { return }
        if let lastSent, !state.isNews(since: lastSent.state),
           Date().timeIntervalSince(lastSent.date) < Self.metricsInterval { return }
        lastSent = (state, Date())
        let content = content(state)
        enqueue { await activity.update(content) }
    }

    private func finish(with state: LiveMatchState) {
        suppressedUntil = Date()
        mirroredSession = nil
        guard let activity else { return }
        stopFollowing()
        let content = ActivityContent(state: state, staleDate: nil)
        enqueue {
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(Self.summaryInterval)))
        }
        MatchLog.info("live activity ended", category: "live")
    }

    /// The app may have been relaunched mid-match; the activity outlives it.
    private func adoptRunningActivity() {
        guard activity == nil else { return }
        if let running = MatchActivity.activities.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            follow(running)
        }
    }

    private func endAbandoned() {
        guard let activity else { return }
        let lastHeard = max(activity.content.state.updatedAt, latest?.updatedAt ?? .distantPast)
        guard Date().timeIntervalSince(lastHeard) > Self.abandonedInterval else { return }
        stopFollowing()
        // How it ended isn't known, so there's no result to leave behind.
        enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func follow(_ activity: MatchActivity) {
        self.activity = activity
        dismissalWatch = Task { [weak self] in
            for await change in activity.activityStateUpdates where change == .dismissed {
                // Swiped away: not again for this match.
                self?.suppressedUntil = Date()
                self?.stopFollowing()
                return
            }
        }
    }

    private func stopFollowing() {
        dismissalWatch?.cancel()
        dismissalWatch = nil
        activity = nil
        lastSent = nil
    }

    private func content(_ state: LiveMatchState) -> ActivityContent<LiveMatchState> {
        ActivityContent(state: state, staleDate: state.updatedAt.addingTimeInterval(Self.staleInterval),
                        relevanceScore: 100)
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await operation()
        }
    }

    /// A match that kicked off before this moment has had its activity already.
    private var suppressedUntil: Date {
        get { AppGroup.defaults.object(forKey: "liveActivitySuppressedUntil") as? Date ?? .distantPast }
        set { AppGroup.defaults.set(newValue, forKey: "liveActivitySuppressedUntil") }
    }
}
