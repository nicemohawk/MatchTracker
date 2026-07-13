//
//  FieldTrainer.swift
//  MatchTracker
//

import Foundation
import Observation
import CoreLocation
import WatchKit
import MatchTrackerKit

/// Records a touchline walk to define a field, modernizing the legacy training flow.
///
/// The user starts at a corner and walks the perimeter. We accumulate accurate GPS samples,
/// report the live distance walked, and auto-finish (with a haptic) once they return within
/// `closeDistance` of the start after covering more than `minimumLoopDistance`.
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

    private let closeDistance: Double = 10          // must return within 10 m of start
    private let minimumLoopDistance: Double = 50    // after covering > 50 m

    private let locationManager = CLLocationManager()
    private var outline: [CLLocation] = []
    private var startLocation: CLLocation?

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
        state = .walking
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.startUpdatingLocation()
    }

    func cancel() {
        locationManager.stopUpdatingLocation()
        state = .idle
    }

    /// Manually finish the walk (used when the user can't quite close the loop).
    func finish() {
        locationManager.stopUpdatingLocation()
        state = .finished
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
}

// MARK: - CLLocationManagerDelegate

extension FieldTrainer: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .walking else { return }
        for location in locations where location.horizontalAccuracy <= TrackPoint.fieldTrainingHorizontalAccuracy {
            if let previous = outline.last {
                distanceWalked += location.distance(from: previous)
            }
            outline.append(location)
            sampleCount = outline.count
            if startLocation == nil { startLocation = location }

            if let start = startLocation,
               distanceWalked > minimumLoopDistance,
               location.distance(from: start) <= closeDistance {
                finish()
                WKInterfaceDevice.current().play(.success)
                return
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
