// SatelliteDetectorDebug.swift
// MatchTracker
//
// DEBUG-only instrumentation for `SatelliteFieldDetector`. Drives the real detector over a set of
// real-world coordinate regions and writes annotated snapshot PNGs plus a results JSON to a
// directory shared with the UI-test runner, so `DetectorValidation` can assert recall/precision
// and attach the imagery for human inspection.
//
// It is triggered entirely from a launch argument — no app-launch wiring is touched. The detector
// is constructed during normal app startup (NearbyFieldSeeder owns one), and its DEBUG `init`
// calls `bootstrapIfRequested()`; the runner only does anything when `-RunDetectorValidation` is
// present, and runs at most once per process.

#if DEBUG
import Foundation
import CoreLocation
import MapKit
import UIKit
import MatchTrackerKit

enum SatelliteDetectorValidation {
    /// Launch argument (NSArgumentDomain): `-RunDetectorValidation "name,lat,lon,span; name,lat,lon,span; …"`.
    /// Each entry is `lat,lon,span` (3 fields) or `name,lat,lon,span` (4 fields); `span` is the
    /// latitude/longitude delta in degrees.
    static let launchKey = "RunDetectorValidation"
    /// Optional launch-environment override for where results are written. Defaults to a directory
    /// under `SIMULATOR_SHARED_RESOURCES_DIRECTORY`, which both the app and the test runner see.
    static let outputEnvKey = "DETECTOR_VALIDATION_OUTPUT"

    private static let didStart = Locked(false)

    /// Called from `SatelliteFieldDetector.init()` on DEBUG builds. Cheap no-op unless the launch
    /// argument is present; kicks the run off exactly once.
    static func bootstrapIfRequested() {
        guard let spec = UserDefaults.standard.string(forKey: launchKey), !spec.isEmpty else { return }
        let shouldStart = didStart.mutate { started -> Bool in
            if started { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        Task.detached(priority: .utility) { await run(spec: spec) }
    }

    // MARK: - Runner

    private struct RegionSpec {
        let name: String
        let region: MKCoordinateRegion
    }

    private struct RegionResult: Codable {
        let name: String
        let latitude: Double
        let longitude: Double
        let span: Double
        let detectionCount: Int
        let scores: [Double]
        let lengthsMeters: [Double]
        let widthsMeters: [Double]
        let timingMilliseconds: Double
        let annotatedImage: String
        let note: String
    }

    private static func run(spec: String) async {
        let outputDirectory = resolveOutputDirectory()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let detector = SatelliteFieldDetector()
        var results: [RegionResult] = []

        for region in parse(spec) {
            let start = Date()
            let detections = await detector.detectFields(in: region.region)
            let elapsed = Date().timeIntervalSince(start) * 1000

            let imageName = "\(sanitize(region.name)).png"
            let note = await annotate(region: region, detections: detections, detector: detector,
                                      writingTo: outputDirectory.appendingPathComponent(imageName))

            results.append(RegionResult(
                name: region.name,
                latitude: region.region.center.latitude,
                longitude: region.region.center.longitude,
                span: region.region.span.latitudeDelta,
                detectionCount: detections.count,
                scores: [],   // scores aren't part of the public API return; recall is what matters here
                lengthsMeters: detections.map { ($0.lengthMeters * 10).rounded() / 10 },
                widthsMeters: detections.map { ($0.widthMeters * 10).rounded() / 10 },
                timingMilliseconds: (elapsed * 10).rounded() / 10,
                annotatedImage: imageName,
                note: note
            ))
        }

        writeResults(results, to: outputDirectory)
    }

    /// Render the base-scale snapshot with detected rectangles overlaid, so a human can see whether
    /// imagery actually shows a pitch and whether the detector framed it. Returns a short note.
    private static func annotate(region: RegionSpec, detections: [OrientedRectangle],
                                 detector: SatelliteFieldDetector,
                                 writingTo url: URL) async -> String {
        guard let snapshot = try? await detector.snapshot(of: region.region) else {
            return "snapshot failed"
        }
        let image = snapshot.mkSnapshot.image
        // Pre-gate ridge candidates (drawn thin/blue) reveal where the model-driven search landed even
        // when nothing passed the gates — the key signal when debugging a 0-detection worn pitch.
        let ridgeRectangles = detector.ridgeSearchDebugRectangles(snapshot: snapshot)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let annotated = renderer.image { context in
            image.draw(at: .zero)
            let cg = context.cgContext
            cg.setLineWidth(2)
            cg.setStrokeColor(UIColor.systemBlue.cgColor)
            for rectangle in ridgeRectangles {
                let points = rectangle.corners.map { snapshot.mkSnapshot.point(for: $0.clCoordinate) }
                guard points.count == 4 else { continue }
                cg.beginPath()
                cg.move(to: points[0])
                for point in points.dropFirst() { cg.addLine(to: point) }
                cg.closePath()
                cg.strokePath()
            }
            cg.setLineWidth(4)
            for (index, rectangle) in detections.enumerated() {
                let points = rectangle.corners.map { snapshot.mkSnapshot.point(for: $0.clCoordinate) }
                guard points.count == 4 else { continue }
                cg.setStrokeColor(UIColor.systemRed.cgColor)
                cg.beginPath()
                cg.move(to: points[0])
                for point in points.dropFirst() { cg.addLine(to: point) }
                cg.closePath()
                cg.strokePath()

                let center = points.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4)
                }
                let label = "#\(index + 1) \(Int(rectangle.lengthMeters))×\(Int(rectangle.widthMeters))m" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 28),
                    .foregroundColor: UIColor.systemRed,
                    .backgroundColor: UIColor(white: 0, alpha: 0.5)
                ]
                label.draw(at: CGPoint(x: center.x - 60, y: center.y - 16), withAttributes: attributes)
            }
        }
        guard let data = annotated.pngData() else { return "png encode failed" }
        try? data.write(to: url, options: .atomic)
        let base = detections.isEmpty ? "no detections" : "\(detections.count) detection(s)"
        // Attach ridge-search introspection so a 0-detection region shows WHY (orientation found,
        // candidates produced, and the gate breakdown for the strongest ones).
        let diagnostics = detector.ridgeSearchDiagnostics(snapshot: snapshot)
        return "\(base) :: \(diagnostics)"
    }

    // MARK: - Parsing & IO

    private static func parse(_ spec: String) -> [RegionSpec] {
        spec.split(separator: ";").enumerated().compactMap { index, rawEntry in
            let fields = rawEntry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let name: String
            let numbers: [String]
            if fields.count == 4 {
                name = fields[0]
                numbers = Array(fields[1...])
            } else if fields.count == 3 {
                name = "region\(index)"
                numbers = fields
            } else {
                return nil
            }
            guard let lat = Double(numbers[0]), let lon = Double(numbers[1]), let span = Double(numbers[2]) else {
                return nil
            }
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            )
            return RegionSpec(name: name, region: region)
        }
    }

    private static func resolveOutputDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment[outputEnvKey] {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        if let shared = environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] {
            return URL(fileURLWithPath: shared, isDirectory: true).appendingPathComponent("DetectorValidation")
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("DetectorValidation")
    }

    private static func writeResults(_ results: [RegionResult], to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(results) {
            try? data.write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        }
        // Sentinel the UI test polls for so it never waits on a run that already finished.
        try? Data("done".utf8).write(to: directory.appendingPathComponent("DONE"), options: .atomic)
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

/// Tiny mutual-exclusion box so `bootstrapIfRequested` starts the run exactly once even if several
/// detectors are constructed concurrently during launch.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
#endif
