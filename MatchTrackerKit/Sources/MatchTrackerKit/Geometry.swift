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
        let coordinates = outline.filter(isPlausibleCoordinate)
        guard coordinates.count >= 3 else { return nil }

        let frame = ENUFrame(reference: centroid(of: coordinates))
        let projected = coordinates.map { frame.project($0) }
        guard let rect = minimumAreaRectangle(for: projected) else { return nil }

        let centerCoordinate = frame.unproject(rect.center)
        return makeOrientedRectangle(
            center: centerCoordinate,
            lengthMeters: rect.lengthMeters,
            widthMeters: rect.widthMeters,
            headingDegrees: rect.headingDegrees
        )
    }

    /// Ramer–Douglas–Peucker simplification, tolerance in meters.
    public static func simplify(_ outline: [Coordinate2D], toleranceMeters: Double) -> [Coordinate2D] {
        guard outline.count > 2, toleranceMeters > 0 else { return outline }

        let frame = ENUFrame(reference: centroid(of: outline))
        let points = outline.map { frame.project($0) }
        var keep = [Bool](repeating: false, count: outline.count)
        keep[0] = true
        keep[outline.count - 1] = true
        douglasPeucker(points, first: 0, last: outline.count - 1, tolerance: toleranceMeters, keep: &keep)

        return zip(outline, keep).compactMap { $0.1 ? $0.0 : nil }
    }

    /// Perpendicular distance (meters) from `point` to the segment `a`–`b`.
    private static func perpendicularDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x)
        let dy = Double(b.y - a.y)
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 1e-12 {
            return hypot(Double(point.x - a.x), Double(point.y - a.y))
        }
        let t = (Double(point.x - a.x) * dx + Double(point.y - a.y) * dy) / lengthSquared
        let projX = Double(a.x) + t * dx
        let projY = Double(a.y) + t * dy
        return hypot(Double(point.x) - projX, Double(point.y) - projY)
    }

    private static func douglasPeucker(_ points: [CGPoint], first: Int, last: Int, tolerance: Double, keep: inout [Bool]) {
        guard last > first + 1 else { return }
        var maxDistance = 0.0
        var maxIndex = first
        for index in (first + 1)..<last {
            let distance = perpendicularDistance(points[index], points[first], points[last])
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = index
            }
        }
        if maxDistance > tolerance {
            keep[maxIndex] = true
            douglasPeucker(points, first: first, last: maxIndex, tolerance: tolerance, keep: &keep)
            douglasPeucker(points, first: maxIndex, last: last, tolerance: tolerance, keep: &keep)
        }
    }

    /// Whether an oriented rectangle has plausible soccer-pitch dimensions: length 60–130 m,
    /// width 35–90 m, aspect ratio > 1.2. The single source of truth for this sanity check,
    /// shared by `inferFieldRectangle` and the app-layer satellite detector.
    public static func isPlausiblePitch(_ rectangle: OrientedRectangle) -> Bool {
        let length = rectangle.lengthMeters
        let width = rectangle.widthMeters
        guard width > 0 else { return false }
        return length >= 60 && length <= 130
            && width >= 35 && width <= 90
            && length / width > 1.2
    }

    /// Infer a field rectangle from a full-match GPS track (no training walk needed):
    /// filter to accurate points, trim occupancy outliers, fit the min-area oriented
    /// rectangle, and sanity-check against plausible pitch dimensions.
    public static func inferFieldRectangle(from track: [TrackPoint]) -> OrientedRectangle? {
        let filtered = track.filter { $0.horizontalAccuracy <= TrackPoint.maximumUsableHorizontalAccuracy && isPlausibleCoordinate($0.coordinate) }
        guard filtered.count >= 8 else { return nil }

        let coordinates = filtered.map(\.coordinate)
        let frame = ENUFrame(reference: centroid(of: coordinates))
        let projected = coordinates.map { frame.project($0) }

        // Trim occupancy outliers (warm-up / walk-off excursions): drop the points whose
        // distance from the median center exceeds the 98th percentile of that distance.
        let medianX = median(projected.map { Double($0.x) })
        let medianY = median(projected.map { Double($0.y) })
        let distances = projected.map { hypot(Double($0.x) - medianX, Double($0.y) - medianY) }
        let cutoff = percentile(distances, 0.98)
        let kept = zip(projected, distances).compactMap { $0.1 <= cutoff ? $0.0 : nil }
        guard kept.count >= 4 else { return nil }

        guard let rect = minimumAreaRectangle(for: kept) else { return nil }

        // Players don't quite reach the touchlines; expand the occupied cloud a touch.
        let length = rect.lengthMeters * 1.05
        let width = rect.widthMeters * 1.05

        let centerCoordinate = frame.unproject(rect.center)
        let rectangle = makeOrientedRectangle(
            center: centerCoordinate,
            lengthMeters: length,
            widthMeters: width,
            headingDegrees: rect.headingDegrees
        )
        guard isPlausiblePitch(rectangle) else { return nil }
        return rectangle
    }
}

public struct FieldProjector: Sendable {
    private let rectangle: OrientedRectangle
    private let frame: ENUFrame
    private let longAxis: CGPoint   // unit (east, north) along the long axis
    private let shortAxis: CGPoint  // unit (east, north) along the short axis
    private let halfLength: Double
    private let halfWidth: Double

    /// How far outside the rectangle (meters) a point may lie and still map to a normalized point.
    private static let outsideToleranceMeters = 20.0

    public init(rectangle: OrientedRectangle) {
        self.rectangle = rectangle
        self.frame = ENUFrame(reference: rectangle.center)
        let radians = foldHeading(rectangle.headingDegrees) * .pi / 180
        self.longAxis = CGPoint(x: sin(radians), y: cos(radians))
        self.shortAxis = CGPoint(x: cos(radians), y: -sin(radians))
        self.halfLength = rectangle.lengthMeters / 2
        self.halfWidth = rectangle.widthMeters / 2
    }

    /// Signed projections of a coordinate onto the long/short axes, in meters from the center.
    private func axisProjections(for coordinate: Coordinate2D) -> (long: Double, short: Double) {
        let local = frame.project(coordinate)
        let long = Double(local.x) * Double(longAxis.x) + Double(local.y) * Double(longAxis.y)
        let short = Double(local.x) * Double(shortAxis.x) + Double(local.y) * Double(shortAxis.y)
        return (long, short)
    }

    public func normalizedPoint(for coordinate: Coordinate2D) -> CGPoint? {
        guard rectangle.lengthMeters > 0, rectangle.widthMeters > 0 else { return nil }
        let (long, short) = axisProjections(for: coordinate)

        let overrunLong = max(0, abs(long) - halfLength)
        let overrunShort = max(0, abs(short) - halfWidth)
        if hypot(overrunLong, overrunShort) > Self.outsideToleranceMeters { return nil }

        let x = long / rectangle.lengthMeters + 0.5
        let y = short / rectangle.widthMeters + 0.5
        return CGPoint(x: x, y: y)
    }

    public func contains(_ coordinate: Coordinate2D, toleranceMeters: Double) -> Bool {
        guard rectangle.lengthMeters > 0, rectangle.widthMeters > 0 else { return false }
        let (long, short) = axisProjections(for: coordinate)
        let overrunLong = max(0, abs(long) - halfLength)
        let overrunShort = max(0, abs(short) - halfWidth)
        return overrunLong <= toleranceMeters && overrunShort <= toleranceMeters
    }
}
