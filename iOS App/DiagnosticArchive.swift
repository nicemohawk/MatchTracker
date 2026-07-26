// DiagnosticArchive.swift
// MatchTracker
//
// DEBUG-only diagnostic export/import. A real player with hundreds of matches in HealthKit can
// export their FULL match history from their device as one `.matchtrackerdiag` file and share it;
// a developer loads that file into a SIMULATOR so every analysis bug reproduces against the real
// data (real GPS routes, real heart rate, the real MatchRecords and fields).
//
// FORMAT — `.matchtrackerdiag`
// ---------------------------
// A single file that is an LZFSE-compressed stream (Apple's `Compression` framework — the only
// public compression API on iOS) of newline-delimited JSON records (JSONL). One JSON object per
// line, each self-contained, streamed out and back in one record at a time so neither side has to
// hold the whole ~100 MB corpus in memory:
//
//   line 1: { "kind": "manifest", … }   format version, app/device info, analysis settings snapshot
//   line 2: { "kind": "fields",   … }   the complete FieldStore (all FieldModel JSON)
//   line 3…: { "kind": "match",   … }   one per soccer workout MatchStore knows (workout metadata +
//                                       full GPS route + heart-rate series + MatchRecord when present)
//
// All dates are ISO-8601 (MatchTrackerJSON), matching the on-disk record/field JSON. Records carry
// only anonymized, analysis-relevant data: no API key, no keychain, no player name (see
// `AnalysisSettingsSnapshot`). The GPS tracks and heart rate ARE the payload, by design — the UI
// says so before the user shares.
//
// The whole file is compiled out of Release builds.

#if DEBUG
import Foundation
import Compression
import CoreLocation
import HealthKit
import MatchTrackerKit

// MARK: - On-wire record types

/// One JSONL line's discriminator, peeked before decoding the concrete record.
private struct RecordKind: Decodable { let kind: String }

enum DiagnosticRecordKind {
    static let manifest = "manifest"
    static let fields = "fields"
    static let match = "match"
    static let journal = "journal"
}

/// One device's lifecycle journal (raw JSONL lines from MatchLog's persistent sink) — the
/// "what actually happened" timeline that lets a session be reconstructed from an export.
/// Import ignores this kind; it exists for the humans (and tools) reading the archive.
struct DiagnosticJournal: Codable {
    var kind = DiagnosticRecordKind.journal
    var device: String
    var entries: [String]
}

/// First line of the archive: what produced it and the environment it came from.
struct DiagnosticManifest: Codable {
    var kind = DiagnosticRecordKind.manifest
    var formatVersion: Int
    var createdAt: Date
    var matchCount: Int
    var fieldCount: Int
    var environment: EnvironmentSnapshot
    var settings: AnalysisSettingsSnapshot
}

/// App build + device/OS the archive was captured on. Purely informational (helps a developer
/// reproduce against the right OS/units), never used to gate import.
struct EnvironmentSnapshot: Codable {
    var appVersion: String
    var appBuild: String
    var systemName: String
    var systemVersion: String
    var deviceModelIdentifier: String
    var deviceModelName: String
}

/// The ONLY settings included — anonymized and limited to what can affect analysis or unit display.
/// Deliberately omits API key, keychain, player name, team code, and anything personally
/// identifying. There are currently no analysis-behaviour toggles in `SettingsStore`, so this is
/// mostly locale/units context plus the one community-contribution behaviour flag.
struct AnalysisSettingsSnapshot: Codable {
    var measurementSystem: String       // "metric" | "us" | "uk" — distance/speed display units
    var localeIdentifier: String
    var contributeDetectedFields: Bool

    /// Snapshot the current locale/units plus the one behaviour flag. No personal or secret values.
    static func current(contributeDetectedFields: Bool) -> AnalysisSettingsSnapshot {
        let system: String
        switch Locale.current.measurementSystem {
        case .metric: system = "metric"
        case .us: system = "us"
        case .uk: system = "uk"
        default: system = Locale.current.measurementSystem.identifier
        }
        return AnalysisSettingsSnapshot(
            measurementSystem: system,
            localeIdentifier: Locale.current.identifier,
            contributeDetectedFields: contributeDetectedFields
        )
    }
}

/// The complete field database.
struct DiagnosticFields: Codable {
    var kind = DiagnosticRecordKind.fields
    var fields: [FieldModel]
}

/// One workout MatchStore knows about, fully self-contained.
struct DiagnosticMatch: Codable {
    var kind = DiagnosticRecordKind.match
    var metadata: WorkoutMetadata
    var route: [RoutePoint]
    var heartRate: [DiagnosticHeartRateSample]
    /// The MatchRecord JSON when one exists (events, format, fieldID, reportedPositions, teamCode).
    /// Nil for a workout-only match with no received record.
    var record: MatchRecord?
}

/// HKWorkout metadata captured at export. `uuid` is the ORIGINAL workout UUID on the source device;
/// it survives as the import idempotency key (a rebuilt workout gets a fresh HK UUID, so the
/// original is stashed in the rebuilt workout's metadata — see `DiagnosticArchiveImport`).
struct WorkoutMetadata: Codable {
    var uuid: UUID
    var startDate: Date
    var endDate: Date
    var totalDistanceMeters: Double?
    var totalEnergyKilocalories: Double?
    var sourceName: String?
    var deviceName: String?
    var deviceModel: String?
    var isIndoor: Bool
    /// False for a record-only "orphan" match that has no HKWorkout to rebuild — its record is
    /// restored as-is so it round-trips as an orphan exactly like on the source device.
    var hasWorkout: Bool
}

/// One GPS fix. Mirrors every field HealthKit stores on a route location so the route reconstructs
/// losslessly (TrackPoint drops altitude/verticalAccuracy, so we capture CLLocation fields directly).
struct RoutePoint: Codable {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var speed: Double           // m/s, negative if invalid
    var course: Double          // degrees, negative if invalid
    var altitude: Double
}

/// One heart-rate sample (bpm at a timestamp).
struct DiagnosticHeartRateSample: Codable {
    var timestamp: Date
    var bpm: Double
}

// MARK: - Archive namespace

enum DiagnosticArchive {
    static let fileExtension = "matchtrackerdiag"
    static let formatVersion = 1

    /// HKWorkout metadata key that stashes the original (source-device) workout UUID on a rebuilt
    /// workout, so re-importing the same archive is idempotent (see the importer).
    static let sourceUUIDMetadataKey = "MTDiagnosticSourceUUID"

    /// Default filename a developer drops into the app container for the headless import path.
    static let headlessImportFilename = "diagnostics-import.\(fileExtension)"

    /// Launch argument (NSArgumentDomain boolean) `-ExportDiagnostics YES`: on launch, export every
    /// known match to `Documents/diagnostics-export.matchtrackerdiag` and log the path. Symmetric
    /// with `-ImportDiagnostics`; lets a developer capture an archive from a booted sim/device
    /// headlessly (also drives the round-trip test).
    static let headlessExportLaunchKey = "ExportDiagnostics"
    static let headlessExportFilename = "diagnostics-export.\(fileExtension)"

    /// No-op unless `-ExportDiagnostics YES` is set. Snapshots are taken by the caller on the main
    /// actor and passed in; the export itself runs off-actor.
    static func runHeadlessExportIfRequested(
        summaries: [MatchSummary],
        fields: [FieldModel],
        settings: AnalysisSettingsSnapshot,
        healthKit: HealthKitService
    ) async {
        guard UserDefaults.standard.bool(forKey: headlessExportLaunchKey) else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent(headlessExportFilename)
        MatchLog.info("Diagnostics headless export: \(summaries.count) matches → \(url.lastPathComponent)", category: "diagnostics")
        do {
            try await export(summaries: summaries, fields: fields, settings: settings, healthKit: healthKit, to: url) { fraction in
                if Int(fraction * 100) % 25 == 0 {
                    MatchLog.info("Diagnostics headless export: \(Int(fraction * 100))%", category: "diagnostics")
                }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            MatchLog.info("Diagnostics headless export complete: \(size ?? -1) bytes", category: "diagnostics")
        } catch {
            MatchLog.error("Diagnostics headless export failed: \(error.localizedDescription)", category: "diagnostics")
        }
    }

    enum ArchiveError: LocalizedError {
        case couldNotOpenOutputStream
        case couldNotOpenInputFile
        case workoutFinishFailed

        var errorDescription: String? {
            switch self {
            case .couldNotOpenOutputStream: return "Couldn't open the archive file for writing."
            case .couldNotOpenInputFile: return "Couldn't open the archive file for reading."
            case .workoutFinishFailed: return "Couldn't rebuild a workout in HealthKit."
            }
        }
    }

    // MARK: - Export

    /// Build a diagnostic archive at `url` covering every summary in `summaries`. Runs off the main
    /// actor; the caller snapshots the (main-actor) match list and field list first. `progress` is
    /// called on an arbitrary queue with a 0…1 fraction as each match is written.
    static func export(
        summaries: [MatchSummary],
        fields: [FieldModel],
        settings: AnalysisSettingsSnapshot,
        healthKit: HealthKitService,
        to url: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let stream = OutputStream(url: url, append: false) else {
            throw ArchiveError.couldNotOpenOutputStream
        }
        stream.open()
        defer { stream.close() }

        // LZFSE compressing filter: hands us compressed chunks as records are written; we drain them
        // straight to the file so peak memory stays at roughly one match plus a small buffer.
        let filter = try OutputFilter(.compress, using: .lzfse) { (chunk: Data?) in
            if let chunk, !chunk.isEmpty { writeFully(chunk, to: stream) }
        }

        let encoder = MatchTrackerJSON.encoder()

        // 1. Manifest.
        let manifest = DiagnosticManifest(
            formatVersion: formatVersion,
            createdAt: Date(),
            matchCount: summaries.count,
            fieldCount: fields.count,
            environment: EnvironmentSnapshot.current(),
            settings: settings
        )
        try writeLine(manifest, encoder: encoder, to: filter)

        // 2. Fields.
        try writeLine(DiagnosticFields(fields: fields), encoder: encoder, to: filter)

        // 2b. Lifecycle journals — this phone's and the last-received watch snapshot. Capped to
        // the newest lines so a long-lived journal can't bloat the archive.
        MatchLog.flushJournal()
        for (device, fileName) in [("phone", "journal-phone.jsonl"), ("watch", "journal-watch.jsonl")] {
            let url = AppGroup.containerURL.appendingPathComponent(fileName)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let entries = contents.split(separator: "\n").suffix(4000).map(String.init)
            guard !entries.isEmpty else { continue }
            try writeLine(DiagnosticJournal(device: device, entries: entries), encoder: encoder, to: filter)
        }

        // 3. One line per match.
        for (index, summary) in summaries.enumerated() {
            let match = try await collect(summary: summary, healthKit: healthKit)
            try writeLine(match, encoder: encoder, to: filter)
            progress(Double(index + 1) / Double(max(summaries.count, 1)))
        }

        try filter.finalize()
    }

    /// Gather everything for one match: workout metadata, full GPS route, heart-rate series, record.
    private static func collect(summary: MatchSummary, healthKit: HealthKitService) async throws -> DiagnosticMatch {
        guard let workout = summary.workout else {
            // Record-only orphan: no HKWorkout, so no route/HR to fetch — restore the record only.
            let record = summary.record
            let metadata = WorkoutMetadata(
                uuid: summary.id,
                startDate: record?.startDate ?? summary.startDate,
                endDate: record?.endDate ?? summary.startDate,
                totalDistanceMeters: nil, totalEnergyKilocalories: nil,
                sourceName: nil, deviceName: nil, deviceModel: nil,
                isIndoor: record?.format == .indoor, hasWorkout: false
            )
            return DiagnosticMatch(metadata: metadata, route: [], heartRate: [], record: record)
        }

        let locations = (try? await fetchRouteLocations(for: workout, healthKit: healthKit)) ?? []
        let route = locations.map(RoutePoint.init(location:))
        let hrSeries = (try? await healthKit.fetchHeartRateSeries(from: workout.startDate, to: workout.endDate)) ?? []
        let heartRate = hrSeries.map { DiagnosticHeartRateSample(timestamp: $0.date, bpm: $0.bpm) }

        let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter())
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .largeCalorie())
        let isIndoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? locations.isEmpty

        let metadata = WorkoutMetadata(
            uuid: workout.uuid,
            startDate: workout.startDate,
            endDate: workout.endDate,
            totalDistanceMeters: distance,
            totalEnergyKilocalories: energy,
            sourceName: workout.sourceRevision.source.name,
            deviceName: workout.device?.name,
            deviceModel: workout.device?.model,
            isIndoor: isIndoor,
            hasWorkout: true
        )
        // The archive already carries the lossless route; strip the record's redundant track copy
        // so route bytes don't ship twice per match. (Kept when there's no HK route — then the
        // record's track IS the only GPS.)
        var record = summary.record
        if !route.isEmpty {
            record?.track = nil
        }
        return DiagnosticMatch(metadata: metadata, route: route, heartRate: heartRate, record: record)
    }

    /// Raw route CLLocations for a workout (with altitude / accuracy / speed / course intact),
    /// time-ordered. Mirrors `HealthKitService`'s private route path but keeps the full location.
    private static func fetchRouteLocations(for workout: HKWorkout, healthKit: HealthKitService) async throws -> [CLLocation] {
        let routePredicate = HKQuery.predicateForObjects(from: workout)
        let route: HKWorkoutRoute? = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(), predicate: routePredicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKWorkoutRoute])?.first)
            }
            healthKit.healthStore.execute(query)
        }
        guard let route else { return [] }

        let locations: [CLLocation] = try await withCheckedThrowingContinuation { continuation in
            var accumulated: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                if let error { continuation.resume(throwing: error); return }
                if let batch { accumulated.append(contentsOf: batch) }
                if done { continuation.resume(returning: accumulated) }
            }
            healthKit.healthStore.execute(query)
        }
        return locations.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Stream helpers

    /// Encode one record, append a newline delimiter, and hand it to the compressing filter.
    private static func writeLine<T: Encodable>(_ value: T, encoder: JSONEncoder, to filter: OutputFilter) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)   // '\n' — JSON escapes any interior newlines, so this only ends the line
        try filter.write(data)
    }

    /// Write all of `data` to `stream`, looping over partial writes.
    private static func writeFully(_ data: Data, to stream: OutputStream) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                let written = stream.write(pointer, maxLength: remaining)
                if written <= 0 { break }   // stream error / full — best effort in a diagnostic tool
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    /// Decode-time discriminator for a JSONL line.
    static func kind(ofLine line: Data) -> String? {
        try? JSONDecoder().decode(RecordKind.self, from: line).kind
    }
}

// MARK: - Convenience conversions

extension RoutePoint {
    init(location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed,
            course: location.course,
            altitude: location.altitude
        )
    }

    /// Rebuild a CLLocation carrying every captured field, for feeding an HKWorkoutRouteBuilder.
    var clLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: horizontalAccuracy > 0 ? 6 : -1,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }
}

extension EnvironmentSnapshot {
    static func current() -> EnvironmentSnapshot {
        let info = Bundle.main.infoDictionary
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        let process = ProcessInfo.processInfo
        return EnvironmentSnapshot(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            systemName: "iOS",
            systemVersion: process.operatingSystemVersionString,
            deviceModelIdentifier: identifier,
            deviceModelName: identifier
        )
    }
}

extension DiagnosticMatch: CustomStringConvertible {
    var description: String {
        "\(metadata.uuid.uuidString.prefix(8)) route=\(route.count) hr=\(heartRate.count) record=\(record != nil)"
    }
}
#endif
