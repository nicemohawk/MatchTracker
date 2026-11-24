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
                // Out-of-order delivery (userInfo fallback racing sendMessage): keep the newest.
                return
            }
        }
        latest = update
        lastReceivedAt = Date()
        if !update.newEvents.isEmpty {
            let known = Set(events.map(\.id))
            events.append(contentsOf: update.newEvents.filter { !known.contains($0.id) })
            events.sort { $0.date < $1.date }
            hasEnded = events.contains { $0.kind == .matchEnd }
        }
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

    func endSession() {
        latest = nil
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
