//
//  LiveStreamer.swift
//  MatchTracker
//

import Foundation
import WatchConnectivity
import MatchTrackerKit

/// Streams `LiveMatchUpdate` deltas to the phone (~5 s cadence) during an active session so the
/// sideline can watch live. Uses `sendMessage` when the phone is reachable; falls back to a
/// sparse (~30 s) `transferUserInfo` so updates still arrive after a reconnect.
final class LiveStreamer {
    static let messageKey = "liveUpdate"

    private var streamTask: Task<Void, Never>?
    private var sequence = 0
    private var sentTrackCount = 0
    private var sentEventCount = 0
    private var lastUserInfoSend = Date.distantPast

    private let sendInterval: TimeInterval = 5
    private let userInfoInterval: TimeInterval = 30

    /// Starts the send loop. The closure snapshots current match state on the main actor.
    func start(snapshot: @escaping @MainActor () -> LiveMatchUpdate?) {
        stop()
        sequence = 0
        sentTrackCount = 0
        sentEventCount = 0
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendOnce(snapshot: snapshot)
                try? await Task.sleep(for: .seconds(self?.sendInterval ?? 5))
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Builds the delta ranges for the caller: points/events not yet streamed.
    @MainActor
    func deltas(track: [TrackPoint], events: [MatchEvent]) -> (points: [TrackPoint], events: [MatchEvent]) {
        let newPoints = Array(track.suffix(from: min(sentTrackCount, track.count)).suffix(10))
        let newEvents = Array(events.suffix(from: min(sentEventCount, events.count)))
        sentTrackCount = track.count
        sentEventCount = events.count
        return (newPoints, newEvents)
    }

    @MainActor
    var nextSequence: Int {
        sequence += 1
        return sequence
    }

    /// One guaranteed final update (e.g. carrying matchEnd) before the streamer stops; forces the
    /// userInfo fallback so it survives an unreachable phone.
    func sendFinalUpdate(snapshot: @escaping @MainActor () -> LiveMatchUpdate?) async {
        await sendOnce(snapshot: snapshot, forceFallback: true)
    }

    private func sendOnce(snapshot: @escaping @MainActor () -> LiveMatchUpdate?,
                          forceFallback: Bool = false) async {
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        // Decide whether this tick can transmit at all BEFORE snapshotting: building the update
        // consumes track/event deltas, and a consumed-but-dropped delta never reaches the phone.
        let reachable = session.isReachable
        let userInfoDue = forceFallback || Date().timeIntervalSince(lastUserInfoSend) >= userInfoInterval
        guard reachable || userInfoDue else { return }

        guard let update = await MainActor.run(body: snapshot) else { return }
        guard let data = try? MatchTrackerJSON.encoder().encode(update) else { return }

        if reachable {
            session.sendMessage([Self.messageKey: data], replyHandler: nil) { error in
                MatchLog.error("Live update send failed: \(error.localizedDescription)", category: "live")
            }
        } else {
            lastUserInfoSend = Date()
            session.transferUserInfo([Self.messageKey: data])
        }
    }
}
