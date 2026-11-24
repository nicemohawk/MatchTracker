//
//  LiveMatchStore.swift
//  MatchTracker
//

import Foundation
import Observation
import MatchTrackerKit

/// State container for the live match feed streamed from the watch. ConnectivityManager feeds
/// decoded `LiveMatchUpdate`s in; the Live card/dashboard render from here. A match is considered
/// live until it ends or updates go quiet for `stalenessTimeout`.
@Observable
@MainActor
final class LiveMatchStore {
    static let stalenessTimeout: TimeInterval = 60

    private(set) var latest: LiveMatchUpdate?
    /// The match as a glance sees it: score, clock, on or off.
    private(set) var state: LiveMatchState?
    private(set) var events: [MatchEvent] = []
    private(set) var recentPoints: [TrackPoint] = []
    private(set) var lastReceivedAt: Date?
    /// Set by the final update; the result stays on screen until `endSession`.
    private(set) var hasEnded = false
    /// Sprints so far. Counted as points arrive, so it never goes down.
    private(set) var sprintCount = 0

    @ObservationIgnored private var sprints = LiveSprintCounter()
    @ObservationIgnored private var stalenessTask: Task<Void, Never>?

    var isLive: Bool {
        guard let lastReceivedAt, !hasEnded else { return false }
        return Date().timeIntervalSince(lastReceivedAt) < Self.stalenessTimeout
    }

    func ingest(_ update: LiveMatchUpdate) {
        if let latest {
            if update.startsNewMatch(after: latest) {
                endSession()
            } else if !update.follows(latest) {
                // Out-of-order delivery (userInfo fallback racing sendMessage): keep the newest, but
                // what happened still happened.
                if update.matchID == latest.matchID { take(update) }
                return
            }
        }
        latest = update
        if state == nil { state = LiveMatchState(update) } else { state?.apply(update) }
        // When the watch said it, not when it got here: a queued update can arrive hours late.
        lastReceivedAt = min(update.timestamp, Date())
        take(update)
        if !update.latestPoints.isEmpty {
            for point in update.latestPoints { sprints.add(point) }
            sprintCount = sprints.count
            recentPoints.append(contentsOf: update.latestPoints)
            if recentPoints.count > 300 {
                recentPoints.removeFirst(recentPoints.count - 300)
            }
        }
        scheduleStalenessCheck()
    }

    private func take(_ update: LiveMatchUpdate) {
        if !update.newEvents.isEmpty {
            // By identity: the watch re-sends an event whose kind changed ("that goal was mine").
            let updated = Set(update.newEvents.map(\.id))
            events.removeAll { updated.contains($0.id) }
            events.append(contentsOf: update.newEvents)
            events.sort { $0.date < $1.date }
            hasEnded = events.contains { $0.kind == .matchEnd }
        }
        if let removed = update.removedEventIDs { events.removeAll { removed.contains($0.id) } }
    }

    func endSession() {
        latest = nil
        state = nil
        events = []
        recentPoints = []
        lastReceivedAt = nil
        hasEnded = false
        sprints = LiveSprintCounter()
        sprintCount = 0
        stalenessTask?.cancel()
    }

    /// Re-evaluates `isLive` shortly after the timeout so SwiftUI drops the Live card without
    /// needing a timer while updates flow, and clears a finished match away.
    private func scheduleStalenessCheck() {
        stalenessTask?.cancel()
        stalenessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stalenessTimeout + 1))
            guard !Task.isCancelled, let self else { return }
            if hasEnded {
                endSession()
            } else if !isLive {
                // Touch observable state so views re-read isLive.
                latest = latest
            }
        }
    }
}
