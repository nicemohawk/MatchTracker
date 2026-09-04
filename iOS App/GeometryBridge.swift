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

extension FieldSource {
    /// Overlay color coding per the UX contract.
    var color: Color {
        switch self {
        case .trained: return .blue
        case .inferred: return .orange
        case .satellite: return .purple
        case .community: return .teal
        }
    }

    var label: String {
        switch self {
        case .trained: return "Trained"
        case .inferred: return "Inferred"
        case .satellite: return "Satellite"
        case .community: return "Community"
        }
    }
}

enum MatchFormat {
    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        MatchTrackerFormat.hoursMinutesSeconds(seconds)
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) min"
    }

    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.1f km/h", metersPerSecond * 3.6)
    }
}
