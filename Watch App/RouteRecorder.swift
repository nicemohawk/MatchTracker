//
//  RouteRecorder.swift
//  MatchTracker
//

import CoreLocation
import Foundation
import MatchTrackerKit
import WatchKit

/// Owns GPS for a match, from warm-up on the start screen to the last fix.
///
/// The rules, each learned from a real match that lost its route:
/// - Updates start while the app is in use. Under When In Use authorization, Core Location only
///   continues in the background for updates that began in the foreground, so waiting for kickoff
///   (the wrist is usually down by then) is too late. `warmUp()` runs on the start screen and
///   `arm()` runs inside the Start tap.
/// - Every accepted fix is on disk before anything else uses it, so a relaunch resumes the route
///   instead of restarting it.
/// - Silence is never final: a watchdog keeps asking for the length of the match.
///
/// Main queue only, like the rest of the live session state.
@Observable
final class RouteRecorder: NSObject {
    enum Signal: Equatable { case off, acquiring, good, lost, denied, imprecise }

    private(set) var signal: Signal = .off

    /// Accepted fixes for the current match, oldest first.
    @ObservationIgnored private(set) var fixes: [RouteFix] = []
    /// Newly accepted fixes, delivered after they've been written to disk.
    @ObservationIgnored var onFixes: (([RouteFix]) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var backgroundActivity: CLBackgroundActivitySession?
    @ObservationIgnored private var journal: RouteJournal?
    @ObservationIgnored private let journalQueue = DispatchQueue(label: "com.matchtracker.watch.routeJournal",
                                                                 qos: .utility)
    @ObservationIgnored private var recordingStart: Date?
    @ObservationIgnored private var monitor = GPSSignalMonitor(startedAt: Date())
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var isUpdating = false
    @ObservationIgnored private var isArmed = false
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var warnedThisLoss = false

    /// Silence long enough to be worth a tap on the wrist.
    private let warningInterval: TimeInterval = 45

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
    }

    // MARK: - Lifecycle

    /// Get a fix before anyone needs it. Foreground only, and cheap to call repeatedly.
    func warmUp() {
        guard !isArmed, isAuthorized, !isUpdating else { return }
        monitor = GPSSignalMonitor(startedAt: Date())
        startUpdates()
        startWatchdog()
    }

    /// Stop warming up (start screen left without starting). Never touches an armed recorder.
    func coolDown() {
        guard !isArmed else { return }
        stopUpdates()
    }

    /// Commit to recording. Call synchronously from the Start tap, while the app is in use.
    func arm() {
        isArmed = true
        retryCount = 0
        warnedThisLoss = false
        MatchLog.info("gps: armed (auth \(manager.authorizationStatus.rawValue), precise \(manager.accuracyAuthorization == .fullAccuracy), warm \(signal == .good))",
                      category: "location")
        guard isAuthorized else {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            refreshSignal()
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        holdBackgroundActivity()
        if !isUpdating {
            monitor = GPSSignalMonitor(startedAt: Date())
            startUpdates()
        }
        startWatchdog()
    }

    /// Start keeping fixes taken at or after `start`. With `resuming`, reload what an earlier
    /// process already wrote for this match.
    func beginRecording(matchID: UUID, start: Date, resuming: Bool = false) {
        let journal = RouteJournal(directory: AppGroupStorage.containerURL, matchID: matchID)
        self.journal = journal
        recordingStart = start
        fixes = resuming ? journal.load() : []
        if resuming {
            MatchLog.info("gps: resumed with \(fixes.count) fixes from disk", category: "location")
        }
    }

    /// Stop and hand back the route. The journal stays on disk until `removeJournal`.
    func finish() -> [RouteFix] {
        logCoverage(end: Date())
        let recorded = fixes
        isArmed = false
        stopUpdates()
        manager.allowsBackgroundLocationUpdates = false
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        journal = nil
        recordingStart = nil
        fixes = []
        return recorded
    }

    /// Delete a match's on-disk route, behind any write still queued for it. Only call once the
    /// route is safe somewhere else.
    func removeJournal(matchID: UUID) {
        let directory = AppGroupStorage.containerURL
        journalQueue.async { RouteJournal(directory: directory, matchID: matchID).remove() }
    }

    /// The app is frontmost again: the best moment there is to restore GPS. Background activity
    /// can only be (re)claimed from here, and a retry is taken now rather than on the backoff.
    func appBecameActive() {
        guard isArmed, isAuthorized else { return }
        manager.allowsBackgroundLocationUpdates = true
        holdBackgroundActivity()
        if !isUpdating {
            startUpdates()
        } else if monitor.shouldRetry(at: Date(), force: true) {
            restartUpdates(reason: "app became active")
        }
    }

    // MARK: - Updates

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    private func holdBackgroundActivity() {
        guard backgroundActivity == nil else { return }
        backgroundActivity = CLBackgroundActivitySession()
    }

    private func startUpdates() {
        isUpdating = true
        manager.startUpdatingLocation()
        refreshSignal()
    }

    private func stopUpdates() {
        isUpdating = false
        watchdog?.cancel()
        watchdog = nil
        manager.stopUpdatingLocation()
        signal = .off
    }

    private func restartUpdates(reason: String) {
        let now = Date()
        retryCount += 1
        MatchLog.error("gps: no callbacks, restarting updates (\(reason), retry \(retryCount), silent \(Int(monitor.silence(at: now))) s)",
                       category: "location")
        monitor.recordRetry(at: now)
        // Stop first: calling start on a running manager is a no-op.
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.checkSignal()
            }
        }
    }

    private func checkSignal() {
        refreshSignal()
        let now = Date()
        guard isArmed else { return }
        if isAuthorized, monitor.shouldRetry(at: now) {
            restartUpdates(reason: "watchdog")
        }
        // Once per loss, while there's still time to do something about it.
        if recordingStart != nil, !warnedThisLoss, monitor.silence(at: now) > warningInterval {
            warnedThisLoss = true
            MatchLog.error("gps: no usable fix for \(Int(monitor.silence(at: now))) s", category: "location")
            WKInterfaceDevice.current().play(.retry)
        }
    }

    private func refreshSignal() {
        let current: Signal
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            current = .denied
        } else if isAuthorized, manager.accuracyAuthorization == .reducedAccuracy {
            // Approximate fixes are kilometers wide: every one fails the accuracy gate.
            current = .imprecise
        } else if !isUpdating && !isArmed {
            current = .off
        } else {
            switch monitor.signal(at: Date()) {
            case .acquiring: current = .acquiring
            case .good: current = .good
            case .lost: current = .lost
            }
        }
        guard current != signal else { return }
        if isArmed { MatchLog.info("gps: signal \(signal) -> \(current)", category: "location") }
        signal = current
    }

    /// One line that says whether a route is whole (counts and durations only).
    private func logCoverage(end: Date) {
        guard let recordingStart else { return }
        let offsets = fixes.map { $0.point.timestamp.timeIntervalSince(recordingStart) }
        let duration = end.timeIntervalSince(recordingStart)
        let edges = [0] + offsets + [duration]
        let longestGap = zip(edges.dropFirst(), edges).map { $0 - $1 }.max() ?? duration
        MatchLog.info("gps: finished with \(fixes.count) fixes over \(Int(duration)) s (first at \(offsets.first.map { "\(Int($0)) s" } ?? "never"), longest gap \(Int(longestGap)) s, retries \(retryCount))",
                      category: "location")
    }
}

// MARK: - CLLocationManagerDelegate

extension RouteRecorder: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let now = Date()
        let usable = locations.contains {
            $0.horizontalAccuracy >= 0
                && $0.horizontalAccuracy <= TrackPoint.maximumUsableHorizontalAccuracy
                && now.timeIntervalSince($0.timestamp) < GPSSignalMonitor.lostInterval
        }
        monitor.recordCallback(at: now, usable: usable)
        if usable { warnedThisLoss = false }
        refreshSignal()

        guard let recordingStart, let journal else { return }
        let accepted = RouteFixFilter.accept(locations.map(RouteFix.init), start: recordingStart,
                                             lastAccepted: fixes.last?.point.timestamp)
        guard !accepted.isEmpty else { return }
        journalQueue.async {
            do {
                try journal.append(accepted)
            } catch {
                MatchLog.error("gps: journal write failed: \(error.localizedDescription)", category: "location")
            }
        }
        if fixes.isEmpty, let first = accepted.first {
            // Accuracy and delay only — the MatchLog privacy contract keeps coordinates out.
            MatchLog.info("gps: first fix \(Int(first.point.timestamp.timeIntervalSince(recordingStart))) s after kickoff (accuracy \(Int(first.point.horizontalAccuracy)) m)",
                          category: "location")
        }
        fixes.append(contentsOf: accepted)
        onFixes?(accepted)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `locationUnknown` is transient and Core Location keeps trying by itself.
        if (error as? CLError)?.code == .locationUnknown { return }
        MatchLog.error("gps: \(error.localizedDescription)", category: "location")
        refreshSignal()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Granted after Start was already tapped: pick up where `arm()` had to stop.
        if isArmed, isAuthorized, !isUpdating {
            manager.allowsBackgroundLocationUpdates = true
            holdBackgroundActivity()
            startUpdates()
            startWatchdog()
        }
        refreshSignal()
    }
}

// MARK: - Conversion

extension RouteFix {
    init(_ location: CLLocation) {
        self.init(
            point: TrackPoint(
                coordinate: Coordinate2D(latitude: location.coordinate.latitude,
                                         longitude: location.coordinate.longitude),
                timestamp: location.timestamp,
                speedMetersPerSecond: location.speed,
                courseDegrees: location.course,
                horizontalAccuracy: location.horizontalAccuracy),
            altitude: location.altitude,
            verticalAccuracy: location.verticalAccuracy)
    }

    var location: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.coordinate.latitude,
                                                      longitude: point.coordinate.longitude),
                   altitude: altitude,
                   horizontalAccuracy: point.horizontalAccuracy,
                   verticalAccuracy: verticalAccuracy,
                   course: point.courseDegrees,
                   speed: point.speedMetersPerSecond,
                   timestamp: point.timestamp)
    }
}
