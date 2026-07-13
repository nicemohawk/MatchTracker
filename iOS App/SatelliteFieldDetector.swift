// SatelliteFieldDetector.swift
// MatchTracker

import Foundation
import CoreLocation
import CoreImage
import Vision
import MapKit
import UIKit
import simd
import MatchTrackerKit

/// On-device satellite-imagery pitch detection. Snapshots Apple Maps satellite tiles, isolates
/// white line markings, finds quadrilateral contours with Vision, scores them as plausible
/// pitches, and maps their pixel corners back to coordinates. All best-effort — returns [] / nil
/// on any failure. Never runs on watchOS (no snapshotter there).
struct SatelliteFieldDetector {
    struct Proposal {
        var rectangle: OrientedRectangle
        var score: Double
    }

    /// Detect candidate pitches in a map region (e.g. the visible viewport).
    func detectFields(in region: MKCoordinateRegion) async -> [OrientedRectangle] {
        guard let snapshot = try? await snapshot(of: region) else { return [] }
        let proposals = analyze(snapshot: snapshot)
        return proposals
            .sorted { $0.score > $1.score }
            .map(\.rectangle)
    }

    /// Scan around an existing (GPS-inferred) rectangle and return a crisp satellite rectangle
    /// overlapping it by >= 70%, used to sharpen noisy GPS geometry.
    func snap(rectangle: OrientedRectangle) async -> OrientedRectangle? {
        let region = scanRegion(around: rectangle)
        guard let snapshot = try? await snapshot(of: region) else { return nil }
        let candidates = analyze(snapshot: snapshot).map(\.rectangle)
        return candidates
            .filter { overlapFraction(between: $0, and: rectangle) >= 0.7 }
            .max { overlapFraction(between: $0, and: rectangle) < overlapFraction(between: $1, and: rectangle) }
    }

    // MARK: - Snapshot

    private struct Snapshot {
        let mkSnapshot: MKMapSnapshotter.Snapshot
        let sampler: PixelSampler
        let region: MKCoordinateRegion
    }

    private func snapshot(of region: MKCoordinateRegion) async throws -> Snapshot {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 1024, height: 1024)
        options.preferredConfiguration = MKImageryMapConfiguration()

        let snapshotter = MKMapSnapshotter(options: options)
        let mkSnapshot: MKMapSnapshotter.Snapshot = try await withCheckedThrowingContinuation { continuation in
            snapshotter.start { snapshot, error in
                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
        guard let sampler = PixelSampler(image: mkSnapshot.image) else {
            throw CocoaError(.featureUnsupported)
        }
        return Snapshot(mkSnapshot: mkSnapshot, sampler: sampler, region: region)
    }

    // MARK: - Analysis

    private func analyze(snapshot: Snapshot) -> [Proposal] {
        guard let ciImage = CIImage(image: snapshot.mkSnapshot.image) else { return [] }
        let mask = lineMask(from: ciImage)

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 1024

        let handler = VNImageRequestHandler(ciImage: mask, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return [] }

        let imageSize = snapshot.mkSnapshot.image.size
        var proposals: [Proposal] = []

        for index in 0..<observation.contourCount {
            guard let contour = try? observation.contour(at: index) else { continue }
            guard let quad = convexQuad(from: contour) else { continue }

            // Normalized (bottom-left origin) -> image points (top-left origin).
            let imagePoints = quad.map { point in
                CGPoint(x: CGFloat(point.x) * imageSize.width,
                        y: (1 - CGFloat(point.y)) * imageSize.height)
            }

            let coordinates = imagePoints.map { pixelToCoordinate($0, snapshot: snapshot) }
            guard let rectangle = FieldGeometry.fitOrientedRectangle(to: coordinates),
                  FieldGeometry.isPlausiblePitch(rectangle) else { continue }

            let score = score(imagePoints: imagePoints, sampler: snapshot.sampler)
            guard score > 0.15 else { continue }
            proposals.append(Proposal(rectangle: rectangle, score: score))
        }
        return proposals
    }

    /// Isolate bright, low-saturation line markings over green turf.
    private func lineMask(from image: CIImage) -> CIImage {
        let desaturated = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.8,
            kCIInputBrightnessKey: 0.05
        ])
        if let threshold = CIFilter(name: "CIColorThreshold") {
            threshold.setValue(desaturated, forKey: kCIInputImageKey)
            threshold.setValue(0.72, forKey: "inputThreshold")
            if let output = threshold.outputImage { return output }
        }
        return desaturated
    }

    /// Simplify a contour to a convex quadrilateral, or nil if it isn't one.
    private func convexQuad(from contour: VNContour) -> [simd_float2]? {
        guard let approximated = try? contour.polygonApproximation(epsilon: 0.02) else { return nil }
        let points = approximated.normalizedPoints
        guard points.count == 4 else { return nil }
        guard isConvex(points) else { return nil }
        return points
    }

    private func isConvex(_ points: [simd_float2]) -> Bool {
        let count = points.count
        var sign = 0
        for i in 0..<count {
            let a = points[i]
            let b = points[(i + 1) % count]
            let c = points[(i + 2) % count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            let current = cross > 0 ? 1 : (cross < 0 ? -1 : 0)
            if current != 0 {
                if sign == 0 { sign = current }
                else if sign != current { return false }
            }
        }
        return true
    }

    // MARK: - Scoring

    private func score(imagePoints: [CGPoint], sampler: PixelSampler) -> Double {
        let edgeWhiteness = edgeWhiteness(imagePoints: imagePoints, sampler: sampler)
        let greenness = interiorGreenness(imagePoints: imagePoints, sampler: sampler)
        return edgeWhiteness * 0.6 + greenness * 0.4
    }

    private func edgeWhiteness(imagePoints: [CGPoint], sampler: PixelSampler) -> Double {
        var total = 0.0
        var samples = 0
        for i in 0..<imagePoints.count {
            let a = imagePoints[i]
            let b = imagePoints[(i + 1) % imagePoints.count]
            for step in 0...8 {
                let t = CGFloat(step) / 8
                let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                guard let rgb = sampler.rgb(at: point) else { continue }
                let brightness = (rgb.r + rgb.g + rgb.b) / 3
                let maxChannel = max(rgb.r, max(rgb.g, rgb.b))
                let minChannel = min(rgb.r, min(rgb.g, rgb.b))
                let saturation = maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0
                total += (brightness > 0.55 && saturation < 0.3) ? 1 : 0
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }

    private func interiorGreenness(imagePoints: [CGPoint], sampler: PixelSampler) -> Double {
        let center = imagePoints.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / CGFloat(imagePoints.count), y: $0.y + $1.y / CGFloat(imagePoints.count))
        }
        var total = 0.0
        var samples = 0
        for dx in stride(from: -0.3, through: 0.3, by: 0.15) {
            for dy in stride(from: -0.3, through: 0.3, by: 0.15) {
                let point = CGPoint(
                    x: center.x + (imagePoints[1].x - imagePoints[0].x) * dx,
                    y: center.y + (imagePoints[2].y - imagePoints[1].y) * dy
                )
                guard let rgb = sampler.rgb(at: point) else { continue }
                total += (rgb.g > rgb.r && rgb.g > rgb.b) ? 1 : 0
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }

    // MARK: - Coordinate mapping

    private func pixelToCoordinate(_ point: CGPoint, snapshot: Snapshot) -> Coordinate2D {
        let region = snapshot.region
        let topLeft = CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let bottomRight = CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )
        let pTopLeft = snapshot.mkSnapshot.point(for: topLeft)
        let pBottomRight = snapshot.mkSnapshot.point(for: bottomRight)

        let dx = pBottomRight.x - pTopLeft.x
        let dy = pBottomRight.y - pTopLeft.y
        let fx = abs(dx) > 0.0001 ? (point.x - pTopLeft.x) / dx : 0
        let fy = abs(dy) > 0.0001 ? (point.y - pTopLeft.y) / dy : 0

        let longitude = topLeft.longitude + Double(fx) * (bottomRight.longitude - topLeft.longitude)
        let latitude = topLeft.latitude + Double(fy) * (bottomRight.latitude - topLeft.latitude)
        return Coordinate2D(latitude: latitude, longitude: longitude)
    }

    private func scanRegion(around rectangle: OrientedRectangle) -> MKCoordinateRegion {
        let frame = ENUFrame(reference: rectangle.center)
        let padding = rectangle.lengthMeters * 1.6
        return MKCoordinateRegion(
            center: rectangle.center.clCoordinate,
            span: MKCoordinateSpan(
                latitudeDelta: padding / metersPerDegreeLatitude,
                longitudeDelta: padding / max(frame.metersPerDegreeLongitude, 1)
            )
        )
    }

    // MARK: - Overlap (approximate IoU in local ENU meters)

    private func overlapFraction(between a: OrientedRectangle, and b: OrientedRectangle) -> Double {
        let frame = ENUFrame(reference: b.center)
        let quadA = a.corners.map(frame.project)
        let quadB = b.corners.map(frame.project)
        guard quadA.count == 4, quadB.count == 4 else { return 0 }

        let allX = (quadA + quadB).map(\.x)
        let allY = (quadA + quadB).map(\.y)
        guard let minX = allX.min(), let maxX = allX.max(),
              let minY = allY.min(), let maxY = allY.max(), maxX > minX, maxY > minY else { return 0 }

        let steps = 40
        var intersection = 0, union = 0
        for i in 0...steps {
            for j in 0...steps {
                let point = CGPoint(x: minX + (maxX - minX) * CGFloat(i) / CGFloat(steps),
                                    y: minY + (maxY - minY) * CGFloat(j) / CGFloat(steps))
                let inA = pointInQuad(point, quadA)
                let inB = pointInQuad(point, quadB)
                if inA && inB { intersection += 1 }
                if inA || inB { union += 1 }
            }
        }
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private func pointInQuad(_ point: CGPoint, _ quad: [CGPoint]) -> Bool {
        var sign = 0
        for i in 0..<quad.count {
            let a = quad[i]
            let b = quad[(i + 1) % quad.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let current = cross > 0 ? 1 : (cross < 0 ? -1 : 0)
            if current != 0 {
                if sign == 0 { sign = current }
                else if sign != current { return false }
            }
        }
        return true
    }
}

/// Reads RGBA pixels from a snapshot image for line/turf scoring.
struct PixelSampler {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let pixels: [UInt8]

    init?(image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        width = cgImage.width
        height = cgImage.height
        bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }

    /// RGB (0...1) at an image point; the point is in image-point space (top-left origin).
    func rgb(at point: CGPoint) -> (r: Double, g: Double, b: Double)? {
        let x = Int(point.x)
        let y = Int(point.y)
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = y * bytesPerRow + x * 4
        return (Double(pixels[offset]) / 255,
                Double(pixels[offset + 1]) / 255,
                Double(pixels[offset + 2]) / 255)
    }
}
