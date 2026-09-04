// NearbyFieldSeeder.swift
// MatchTracker

import Foundation
import CoreLocation
import MapKit
import Observation
import MatchTrackerKit

/// On-device community field seeding (V2 §8, phase 1). Tiles the area around a location into
/// ~600 m squares, runs the existing `SatelliteFieldDetector` on each un-scanned tile, dedupes the
/// detections against known fields and prior seeds, then (a) contributes them to the community
/// field database as low-confidence satellite seeds and (b) publishes them as proposals the Fields
/// tab can offer for the personal list. Imagery licensing is a non-issue here: `MKMapSnapshotter`
/// is ordinary MapKit usage. Best-effort throughout; nothing here ever blocks the UI.
@Observable
@MainActor
final class NearbyFieldSeeder: NSObject {
    /// True while a seed pass is running.
    private(set) var isScanning = false
    /// Tiles completed so far in the current pass.
    private(set) var scannedTiles = 0
    /// Tiles the current pass will scan (recently-scanned tiles are skipped and not counted).
    private(set) var totalTiles = 0
    /// Freshly detected pitches for the Fields tab to render and offer as proposals.
    private(set) var proposals: [OrientedRectangle] = []

    private let fields: FieldsModel
    private let uploads: UploadService
    private let settings: SettingsStore

    @ObservationIgnored private let detector = SatelliteFieldDetector()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    @ObservationIgnored private var wantsLocation = false
    @ObservationIgnored private var scanTask: Task<[OrientedRectangle], Never>?
    @ObservationIgnored private var log = SeedLog()

    // Tuning.
    private let searchRadius: Double = 1500     // meters from center to tile
    private let tileSize: Double = 600          // meters per square tile
    private let dedupeMeters: Double = 40       // near-duplicate threshold
    private let rescanInterval: TimeInterval = 30 * 24 * 60 * 60  // skip tiles scanned within 30 days
    private let gridStep = 0.005                // ~556 m scanned-log grid

    init(fields: FieldsModel, uploads: UploadService, settings: SettingsStore) {
        self.fields = fields
        self.uploads = uploads
        self.settings = settings
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        loadLog()
    }

    /// Whether location access is already granted (so an automatic pass can run without prompting).
    var isLocationAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    // MARK: - Entry points

    /// Resolve the current location (requesting when-in-use access if needed) and seed around it.
    func seedAroundCurrentLocation() async {
        guard !isScanning else { return }
        guard let coordinate = await currentCoordinate() else { return }
        await seed(around: Coordinate2D(coordinate))
    }

    /// Tile the area around a coordinate and scan every un-scanned tile serially.
    func seed(around center: Coordinate2D) async {
        guard !isScanning else { return }
        let tiles = pendingTiles(around: center)
        guard !tiles.isEmpty else {
            proposals = []
            return
        }

        isScanning = true
        scannedTiles = 0
        totalTiles = tiles.count
        defer {
            isScanning = false
            scanTask = nil
        }

        let task = Task { () -> [OrientedRectangle] in
            var detections: [OrientedRectangle] = []
            for tile in tiles {
                if Task.isCancelled { break }
                let found = await detector.detectFields(in: tile.region)
                markScanned(tile.key)
                detections.append(contentsOf: found)
                scannedTiles += 1
            }
            return detections
        }
        scanTask = task
        let detections = await task.value
        saveLog()

        let fresh = dedupe(detections)
        proposals = fresh

        guard !fresh.isEmpty else { return }
        let seeds = fresh.map { rectangle in
            FieldModel(id: UUID(), name: "Detected field", createdAt: Date(), outline: [],
                       rectangle: rectangle, source: .satellite, observationCount: 0)
        }
        // Only remember contributed seeds when the toggle is on, so a later pass can re-propose
        // fields the user chose not to share.
        if settings.contributeDetectedFields {
            log.seededCenters.append(contentsOf: fresh.map(\.center))
            saveLog()
        }
        await uploads.contributeSeeds(seeds)
    }

    /// Cancel an in-flight seed pass. Tiles already scanned stay logged.
    func cancel() {
        scanTask?.cancel()
    }

    /// Clear the scanned-region + contributed-seed log (debugging).
    func resetLog() {
        log = SeedLog()
        try? FileManager.default.removeItem(at: Self.logURL)
    }

    // MARK: - Tiling

    private struct Tile {
        let key: String
        let region: MKCoordinateRegion
    }

    private func pendingTiles(around center: Coordinate2D) -> [Tile] {
        let frame = ENUFrame(reference: center)
        var tiles: [Tile] = []
        var seenKeys = Set<String>()
        let step = tileSize
        var north = -searchRadius
        while north <= searchRadius {
            var east = -searchRadius
            while east <= searchRadius {
                defer { east += step }
                // Trim tiles whose center falls outside the search radius (keep it roughly circular).
                guard hypot(east, north) <= searchRadius + tileSize / 2 else { continue }
                let tileCenter = frame.unproject(CGPoint(x: east, y: north))
                let key = gridKey(for: tileCenter)
                guard seenKeys.insert(key).inserted else { continue }
                guard !recentlyScanned(key) else { continue }
                tiles.append(Tile(key: key, region: region(around: tileCenter)))
            }
            north += step
        }
        return tiles
    }

    private func region(around center: Coordinate2D) -> MKCoordinateRegion {
        let frame = ENUFrame(reference: center)
        return MKCoordinateRegion(
            center: center.clCoordinate,
            span: MKCoordinateSpan(
                latitudeDelta: tileSize / metersPerDegreeLatitude,
                longitudeDelta: tileSize / max(frame.metersPerDegreeLongitude, 1)
            )
        )
    }

    // MARK: - Dedupe

    private func dedupe(_ detections: [OrientedRectangle]) -> [OrientedRectangle] {
        let knownCenters = fields.fields.map(\.rectangle.center) + log.seededCenters
        var kept: [OrientedRectangle] = []
        for detection in detections {
            if knownCenters.contains(where: { metersBetween($0, detection.center) < dedupeMeters }) { continue }
            if kept.contains(where: { metersBetween($0.center, detection.center) < dedupeMeters }) { continue }
            kept.append(detection)
        }
        return kept
    }

    private func metersBetween(_ a: Coordinate2D, _ b: Coordinate2D) -> Double {
        let point = ENUFrame(reference: a).project(b)
        return hypot(Double(point.x), Double(point.y))
    }

    // MARK: - Scanned-region log

    private struct SeedLog: Codable {
        var scannedTiles: [String: Date] = [:]
        var seededCenters: [Coordinate2D] = []
    }

    private static let logURL = AppGroup.containerURL.appendingPathComponent("nearby-seed-log.json")

    private func gridKey(for coordinate: Coordinate2D) -> String {
        let latKey = (coordinate.latitude / gridStep).rounded()
        let lonKey = (coordinate.longitude / gridStep).rounded()
        return "\(Int(latKey)):\(Int(lonKey))"
    }

    private func recentlyScanned(_ key: String) -> Bool {
        guard let date = log.scannedTiles[key] else { return false }
        return Date().timeIntervalSince(date) < rescanInterval
    }

    private func markScanned(_ key: String) {
        log.scannedTiles[key] = Date()
    }

    private func loadLog() {
        guard let data = try? Data(contentsOf: Self.logURL),
              let decoded = try? MatchTrackerJSON.decoder().decode(SeedLog.self, from: data) else { return }
        log = decoded
    }

    private func saveLog() {
        guard let data = try? MatchTrackerJSON.encoder().encode(log) else { return }
        try? data.write(to: Self.logURL, options: .atomic)
    }

    // MARK: - One-shot location

    private func currentCoordinate() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            switch locationManager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                locationManager.requestLocation()
            case .notDetermined:
                wantsLocation = true
                locationManager.requestWhenInUseAuthorization()
            default:
                resumeLocation(nil)
            }
        }
    }

    private func resumeLocation(_ coordinate: CLLocationCoordinate2D?) {
        locationContinuation?.resume(returning: coordinate)
        locationContinuation = nil
    }
}

// MARK: - CLLocationManagerDelegate

extension NearbyFieldSeeder: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsLocation else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            wantsLocation = false
            manager.requestLocation()
        case .notDetermined:
            break
        default:
            wantsLocation = false
            resumeLocation(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resumeLocation(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resumeLocation(nil)
    }
}
