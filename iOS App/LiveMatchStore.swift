//
//  LiveMatchStore.swift
//  MatchTracker
//

import Foundation
import Observation
import MatchTrackerKit

/// State container for the live match feed streamed from the watch. ConnectivityManager feeds
/// decoded `LiveMatchUpdate`s in; the Live card/dashboard render from here. A match is considered
/// live until updates go quiet for `stalenessTimeout`.
@Observable
@MainActor
final class LiveMatchStore {
    static let stalenessTimeout: TimeInterval = 60

    private(set) var latest: LiveMatchUpdate?
    private(set) var events: [MatchEvent] = []
    private(set) var recentPoints: [TrackPoint] = []
    private(set) var lastReceivedAt: Date?

    @ObservationIgnored private var stalenessTask: Task<Void, Never>?

    var isLive: Bool {
        guard let lastReceivedAt else { return false }
        return Date().timeIntervalSince(lastReceivedAt) < Self.stalenessTimeout
    }

    func ingest(_ update: LiveMatchUpdate) {
        // Out-of-order delivery (userInfo fallback racing sendMessage): keep the newest sequence.
        if let latest, update.sequence <= latest.sequence { return }
        latest = update
        lastReceivedAt = Date()
        if !update.newEvents.isEmpty {
            let known = Set(events.map(\.id))
            events.append(contentsOf: update.newEvents.filter { !known.contains($0.id) })
            events.sort { $0.date < $1.date }
        }
        if !update.latestPoints.isEmpty {
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
        stalenessTask?.cancel()
    }

    /// Re-evaluates `isLive` shortly after the timeout so SwiftUI drops the Live card without
    /// needing a timer while updates flow.
    private func scheduleStalenessCheck() {
        stalenessTask?.cancel()
        stalenessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stalenessTimeout + 1))
            guard !Task.isCancelled else { return }
            // Touch observable state so views re-read isLive.
            if let self, !self.isLive {
                self.latest = self.latest
            }
        }
    }
}
