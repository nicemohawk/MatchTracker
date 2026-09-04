//
//  MainThreadWatchdog.swift
//  MatchTracker
//

import Foundation
import MatchTrackerKit

/// Journals stretches where the main thread stops answering.
///
/// A frozen watch UI — a countdown stuck on its last numeral, a control that buzzes and then
/// never redraws — is indistinguishable from a logic bug when all you have is the symptom, and
/// the journal couldn't tell the two apart either. This pings the main queue once a second and
/// records any round trip slower than `stallThreshold`, so an export says plainly whether the
/// app stopped rendering, when, and for how long.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "com.matchtracker.watch.mainThreadWatchdog", qos: .utility)
    private let stallThreshold: TimeInterval = 2
    private var timer: DispatchSourceTimer?
    /// Queue-confined: only one ping is outstanding at a time, so a long stall is reported once
    /// rather than by every ping that piled up behind it.
    private var pingInFlight = false

    private init() {}

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            source.setEventHandler { [self] in ping() }
            source.resume()
            timer = source
        }
    }

    private func ping() {
        guard !pingInFlight else { return }
        pingInFlight = true
        let sent = Date()
        DispatchQueue.main.async { [self] in
            let latency = Date().timeIntervalSince(sent)
            queue.async { [self] in
                pingInFlight = false
                guard latency >= stallThreshold else { return }
                MatchLog.error("main thread stalled \(String(format: "%.1f", latency))s", category: "watchdog")
            }
        }
    }
}
