// DiagnosticArchiveImport.swift
// MatchTracker
//
// DEBUG-only import side of the diagnostic archive (see DiagnosticArchive.swift for the format),
// plus the Settings › Developer UI controls and the headless launch path.
//
// Import recreates the source device's world INSIDE a simulator:
//   • fields.json in the app group is recreated from the archive's field database.
//   • For each match, the REAL data is written back into HealthKit on the sim — an HKWorkout with
//     its GPS route + heart-rate samples via the same builder APIs DemoMatchFactory uses (real
//     timestamps, real coordinates) — and the MatchRecord is written to the app group, so
//     MatchStore.refresh() discovers everything exactly as it would in production.
//
// IDEMPOTENCY. A rebuilt workout is assigned a FRESH HealthKit UUID (HealthKit owns UUID
// assignment), so the original source UUID is stashed in the rebuilt workout's metadata under
// `DiagnosticArchive.sourceUUIDMetadataKey`. Re-importing the same archive skips any match whose
// original UUID is already present that way. Because the record's `id` must equal the (new)
// workout UUID for MatchStore to join them, each imported record's `id` is remapped from the
// original workout UUID to the freshly assigned one; every other field is preserved verbatim.
//
// Compiled out of Release builds.

#if DEBUG
import Foundation
import Compression
import CoreLocation
import HealthKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MatchTrackerKit

enum DiagnosticArchiveImport {

    struct Summary: Equatable {
        var imported = 0
        var skipped = 0
        var failed = 0
        var fieldsImported = 0
        var manifest: String = ""

        var caption: String {
            "\(imported) imported, \(skipped) skipped, \(failed) failed · \(fieldsImported) fields"
        }
    }

    // MARK: - Import

    /// Read the archive at `url` and reconstruct fields + matches. Idempotent: matches already
    /// present (by original workout UUID) are skipped. `progress` receives a 0…1 fraction.
    /// Returns counts of imported / skipped / failed matches.
    @discardableResult
    static func importArchive(
        from url: URL,
        healthKit: HealthKitService,
        fieldsDirectory: URL = AppGroup.fieldsDirectory,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> Summary {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DiagnosticArchive.ArchiveError.couldNotOpenInputFile
        }
        defer { try? handle.close() }

        // Decompressing filter pulls compressed bytes from the file on demand.
        let filter = try InputFilter(.decompress, using: .lzfse) { (length: Int) -> Data? in
            let data = handle.readData(ofLength: length)
            return data.isEmpty ? nil : data
        }

        // Which original workout UUIDs are already imported (idempotency), read from the metadata
        // stash on previously rebuilt workouts.
        var alreadyImported = try await existingSourceUUIDs(healthKit: healthKit)

        var summary = Summary()
        let decoder = MatchTrackerJSON.decoder()
        var expectedMatches = 0
        var seenMatches = 0

        // Stream decompressed bytes, split on newlines, and process each JSONL record as it lands so
        // we never hold the whole corpus in memory.
        var pending = Data()
        func drainLines(final: Bool) async throws {
            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newlineIndex])
                pending.removeSubrange(pending.startIndex...newlineIndex)
                try await process(line)
            }
            if final, !pending.isEmpty {
                let line = pending
                pending = Data()
                try await process(line)
            }
        }

        func process(_ line: Data) async throws {
            guard !line.isEmpty, let kind = DiagnosticArchive.kind(ofLine: line) else { return }
            switch kind {
            case DiagnosticRecordKind.manifest:
                if let manifest = try? decoder.decode(DiagnosticManifest.self, from: line) {
                    expectedMatches = manifest.matchCount
                    summary.manifest = "v\(manifest.formatVersion) · \(manifest.matchCount) matches · "
                        + "\(manifest.fieldCount) fields · \(manifest.environment.systemVersion)"
                    MatchLog.info("Diagnostics import: manifest \(summary.manifest)", category: "diagnostics")
                }
            case DiagnosticRecordKind.fields:
                if let payload = try? decoder.decode(DiagnosticFields.self, from: line) {
                    summary.fieldsImported = recreateFields(payload.fields, directory: fieldsDirectory)
                    MatchLog.info("Diagnostics import: recreated \(summary.fieldsImported) fields", category: "diagnostics")
                }
            case DiagnosticRecordKind.match:
                guard let match = try? decoder.decode(DiagnosticMatch.self, from: line) else {
                    summary.failed += 1
                    return
                }
                seenMatches += 1
                do {
                    let outcome = try await importMatch(match, healthKit: healthKit, alreadyImported: &alreadyImported)
                    switch outcome {
                    case .imported: summary.imported += 1
                    case .skipped: summary.skipped += 1
                    }
                } catch {
                    summary.failed += 1
                    MatchLog.error("Diagnostics import: match \(match.metadata.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)",
                                   category: "diagnostics")
                }
                progress(Double(seenMatches) / Double(max(expectedMatches, seenMatches, 1)))
            default:
                break
            }
        }

        while let chunk = try filter.readData(ofLength: 1 << 16), !chunk.isEmpty {
            pending.append(chunk)
            try await drainLines(final: false)
        }
        try await drainLines(final: true)

        MatchLog.info("Diagnostics import complete: \(summary.caption)", category: "diagnostics")
        return summary
    }

    private enum MatchOutcome { case imported, skipped }

    /// Recreate one match. Skips (idempotent) if its original UUID is already imported.
    private static func importMatch(
        _ match: DiagnosticMatch,
        healthKit: HealthKitService,
        alreadyImported: inout Set<UUID>
    ) async throws -> MatchOutcome {
        let originalUUID = match.metadata.uuid

        // Record-only orphan: no HKWorkout to rebuild. Restore the record as-is (keeps its id), so
        // it round-trips as an orphan. Idempotent by record-file existence.
        guard match.metadata.hasWorkout else {
            if let record = match.record {
                let url = AppGroup.matchRecordURL(for: record.id)
                if FileManager.default.fileExists(atPath: url.path) { return .skipped }
                try writeRecord(record)
                return .imported
            }
            return .skipped
        }

        if alreadyImported.contains(originalUUID) { return .skipped }

        try await requestWriteAuthorization(healthKit: healthKit)
        let newUUID = try await buildWorkout(match, healthKit: healthKit)
        alreadyImported.insert(originalUUID)

        // Remap the record onto the freshly assigned workout UUID so MatchStore joins them.
        if let record = match.record {
            let remapped = MatchRecord(
                id: newUUID,
                startDate: record.startDate,
                endDate: record.endDate,
                fieldID: record.fieldID,
                events: record.events,
                teamCode: record.teamCode,
                sportID: record.sportID,
                headings: record.headings,
                format: record.format,
                reportedPositions: record.reportedPositions
            )
            try writeRecord(remapped)
        }
        return .imported
    }

    // MARK: - HealthKit reconstruction

    /// Rebuild an HKWorkout (+ route + heart rate) from a diagnostic match. Returns the freshly
    /// assigned workout UUID. Mirrors DemoMatchFactory's builder usage; the original source UUID is
    /// stashed in workout metadata for idempotency.
    private static func buildWorkout(_ match: DiagnosticMatch, healthKit: HealthKitService) async throws -> UUID {
        let meta = match.metadata

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .soccer
        configuration.locationType = meta.isIndoor ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(healthStore: healthKit.healthStore,
                                       configuration: configuration, device: .local())
        try await builder.beginCollection(at: meta.startDate)

        var samples: [HKSample] = []

        let heartRateType = HKQuantityType(.heartRate)
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        for sample in match.heartRate {
            samples.append(HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: heartRateUnit, doubleValue: sample.bpm),
                start: sample.timestamp, end: sample.timestamp
            ))
        }

        // Total distance / energy are restored as single workout-spanning samples so the workout's
        // summary statistics (the Matches-row distance, the detail headline) match the source. The
        // per-time detail analytics come from the GPS route + HR series, which are reproduced fully.
        if let distance = meta.totalDistanceMeters, distance > 0, meta.endDate > meta.startDate {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                start: meta.startDate, end: meta.endDate
            ))
        }
        if let energy = meta.totalEnergyKilocalories, energy > 0, meta.endDate > meta.startDate {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.activeEnergyBurned),
                quantity: HKQuantity(unit: .largeCalorie(), doubleValue: energy),
                start: meta.startDate, end: meta.endDate
            ))
        }

        if !samples.isEmpty { try await add(samples, to: builder) }
        try await builder.endCollection(at: meta.endDate)
        try await addMetadata([DiagnosticArchive.sourceUUIDMetadataKey: meta.uuid.uuidString], to: builder)

        guard let workout = try await builder.finishWorkout() else {
            throw DiagnosticArchive.ArchiveError.workoutFinishFailed
        }

        // Attach the GPS route (chunked to stay under insert limits). Indoor sessions have none.
        if !match.route.isEmpty {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthKit.healthStore, device: .local())
            let locations = match.route.map(\.clLocation)
            for start in stride(from: 0, to: locations.count, by: 250) {
                let slice = Array(locations[start..<min(start + 250, locations.count)])
                try await routeBuilder.insertRouteData(slice)
            }
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
        }
        return workout.uuid
    }

    /// Original source UUIDs already reconstructed on this store (idempotency key), read from the
    /// metadata stash on previously imported workouts.
    private static func existingSourceUUIDs(healthKit: HealthKitService) async throws -> Set<UUID> {
        let workouts = try await healthKit.fetchSoccerWorkouts()
        var result: Set<UUID> = []
        for workout in workouts {
            if let stored = workout.metadata?[DiagnosticArchive.sourceUUIDMetadataKey] as? String,
               let uuid = UUID(uuidString: stored) {
                result.insert(uuid)
            }
        }
        return result
    }

    private static func requestWriteAuthorization(healthKit: HealthKitService) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw DemoErrorBridge.healthDataUnavailable
        }
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning)
        ]
        try await healthKit.healthStore.requestAuthorization(toShare: share, read: share)
    }

    private static func add(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.add(samples) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func addMetadata(_ metadata: [String: Any], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addMetadata(metadata) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - Fields / records on disk

    /// Recreate fields.json from the archive's field list, merging by id (idempotent). Returns the
    /// number of fields written.
    private static func recreateFields(_ fields: [FieldModel], directory: URL) -> Int {
        let store = FieldStore(directory: directory)
        try? store.load()
        for field in fields { try? store.save(field) }
        return fields.count
    }

    private static func writeRecord(_ record: MatchRecord) throws {
        let encoder = MatchTrackerJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: AppGroup.matchRecordURL(for: record.id), options: .atomic)
    }

    private enum DemoErrorBridge: LocalizedError {
        case healthDataUnavailable
        var errorDescription: String? { "HealthKit is unavailable on this device." }
    }

    // MARK: - Headless launch path

    /// Launch argument (NSArgumentDomain boolean): `-ImportDiagnostics YES`. When present, look for
    /// `diagnostics-import.matchtrackerdiag` in the app container's Documents directory (a developer
    /// drops it there via `xcrun simctl get_app_container booted <bundle id> data`), import it, and
    /// log progress via MatchLog. Runs once at launch.
    static let headlessLaunchKey = "ImportDiagnostics"

    /// Invoked from app bootstrap. No-op unless the launch argument is set. Refreshes the passed
    /// stores afterward so imported matches/fields appear without another launch.
    static func runHeadlessIfRequested(healthKit: HealthKitService, onComplete: @escaping @Sendable () async -> Void) async {
        guard UserDefaults.standard.bool(forKey: headlessLaunchKey) else { return }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent(DiagnosticArchive.headlessImportFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            MatchLog.error("Diagnostics headless import: no archive at \(url.path)", category: "diagnostics")
            return
        }

        MatchLog.info("Diagnostics headless import: reading \(url.lastPathComponent)", category: "diagnostics")
        do {
            let summary = try await importArchive(from: url, healthKit: healthKit) { fraction in
                if Int(fraction * 100) % 25 == 0 {
                    MatchLog.info("Diagnostics headless import: \(Int(fraction * 100))%", category: "diagnostics")
                }
            }
            MatchLog.info("Diagnostics headless import done: \(summary.caption)", category: "diagnostics")
            await onComplete()
        } catch {
            MatchLog.error("Diagnostics headless import failed: \(error.localizedDescription)", category: "diagnostics")
        }
    }
}

// MARK: - Settings › Developer controls

/// Export / Import rows mounted inside SettingsView's DEBUG Developer section. Owns its own
/// progress + result state so the SettingsView edit stays a single call site.
struct DiagnosticArchiveControls: View {
    let healthKit: HealthKitService
    /// Snapshots taken on tap (both are @MainActor state elsewhere).
    let summariesProvider: () -> [MatchSummary]
    let fieldsProvider: () -> [FieldModel]
    let settingsSnapshot: () -> AnalysisSettingsSnapshot
    let onImported: () async -> Void

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var progress = 0.0
    @State private var message: String?
    @State private var exportedURL: URL?
    @State private var showingShare = false
    @State private var showingFileImporter = false

    var body: some View {
        Group {
            Button {
                export()
            } label: {
                Label("Export Diagnostic Archive", systemImage: "shippingbox.and.arrow.backward")
            }
            .disabled(isExporting || isImporting)

            Button {
                showingFileImporter = true
            } label: {
                Label("Import Diagnostic Archive", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(isExporting || isImporting)

            if isExporting || isImporting {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Contains your GPS tracks and heart-rate data.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingShare) {
            if let exportedURL {
                DiagnosticShareSheet(items: [exportedURL])
            }
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.data, .item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { performImport(url) }
            case .failure(let error): message = "Import cancelled: \(error.localizedDescription)"
            }
        }
    }

    private func export() {
        isExporting = true
        progress = 0
        message = nil
        let summaries = summariesProvider()
        let fields = fieldsProvider()
        let settings = settingsSnapshot()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTracker-\(Date().formatted(.iso8601.year().month().day())).\(DiagnosticArchive.fileExtension)")
        Task {
            do {
                try await DiagnosticArchive.export(
                    summaries: summaries, fields: fields, settings: settings,
                    healthKit: healthKit, to: url
                ) { fraction in Task { @MainActor in progress = fraction } }
                await MainActor.run {
                    exportedURL = url
                    message = "Exported \(summaries.count) matches, \(fields.count) fields."
                    isExporting = false
                    showingShare = true
                }
            } catch {
                await MainActor.run {
                    message = "Export failed: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }

    private func performImport(_ url: URL) {
        isImporting = true
        progress = 0
        message = nil
        Task {
            // Security-scoped access for a file picked outside the app container.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await DiagnosticArchiveImport.importArchive(
                    from: url, healthKit: healthKit
                ) { fraction in Task { @MainActor in progress = fraction } }
                await onImported()
                await MainActor.run {
                    message = summary.caption
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    message = "Import failed: \(error.localizedDescription)"
                    isImporting = false
                }
            }
        }
    }
}

/// Minimal UIActivityViewController wrapper for sharing the exported archive file.
private struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
