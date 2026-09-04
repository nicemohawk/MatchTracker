//
//  FieldTrainer.swift
//  MatchTracker
//

import Foundation
import Observation
import CoreLocation
import HealthKit
import WatchKit
import MatchTrackerKit

/// Records a touchline walk to define a field, modernizing the legacy training flow.
///
/// The user starts at a corner and walks the perimeter. We accumulate accurate GPS samples,
/// report the live distance walked, and auto-finish (with a haptic) once they return within
/// `closeDistance` of the start after covering more than `minimumLoopDistance`.
///
/// The walk runs inside a throwaway `HKWorkoutSession` (never saved): a bare
/// `startUpdatingLocation()` on watchOS gets throttled to sporadic fixes and stops entirely
/// wrist-down — a real walk once produced 8 points across three sides of a pitch. The session
/// keeps GPS hot at ~1 Hz and the app running for the whole loop.
@Observable
final class FieldTrainer: NSObject {
    enum State: Equatable {
        case idle
        case walking
        case finished
    }

    var state: State = .idle
    var distanceWalked: Double = 0     // meters
    var sampleCount = 0
    /// True while no usable fix has arrived for a while mid-walk — surfaced live so a starving
    /// walk is visible AT THE FIELD, not after a garbage fit at home.
    var gpsWeak = false

    private let closeDistance: Double = 10          // must return within 10 m of start
    private let minimumLoopDistance: Double = 50    // after covering > 50 m
    /// No accepted fix for this long mid-walk = the "weak GPS" state (journaled + shown).
    private let starvationInterval: TimeInterval = 8

    private let locationManager = CLLocationManager()
    private let healthStore = HKHealthStore()
    private var gpsSession: HKWorkoutSession?
    private var outline: [CLLocation] = []
    private var startLocation: CLLocation?
    private var walkBegan: Date?
    private var lastAcceptedAt: Date?
    private var rejectedCount = 0
    private var starvationWatchdog: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .fitness
    }

    func start() {
        outline = []
        startLocation = nil
        distanceWalked = 0
        sampleCount = 0
        rejectedCount = 0
        gpsWeak = false
        walkBegan = Date()
        lastAcceptedAt = nil
        state = .walking
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        MatchLog.info("field walk: started (location auth \(locationManager.authorizationStatus.rawValue), gate \(Int(TrackPoint.fieldTrainingHorizontalAccuracy)) m)",
                      category: "training")
        startGPSSession()
        locationManager.startUpdatingLocation()
        startStarvationWatchdog()
    }

    func cancel() {
        stopRecording()
        MatchLog.info("field walk: cancelled after \(sampleCount) points / \(Int(distanceWalked)) m",
                      category: "training")
        state = .idle
    }

    /// Manually finish the walk (used when the user can't quite close the loop).
    func finish() {
        finish(reason: "manual")
    }

    private func finish(reason: String) {
        stopRecording()
        let duration = walkBegan.map { Int(Date().timeIntervalSince($0)) } ?? 0
        MatchLog.info("field walk: finished (\(reason)) — \(sampleCount) points, \(Int(distanceWalked)) m, \(duration) s, \(rejectedCount) rejected, sparse \(walkLooksSparse)",
                      category: "training")
        state = .finished
    }

    private func stopRecording() {
        locationManager.stopUpdatingLocation()
        starvationWatchdog?.cancel()
        starvationWatchdog = nil
        gpsSession?.end()
        gpsSession = nil
    }

    /// A throwaway workout session purely for GPS priority + runtime. Never collects or saves a
    /// workout; failures degrade to the old throttled behavior rather than blocking the walk.
    private func startGPSSession() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session.startActivity(with: Date())
            gpsSession = session
            MatchLog.info("field walk: GPS workout session started", category: "training")
        } catch {
            MatchLog.error("field walk: GPS session failed (\(error.localizedDescription)) — walk continues throttled",
                           category: "training")
        }
    }

    private func startStarvationWatchdog() {
        starvationWatchdog = Task { @MainActor [weak self] in
            while let self, self.state == .walking {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.state == .walking else { return }
                let reference = self.lastAcceptedAt ?? self.walkBegan ?? Date()
                let gap = Date().timeIntervalSince(reference)
                if gap > self.starvationInterval, !self.gpsWeak {
                    self.gpsWeak = true
                    WKInterfaceDevice.current().play(.retry)
                    MatchLog.error("field walk: no usable fix for \(Int(gap)) s at point \(self.sampleCount)",
                                   category: "training")
                }
            }
        }
    }

    /// Whether the walk captured too few points to trust the fit: a steady 1 Hz walk yields
    /// ~0.7 points/m, so anything under ~0.2 (or a tiny absolute count) means GPS starved and
    /// the rectangle is guesswork.
    var walkLooksSparse: Bool {
        guard distanceWalked > 0 else { return true }
        let density = Double(sampleCount) / distanceWalked
        return sampleCount < 30 || density < 0.2
    }

    /// Build a trained `FieldModel` from the walked outline. Returns nil if the walk is too short.
    func makeField(named name: String) -> FieldModel? {
        let coordinates = outline.map {
            Coordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        guard coordinates.count >= 4,
              let rectangle = FieldGeometry.fitOrientedRectangle(to: coordinates) else { return nil }
        return FieldModel(
            id: UUID(),
            name: name.isEmpty ? "New Field" : name,
            createdAt: Date(),
            outline: coordinates,
            rectangle: rectangle,
            source: .trained,
            observationCount: 0
        )
    }

    /// Journal the fit that actually got saved (dimensions only — never coordinates).
    func logSavedField(_ field: FieldModel) {
        let rectangle = field.rectangle
        let density = distanceWalked > 0 ? Double(sampleCount) / distanceWalked : 0
        MatchLog.info(String(format: "field walk: saved fit %.0f×%.0f m from %d points (%.2f pts/m, sparse %@)",
                             rectangle.lengthMeters, rectangle.widthMeters, sampleCount, density,
                             walkLooksSparse ? "true" : "false"),
                      category: "training")
    }
}

// MARK: - CLLocationManagerDelegate

extension FieldTrainer: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .walking else { return }
        for location in locations {
            guard location.horizontalAccuracy <= TrackPoint.fieldTrainingHorizontalAccuracy else {
                rejectedCount += 1
                if rejectedCount % 10 == 0 {
                    MatchLog.info("field walk: \(rejectedCount) fixes rejected by the \(Int(TrackPoint.fieldTrainingHorizontalAccuracy)) m gate (latest \(Int(location.horizontalAccuracy)) m)",
                                  category: "training")
                }
                continue
            }
            let gap = lastAcceptedAt.map { location.timestamp.timeIntervalSince($0) }
            if let previous = outline.last {
                distanceWalked += location.distance(from: previous)
            }
            outline.append(location)
            sampleCount = outline.count
            lastAcceptedAt = location.timestamp
            if gpsWeak { gpsWeak = false }
            if startLocation == nil { startLocation = location }
            // Cadence breadcrumb every 10th point: enough to reconstruct where a walk starved
            // without journaling every fix.
            if sampleCount % 10 == 0 || sampleCount == 1 {
                MatchLog.info(String(format: "field walk: point %d at %.0f m (accuracy %.0f m, gap %.1f s)",
                                     sampleCount, distanceWalked, location.horizontalAccuracy, gap ?? 0),
                              category: "training")
            }

            if let start = startLocation,
               distanceWalked > minimumLoopDistance,
               location.distance(from: start) <= closeDistance {
                finish(reason: "loop closed")
                WKInterfaceDevice.current().play(.success)
                return
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MatchLog.error("field walk: location error \(error.localizedDescription)", category: "training")
    }
}
