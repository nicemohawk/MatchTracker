// FieldNamer.swift
// MatchTracker
//
// Resolves a human-meaningful name for a field from its location, so saved fields never read
// "New Field" / "Match Field". Preference order:
//   1. A nearby sports/recreation point of interest from Maps ("Riverside Soccer Complex").
//   2. The geocoder's area of interest, which is usually the park or facility name.
//   3. The street ("W Union St Field"), then neighborhood/city as a last resort.
// Purely cosmetic and best-effort: nil means "keep whatever name you have".

import MapKit
import CoreLocation

@MainActor
enum FieldNamer {
    static func suggestedName(for coordinate: CLLocationCoordinate2D) async -> String? {
        if let poi = await nearestFacilityName(coordinate) { return poi }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        if let area = placemark?.areasOfInterest?.first, !area.isEmpty { return area }
        if let street = placemark?.thoroughfare, !street.isEmpty { return "\(street) Field" }
        if let neighborhood = placemark?.subLocality ?? placemark?.locality, !neighborhood.isEmpty {
            return "\(neighborhood) Field"
        }
        return nil
    }

    /// Closest named sports/recreation POI within ~400 m of the pitch center.
    private static func nearestFacilityName(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 400)
        request.pointOfInterestFilter = MKPointOfInterestFilter(
            including: [.stadium, .park, .school, .university, .fitnessCenter])
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }

        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return response.mapItems
            .compactMap { item -> (name: String, distance: CLLocationDistance)? in
                guard let name = item.name, !name.isEmpty else { return nil }
                let itemLocation = CLLocation(latitude: item.placemark.coordinate.latitude,
                                              longitude: item.placemark.coordinate.longitude)
                return (name, itemLocation.distance(from: center))
            }
            .min { $0.distance < $1.distance }?
            .name
    }
}
