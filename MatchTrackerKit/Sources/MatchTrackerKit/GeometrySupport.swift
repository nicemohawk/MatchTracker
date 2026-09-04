import Foundation
import CoreGraphics

// MARK: - Internal geometry support
//
// Shared numeric helpers used across the analytics engine. Everything works in a local
// East-North-Up (ENU) meters frame around a reference coordinate. Equirectangular projection
// is accurate to well under a meter at soccer-pitch scale, which is all the geometry needs.

/// Meters per degree of latitude (mean Earth radius). Longitude is scaled by cos(latitude).
public let metersPerDegreeLatitude = 111_320.0

/// Local tangent-plane (East-North-Up) projection around a reference coordinate.
/// Projected points use `x` = meters east, `y` = meters north. Accurate to well under a meter
/// at soccer-pitch scale; shared by the analytics engine and app-layer geometry.
public struct ENUFrame {
    public let referenceLatitude: Double
    public let referenceLongitude: Double
    public let metersPerDegreeLongitude: Double

    public init(reference: Coordinate2D) {
        referenceLatitude = reference.latitude
        referenceLongitude = reference.longitude
        metersPerDegreeLongitude = metersPerDegreeLatitude * cos(reference.latitude * .pi / 180)
    }

    public func project(_ coordinate: Coordinate2D) -> CGPoint {
        CGPoint(
            x: (coordinate.longitude - referenceLongitude) * metersPerDegreeLongitude,
            y: (coordinate.latitude - referenceLatitude) * metersPerDegreeLatitude
        )
    }

    public func unproject(_ point: CGPoint) -> Coordinate2D {
        Coordinate2D(
            latitude: referenceLatitude + Double(point.y) / metersPerDegreeLatitude,
            longitude: referenceLongitude + Double(point.x) / max(metersPerDegreeLongitude, 1e-9)
        )
    }
}

/// Great-circle distance in meters.
func haversineMeters(_ a: Coordinate2D, _ b: Coordinate2D) -> Double {
    let earthRadius = 6_371_000.0
    let deltaLatitude = (b.latitude - a.latitude) * .pi / 180
    let deltaLongitude = (b.longitude - a.longitude) * .pi / 180
    let latitudeA = a.latitude * .pi / 180
    let latitudeB = b.latitude * .pi / 180
    let h = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
        + cos(latitudeA) * cos(latitudeB) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
    return 2 * earthRadius * asin(min(1, sqrt(h)))
}

/// Simple arithmetic-mean centroid of a coordinate cloud (good enough for a local frame origin).
func centroid(of coordinates: [Coordinate2D]) -> Coordinate2D {
    guard !coordinates.isEmpty else { return Coordinate2D(latitude: 0, longitude: 0) }
    let latitude = coordinates.reduce(0) { $0 + $1.latitude } / Double(coordinates.count)
    let longitude = coordinates.reduce(0) { $0 + $1.longitude } / Double(coordinates.count)
    return Coordinate2D(latitude: latitude, longitude: longitude)
}

/// Whether a coordinate is a physically plausible fix (not the null island, in range, finite).
func isPlausibleCoordinate(_ coordinate: Coordinate2D) -> Bool {
    guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return false }
    guard coordinate.latitude >= -90, coordinate.latitude <= 90 else { return false }
    guard coordinate.longitude >= -180, coordinate.longitude <= 180 else { return false }
    if abs(coordinate.latitude) < 1e-6 && abs(coordinate.longitude) < 1e-6 { return false }
    return true
}

// MARK: Statistics

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

func standardDeviation(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let m = mean(values)
    let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
    return sqrt(variance)
}

/// Linear-interpolated percentile (0...1) of a value list.
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    if sorted.count == 1 { return sorted[0] }
    let clamped = min(max(fraction, 0), 1)
    let position = clamped * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper { return sorted[lower] }
    let weight = position - Double(lower)
    return sorted[lower] * (1 - weight) + sorted[upper] * weight
}

// MARK: Convex hull & minimum-area rectangle

/// Andrew's monotone chain convex hull. Returns hull points counter-clockwise, no repeat.
func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    let unique = Array(Set(points.map { PackedPoint($0) })).map { $0.point }
    guard unique.count >= 3 else { return unique }

    let sorted = unique.sorted { lhs, rhs in
        lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
    }

    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        Double(a.x - o.x) * Double(b.y - o.y) - Double(a.y - o.y) * Double(b.x - o.x)
    }

    var lower: [CGPoint] = []
    for point in sorted {
        while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
            lower.removeLast()
        }
        lower.append(point)
    }

    var upper: [CGPoint] = []
    for point in sorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
            upper.removeLast()
        }
        upper.append(point)
    }

    lower.removeLast()
    upper.removeLast()
    return lower + upper
}

/// Hashable wrapper so we can de-duplicate CGPoints (which aren't Hashable to the precision we want).
private struct PackedPoint: Hashable {
    let x: Double
    let y: Double
    init(_ point: CGPoint) {
        // Snap to 1 mm to fold GPS-identical points together without collapsing real structure.
        x = (Double(point.x) * 1000).rounded() / 1000
        y = (Double(point.y) * 1000).rounded() / 1000
    }
    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// The result of a minimum-area oriented rectangle fit, expressed in an ENU frame.
struct MinAreaRectangle {
    var center: CGPoint          // ENU meters
    var lengthMeters: Double     // long side
    var widthMeters: Double      // short side
    var headingDegrees: Double   // compass bearing of the long axis, folded to 0..<180
}

/// Fold an undirected axis bearing into the 0..<180 half-circle.
func foldHeading(_ degrees: Double) -> Double {
    var value = degrees.truncatingRemainder(dividingBy: 180)
    if value < 0 { value += 180 }
    if value >= 180 { value -= 180 }
    return value
}

/// Minimum-area enclosing rectangle via rotating calipers over the convex hull.
/// Points are ENU meters; the returned center is in the same frame.
func minimumAreaRectangle(for points: [CGPoint]) -> MinAreaRectangle? {
    let hull = convexHull(points)
    guard hull.count >= 3 else { return nil }

    var best: (area: Double, rect: MinAreaRectangle)?
    let count = hull.count
    for index in 0..<count {
        let a = hull[index]
        let b = hull[(index + 1) % count]
        let edge = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let length = hypot(Double(edge.x), Double(edge.y))
        guard length > 1e-9 else { continue }
        let unitX = Double(edge.x) / length
        let unitY = Double(edge.y) / length

        var minU = Double.greatestFiniteMagnitude
        var maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude
        for point in hull {
            let u = Double(point.x) * unitX + Double(point.y) * unitY
            let v = -Double(point.x) * unitY + Double(point.y) * unitX
            minU = min(minU, u); maxU = max(maxU, u)
            minV = min(minV, v); maxV = max(maxV, v)
        }

        let extentU = maxU - minU
        let extentV = maxV - minV
        let area = extentU * extentV
        if best == nil || area < best!.area {
            let centerU = (minU + maxU) / 2
            let centerV = (minV + maxV) / 2
            // Rotate the edge-frame center back into ENU.
            let centerX = centerU * unitX + centerV * (-unitY)
            let centerY = centerU * unitY + centerV * unitX

            let longAlongEdge = extentU >= extentV
            let length = max(extentU, extentV)
            let width = min(extentU, extentV)
            // Long-axis direction vector (east, north).
            let axisEast = longAlongEdge ? unitX : -unitY
            let axisNorth = longAlongEdge ? unitY : unitX
            let heading = foldHeading(atan2(axisEast, axisNorth) * 180 / .pi)

            best = (area, MinAreaRectangle(
                center: CGPoint(x: centerX, y: centerY),
                lengthMeters: length,
                widthMeters: width,
                headingDegrees: heading
            ))
        }
    }
    return best?.rect
}

/// Build a canonical `OrientedRectangle` from center/size/heading, generating ordered corners.
func makeOrientedRectangle(center: Coordinate2D, lengthMeters: Double, widthMeters: Double, headingDegrees: Double) -> OrientedRectangle {
    let heading = foldHeading(headingDegrees)
    let frame = ENUFrame(reference: center)
    let radians = heading * .pi / 180
    // Long axis points along the compass bearing; short axis is 90° clockwise from it.
    let longAxis = CGPoint(x: sin(radians), y: cos(radians))   // (east, north)
    let shortAxis = CGPoint(x: cos(radians), y: -sin(radians)) // (east, north)
    let halfLength = lengthMeters / 2
    let halfWidth = widthMeters / 2

    func corner(_ alongLong: Double, _ alongShort: Double) -> Coordinate2D {
        let east = alongLong * Double(longAxis.x) + alongShort * Double(shortAxis.x)
        let north = alongLong * Double(longAxis.y) + alongShort * Double(shortAxis.y)
        return frame.unproject(CGPoint(x: east, y: north))
    }

    let corners = [
        corner(-halfLength, -halfWidth),
        corner(halfLength, -halfWidth),
        corner(halfLength, halfWidth),
        corner(-halfLength, halfWidth)
    ]

    return OrientedRectangle(
        center: center,
        lengthMeters: lengthMeters,
        widthMeters: widthMeters,
        headingDegrees: heading,
        corners: corners
    )
}
