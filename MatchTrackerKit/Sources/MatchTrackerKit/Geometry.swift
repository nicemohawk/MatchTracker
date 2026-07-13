import Foundation
import CoreGraphics

// MARK: - Geometry & fields

public struct Coordinate2D: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct OrientedRectangle: Codable, Equatable, Sendable {
    public var center: Coordinate2D
    public var lengthMeters: Double      // long side
    public var widthMeters: Double       // short side
    public var headingDegrees: Double    // compass bearing of long axis, 0..<180
    public var corners: [Coordinate2D]   // 4, ordered, closed ring NOT repeated

    public init(center: Coordinate2D, lengthMeters: Double, widthMeters: Double, headingDegrees: Double, corners: [Coordinate2D]) {
        self.center = center
        self.lengthMeters = lengthMeters
        self.widthMeters = widthMeters
        self.headingDegrees = headingDegrees
        self.corners = corners
    }
}

public enum FieldGeometry {
    /// Minimum-area oriented bounding rectangle of the outline (convex hull + rotating
    /// calipers, computed in a local ENU meters projection around the centroid).
    public static func fitOrientedRectangle(to outline: [Coordinate2D]) -> OrientedRectangle? {
        // STUB: naive axis-aligned bounding box, no rotating calipers yet.
        guard !outline.isEmpty else { return nil }

        let latitudes = outline.map(\.latitude)
        let longitudes = outline.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return nil }

        let center = Coordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(center.latitude * .pi / 180)
        let height = (maxLat - minLat) * metersPerDegreeLat
        let width = (maxLon - minLon) * metersPerDegreeLon

        let corners = [
            Coordinate2D(latitude: minLat, longitude: minLon),
            Coordinate2D(latitude: minLat, longitude: maxLon),
            Coordinate2D(latitude: maxLat, longitude: maxLon),
            Coordinate2D(latitude: maxLat, longitude: minLon)
        ]

        return OrientedRectangle(
            center: center,
            lengthMeters: max(width, height),
            widthMeters: min(width, height),
            headingDegrees: width >= height ? 90 : 0,
            corners: corners
        )
    }

    /// Ramer–Douglas–Peucker simplification, tolerance in meters.
    public static func simplify(_ outline: [Coordinate2D], toleranceMeters: Double) -> [Coordinate2D] {
        // STUB: pass-through, no simplification yet.
        return outline
    }

    /// Infer a field rectangle from a full-match GPS track (no training walk needed):
    /// filter to accurate points, trim occupancy outliers, fit the min-area oriented
    /// rectangle, and sanity-check against plausible pitch dimensions.
    public static func inferFieldRectangle(from track: [TrackPoint]) -> OrientedRectangle? {
        // STUB: fit a bounding rectangle over all coordinates, no outlier trimming or
        // dimension sanity-checking yet.
        let coordinates = track.map(\.coordinate)
        return fitOrientedRectangle(to: coordinates)
    }
}

public struct FieldProjector: Sendable {
    private let rectangle: OrientedRectangle

    public init(rectangle: OrientedRectangle) {
        self.rectangle = rectangle
    }

    public func normalizedPoint(for coordinate: Coordinate2D) -> CGPoint? {
        // STUB: linear map of lat/lon into the rectangle's bounding box.
        guard rectangle.corners.count == 4 else { return nil }
        let latitudes = rectangle.corners.map(\.latitude)
        let longitudes = rectangle.corners.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max(),
              maxLat > minLat, maxLon > minLon else { return nil }

        let x = (coordinate.longitude - minLon) / (maxLon - minLon)
        let y = (coordinate.latitude - minLat) / (maxLat - minLat)
        return CGPoint(x: x, y: y)
    }

    public func contains(_ coordinate: Coordinate2D, toleranceMeters: Double) -> Bool {
        // STUB: inside the normalized unit square with a slack margin.
        guard let point = normalizedPoint(for: coordinate) else { return false }
        let slack = 0.0
        return point.x >= -slack && point.x <= 1 + slack && point.y >= -slack && point.y <= 1 + slack
    }
}
