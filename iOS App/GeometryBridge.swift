// GeometryBridge.swift
// MatchTracker

import Foundation
import CoreLocation
import MapKit
import SwiftUI
import MatchTrackerKit

extension Coordinate2D {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension OrientedRectangle {
    var coordinateRing: [CLLocationCoordinate2D] {
        corners.map(\.clCoordinate)
    }

    /// A map region that comfortably frames the rectangle.
    var mapRegion: MKCoordinateRegion {
        let latitudes = corners.map(\.latitude)
        let longitudes = corners.map(\.longitude)
        let minLat = latitudes.min() ?? center.latitude
        let maxLat = latitudes.max() ?? center.latitude
        let minLon = longitudes.min() ?? center.longitude
        let maxLon = longitudes.max() ?? center.longitude
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.002),
            longitudeDelta: max((maxLon - minLon) * 1.6, 0.002)
        )
        return MKCoordinateRegion(center: center.clCoordinate, span: span)
    }
}

extension FieldModel {
    /// The one state a field can be in. An outline nobody drew or corrected, seen in fewer than
    /// three matches, is a guess worth a look.
    var needsOutlineCheck: Bool {
        source != .trained && observationCount < 3
    }
}

extension UnitSystem {
    /// "115 × 74 yd"
    func fieldSize(length: Double, width: Double) -> String {
        "\(shortDistance(length).value) × \(shortDistance(width).text)"
    }

    /// "115 by 74 yards"
    func spokenFieldSize(length: Double, width: Double) -> String {
        "\(shortDistance(length).value) by \(shortDistance(width).spoken)"
    }
}

/// Display strings in the player's units. Storage and analysis stay metric.
enum MatchFormat {
    /// Match-scale distance ("4.62 mi"), dropping to yards or meters for anything run-sized.
    static func distance(_ meters: Double) -> String {
        measure(meters).text
    }

    /// `distance` with its unit kept apart, for styling and VoiceOver.
    static func measure(_ meters: Double) -> UnitSystem.Measure {
        let units = UnitSystem.current
        let shortThreshold = units == .metric ? 1000.0 : 402.336
        return meters < shortThreshold ? units.shortDistance(meters) : units.distance(meters)
    }

    static func speed(_ metersPerSecond: Double) -> String {
        UnitSystem.current.speed(metersPerSecond).text
    }

    /// A field's size, e.g. "115 × 74 yd".
    static func fieldSize(_ rectangle: OrientedRectangle) -> String {
        UnitSystem.current.fieldSize(length: rectangle.lengthMeters, width: rectangle.widthMeters)
    }

    static func spokenFieldSize(_ rectangle: OrientedRectangle) -> String {
        UnitSystem.current.spokenFieldSize(length: rectangle.lengthMeters, width: rectangle.widthMeters)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        MatchTrackerFormat.hoursMinutesSeconds(seconds)
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) min"
    }
}
