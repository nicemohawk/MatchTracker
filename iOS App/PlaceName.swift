// PlaceName.swift
// MatchTracker
//
// Reverse-geocoded "City, State" labels for match locations. CLGeocoder is rate-limited and
// async, so lookups are cached by a ~1 km coordinate grid (venues don't move) and serialized
// through one geocoder instance. Purely cosmetic metadata: failures return nil and the UI
// simply omits the place line.

import CoreLocation

@MainActor
enum PlaceNameService {
    private static var cache: [String: String?] = [:]
    private static let geocoder = CLGeocoder()

    /// Human-readable place ("Athens, Ohio") for a coordinate, or nil when geocoding fails.
    static func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let key = String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] { return cached }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await geocoder.reverseGeocodeLocation(location).first
        let name = [placemark?.locality, placemark?.administrativeArea]
            .compactMap(\.self)
            .joined(separator: ", ")
        let result = name.isEmpty ? nil : name
        cache[key] = result
        return result
    }
}
