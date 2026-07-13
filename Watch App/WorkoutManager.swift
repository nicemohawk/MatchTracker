//
//  WorkoutManager.swift
//  MatchTracker
//

import Foundation
import Observation
import HealthKit
import CoreLocation
import WatchKit
import WidgetKit
import MatchTrackerKit

/// High-level screen the watch app is showing. Drives root navigation.
enum MatchPhase: Equatable {
    case idle       // start screen
    case countdown  // 3-2-1 before the match
    case active     // live session (Controls / Metrics / Events tabs)
    case summary    // post-match summary
}

/// The outcome of ending a match, letting the UI distinguish a real finish (show the summary)
/// from a too-short session that was discarded without saving (return straight to the start).
enum MatchOutcome {
    case finished(workout: HKWorkout?, record: MatchRecord)
    case discardedTooShort
}

/// Owns the HealthKit workout session, live builder, route builder and location manager for a
/// single match, exactly like the legacy `WorkoutController` — modernized to SwiftUI/@Observable.
///
/// Publishes live metrics, the running event log and sub state; persists the in-progress
/// `MatchRecord` to the app group after every event for crash safety; and supports recovery of an
/// interrupted session on next launch.
@Observable
final class WorkoutManager: NSObject {
    static let shared = WorkoutManager()

    // MARK: Navigation / lifecycle state

    var phase: MatchPhase = .idle
    var sessionState: HKWorkoutSessionState = .notStarted
    var isAuthorized = false

    /// Field the start screen matched via a one-shot location lookup (shown before kickoff).
    var detectedField: FieldModel?

    // MARK: Live metrics (updated on the main queue)

    var heartRate: Double = 0
    var activeCalories: Double = 0          // kcal
    var distanceMeters: Double = 0
    var currentSpeed: Double = 0            // m/s, from recent GPS samples
    var elapsedAtPause: TimeInterval = 0    // snapshot for summary

    // MARK: Match content

    var events: [MatchEvent] = []
    var onPitch = true
    private(set) var track: [TrackPoint] = []

    /// Transient banner surfaced when an automatic substitution is detected (e.g. "Subbed out
    /// (auto)"). Set for a moment, then cleared; Metrics/Session overlays it briefly.
    var autoSubBanner: String?

    // MARK: Summary results (populated by endMatch)

    var finishedWorkout: HKWorkout?
    var finishedRecord: MatchRecord?
    var summaryAverageHeartRate: Double?
    var proposedField: FieldModel?

    // MARK: Match identity

    @ObservationIgnored private var matchID = UUID()
    @ObservationIgnored private var matchStartDate = Date()
    @ObservationIgnored private var fieldID: UUID?

    // MARK: HealthKit / location plumbing

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var recentLocations: [CLLocation] = []

    /// Geometry-first automatic substitution detector. Non-nil only when a field was resolved for
    /// this match (no field → no boundary to reason about → detection disabled, everything else
    /// works as before).
    @ObservationIgnored private var autoSubDetector: AutoSubDetector?

    /// Sensor-fusion heading samples and live sideline streaming, both active only during a match.
    @ObservationIgnored private let headingRecorder = HeadingRecorder()
    @ObservationIgnored private let liveStreamer = LiveStreamer()

    /// Built per match so the selected sport's activity type is honored.
    private func makeWorkoutConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        let sport = WatchSettings.sportProfile
        configuration.activityType = HKWorkoutActivityType(rawValue: UInt(sport.workoutActivityTypeRawValue)) ?? .soccer
        configuration.locationType = .outdoor
        return configuration
    }

    private override init() {
        super.init()
        locationManager.delegate = self
    }

    // MARK: - Derived values

    /// Running score as (us, them). A goal the wearer scored also counts for us.
    var score: (us: Int, them: Int) {
        var us = 0
        var them = 0
        for event in events {
            switch event.kind {
            case .goalForUs, .goalMine: us += 1
            case .goalAgainstUs: them += 1
            default: break
            }
        }
        return (us, them)
    }

    /// Count of the "notable" events surfaced in the Events tab.
    var loggedEventCount: Int {
        events.filter {
            switch $0.kind {
            case .flag, .goalForUs, .goalAgainstUs, .goalMine, .assist: return true
            default: return false
            }
        }.count
    }

    /// Live elapsed time at a given instant, driven by the builder so pauses are respected.
    func elapsedTime(at date: Date) -> TimeInterval {
        guard let builder else { return elapsedAtPause }
        return builder.elapsedTime(at: date)
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        let typesToShare: Set<HKSampleType> = [
            HKQuantityType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.heartRate)
        ]
        let typesToRead: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKObjectType.activitySummaryType()
        ]
        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
            isAuthorized = true
        } catch {
            isAuthorized = false
        }
        requestLocationAuthorization()
    }

    private func requestLocationAuthorization() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .fitness
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        }
    }

    // MARK: - Match lifecycle

    /// Configure and start the workout session for a match on an optional detected field.
    func startMatch(field: FieldModel?) async {
        resetForNewMatch(field: field)

        do {
            let configuration = makeWorkoutConfiguration()
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder
            self.routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())

            let start = Date()
            matchStartDate = start
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)

            startLocationUpdates()
            headingRecorder.start()
            liveStreamer.start { [weak self] in self?.makeLiveUpdate() }
            log(.matchStart, haptic: false)
            phase = .active
        } catch {
            // If we can't start, fall back to the start screen.
            MatchLog.error("Unable to start workout session: \(error.localizedDescription)", category: "workout")
            phase = .idle
        }
    }

    /// Snapshot of live state for the sideline stream; nil ends the current send quietly.
    @MainActor
    private func makeLiveUpdate() -> LiveMatchUpdate? {
        guard phase == .active else { return nil }
        let deltas = liveStreamer.deltas(track: track, events: events)
        let score = score
        let hasScore = score.us + score.them > 0
        return LiveMatchUpdate(
            sequence: liveStreamer.nextSequence,
            timestamp: Date(),
            elapsed: elapsedTime(at: Date()),
            heartRate: heartRate > 0 ? heartRate : nil,
            distanceMeters: distanceMeters,
            currentSpeed: currentSpeed > 0 ? currentSpeed : nil,
            onPitch: onPitch,
            latestPoints: deltas.points,
            newEvents: deltas.events,
            usGoals: hasScore ? score.us : nil,
            themGoals: hasScore ? score.them : nil
        )
    }

    func pause() {
        session?.pause()
    }

    func resume() {
        session?.resume()
    }

    /// Toggle the wearer's on-pitch state, logging a manual sub event with a strong haptic. Manual
    /// events win: the detector is re-synced and its auto output muted for the cooldown.
    func toggleSub() {
        onPitch.toggle()
        let event = MatchEvent(kind: onPitch ? .subIn : .subOut, date: Date(), source: .manual)
        autoSubDetector?.recordManualEvent(event)
        append(event, haptic: false)
        WKInterfaceDevice.current().play(.notification)
    }

    /// Append a manually-logged event, give feedback and persist the crash-safe record.
    func log(_ kind: MatchEventKind, note: String? = nil, haptic: Bool = true) {
        append(MatchEvent(kind: kind, date: Date(), note: note, source: .manual), haptic: haptic)
    }

    /// Append an already-built event (preserving its date and source), optionally give a success
    /// haptic, and persist the crash-safe record.
    private func append(_ event: MatchEvent, haptic: Bool) {
        events.append(event)
        if haptic {
            WKInterfaceDevice.current().play(.success)
        }
        persistInProgress()
    }

    /// A match shorter than this (builder elapsed time) is treated as an accidental start and
    /// discarded rather than saved.
    private let minimumMatchDuration: TimeInterval = 60

    /// End the match: stop location, finish the builder + route, persist and hand back results.
    /// Sessions shorter than `minimumMatchDuration` are discarded without saving or transferring.
    @discardableResult
    func endMatch() async -> MatchOutcome {
        let end = Date()
        stopLocationUpdates()
        headingRecorder.stop()

        // Discard an accidental / too-short session: no matchEnd event, no HealthKit save, no
        // record persistence, no file transfer, no field learning. Return to the start screen.
        let elapsed = builder?.elapsedTime(at: end) ?? elapsedAtPause
        if elapsed < minimumMatchDuration {
            liveStreamer.stop()
            session?.end()
            builder?.discardWorkout()
            headingRecorder.reset()
            AppGroupStorage.clearInProgress()
            reset()
            return .discardedTooShort
        }

        log(.matchEnd, haptic: false)
        // One final live delta so the sideline sees matchEnd instead of timing out.
        await liveStreamer.sendFinalUpdate { [weak self] in self?.makeLiveUpdate() }
        liveStreamer.stop()

        // Capture the workout's average heart rate before finishing.
        if let statistics = builder?.statistics(for: HKQuantityType(.heartRate)) {
            let unit = HKUnit.count().unitDivided(by: .minute())
            summaryAverageHeartRate = statistics.averageQuantity()?.doubleValue(for: unit)
        }
        elapsedAtPause = builder?.elapsedTime(at: end) ?? elapsedAtPause

        session?.end()

        var workout: HKWorkout?
        do {
            try await builder?.endCollection(at: end)
            workout = try await builder?.finishWorkout()
            if let workout, let routeBuilder {
                _ = try? await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
        } catch {
            MatchLog.error("Finishing workout failed: \(error.localizedDescription)", category: "workout")
            workout = nil
        }

        // Automatic period detection: no-op when the wearer tagged periods manually.
        let projector = fieldID
            .flatMap { id in AppGroupStorage.fieldStore.fields.first { $0.id == id } }
            .map { FieldProjector(rectangle: $0.rectangle) }
        let detectedPeriods = PeriodDetector.detectPeriods(track: track, events: events,
                                                           projector: projector,
                                                           configuration: PeriodDetectorConfiguration())
        if !detectedPeriods.isEmpty {
            events.append(contentsOf: detectedPeriods)
            events.sort { $0.date < $1.date }
        }

        let recordID = workout?.uuid ?? matchID
        let record = MatchRecord(
            id: recordID,
            startDate: matchStartDate,
            endDate: end,
            fieldID: fieldID,
            events: events,
            teamCode: AppGroupStorage.teamCode,
            sportID: WatchSettings.sportProfile.id,
            headings: headingRecorder.collected
        )

        finishedWorkout = workout
        finishedRecord = record
        AppGroupStorage.persistFinished(record)
        AppGroupStorage.clearInProgress()
        writeLastMatchSnapshot(record: record, end: end)

        // Post-match field learning: refine a known field or propose a newly inferred one.
        switch AppGroupStorage.fieldStore.recordObservation(track: track) {
        case .proposed(let field):
            proposedField = field
        case .matched, .none:
            proposedField = nil
        }

        phase = .summary
        return .finished(workout: workout, record: record)
    }

    /// Feeds the widget's last-match Smart Stack card.
    private func writeLastMatchSnapshot(record: MatchRecord, end: Date) {
        let runs = RunDetector.detectRuns(in: track, configuration: RunDetectorConfiguration())
        let fieldName = record.fieldID
            .flatMap { id in AppGroupStorage.fieldStore.fields.first { $0.id == id }?.name }
        let snapshot = LastMatchSnapshot(
            matchID: record.id,
            endDate: end,
            fieldName: fieldName,
            durationSeconds: elapsedAtPause,
            timeOnPitchSeconds: SubstitutionTracker.timeOnPitch(events: record.events,
                                                                matchStart: record.startDate,
                                                                matchEnd: end),
            distanceMeters: distanceMeters,
            goalsUs: score.us,
            goalsThem: score.them,
            sprintCount: runs.filter { $0.intensity == .sprint }.count
        )
        do {
            try snapshot.save(to: AppGroupStorage.containerURL)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            MatchLog.error("Snapshot write failed: \(error.localizedDescription)", category: "widgets")
        }
    }

    /// Return to the start screen, clearing the finished match.
    func reset() {
        finishedWorkout = nil
        finishedRecord = nil
        proposedField = nil
        summaryAverageHeartRate = nil
        events = []
        track = []
        heartRate = 0
        activeCalories = 0
        distanceMeters = 0
        currentSpeed = 0
        elapsedAtPause = 0
        onPitch = true
        autoSubDetector = nil
        autoSubBanner = nil
        session = nil
        builder = nil
        routeBuilder = nil
        sessionState = .notStarted
        phase = .idle
    }

    private func resetForNewMatch(field: FieldModel?) {
        matchID = UUID()
        fieldID = field?.id
        // A resolved field gives the detector a touchline to reason about; without one, automatic
        // substitution detection is simply off for this match. Referees are never "subbed".
        autoSubDetector = WatchSettings.refereeMode ? nil : field.map {
            AutoSubDetector(projector: FieldProjector(rectangle: $0.rectangle), initiallyOnPitch: true)
        }
        autoSubBanner = nil
        events = []
        track = []
        recentLocations = []
        heartRate = 0
        activeCalories = 0
        distanceMeters = 0
        currentSpeed = 0
        elapsedAtPause = 0
        onPitch = true
        finishedWorkout = nil
        finishedRecord = nil
        proposedField = nil
        summaryAverageHeartRate = nil
    }

    private func persistInProgress() {
        let record = MatchRecord(
            id: matchID,
            startDate: matchStartDate,
            endDate: nil,
            fieldID: fieldID,
            events: events,
            teamCode: AppGroupStorage.teamCode
        )
        AppGroupStorage.persistInProgress(record)
    }

    // MARK: - Location

    private func startLocationUpdates() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
    }

    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
    }

    private func recomputeCurrentSpeed() {
        let usable = recentLocations.suffix(5).filter { $0.speed >= 0 }
        if usable.isEmpty {
            currentSpeed = 0
        } else {
            currentSpeed = usable.reduce(0) { $0 + $1.speed } / Double(usable.count)
        }
    }

    // MARK: - Session recovery

    /// Called on launch to reattach to a session that survived the app being suspended/killed.
    func recoverActiveWorkoutSession() async {
        guard session == nil else { return }
        let recovered: HKWorkoutSession?
        do {
            recovered = try await healthStore.recoverActiveWorkoutSession()
        } catch {
            recovered = nil
        }
        guard let recovered else { return }
        handleActiveWorkoutRecovery(session: recovered)
    }

    /// Reattach delegates/metrics to a recovered session and restore the in-progress record.
    func handleActiveWorkoutRecovery(session recovered: HKWorkoutSession) {
        let builder = recovered.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                     workoutConfiguration: recovered.workoutConfiguration)
        recovered.delegate = self
        builder.delegate = self

        session = recovered
        self.builder = builder
        routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
        sessionState = recovered.state

        if let record = AppGroupStorage.loadInProgress() {
            matchID = record.id
            matchStartDate = record.startDate
            fieldID = record.fieldID
            events = record.events
            // Restore on-pitch state from the last substitution event (a subIn or subOut),
            // ignoring any later non-sub events that would otherwise mask it.
            let lastSub = events.last { $0.kind == .subIn || $0.kind == .subOut }
            onPitch = lastSub?.kind != .subOut

            // Rebuild the detector from the recovered field so auto-detection resumes mid-match.
            if let fieldID, let field = AppGroupStorage.fieldStore.fields.first(where: { $0.id == fieldID }) {
                autoSubDetector = AutoSubDetector(projector: FieldProjector(rectangle: field.rectangle),
                                                  initiallyOnPitch: onPitch)
            }
        }

        startLocationUpdates()
        phase = .active
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        DispatchQueue.main.async {
            self.sessionState = toState
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        // Non-fatal: surface nothing, keep the UI responsive.
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let energyUnit = HKUnit.largeCalorie()
        let distanceUnit = HKUnit.meter()

        var newHeartRate: Double?
        var newCalories: Double?
        var newDistance: Double?

        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = workoutBuilder.statistics(for: quantityType) else { continue }

            switch quantityType {
            case HKQuantityType(.heartRate):
                if let value = statistics.mostRecentQuantity()?.doubleValue(for: heartRateUnit), value > 1 {
                    newHeartRate = value
                }
            case HKQuantityType(.activeEnergyBurned):
                newCalories = statistics.sumQuantity()?.doubleValue(for: energyUnit)
            case HKQuantityType(.distanceWalkingRunning):
                newDistance = statistics.sumQuantity()?.doubleValue(for: distanceUnit)
            default:
                break
            }
        }

        DispatchQueue.main.async {
            if let newHeartRate { self.heartRate = newHeartRate }
            if let newCalories { self.activeCalories = newCalories }
            if let newDistance { self.distanceMeters = newDistance }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WorkoutManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let filtered = locations.filter { $0.horizontalAccuracy <= TrackPoint.maximumUsableHorizontalAccuracy }
        guard !filtered.isEmpty else { return }

        routeBuilder?.insertRouteData(filtered) { _, _ in }

        let points = filtered.map(Self.trackPoint(from:))
        DispatchQueue.main.async {
            self.track.append(contentsOf: points)
            self.recentLocations.append(contentsOf: filtered)
            if self.recentLocations.count > 10 {
                self.recentLocations.removeFirst(self.recentLocations.count - 10)
            }
            self.recomputeCurrentSpeed()
            self.runAutoSubDetection(on: points)
        }
    }

    /// Feed accepted GPS points (with the latest heart rate) through the detector. A returned auto
    /// sub event is logged preserving its own date/source, flips `onPitch`, fires a distinct gentle
    /// haptic and raises a transient banner. Runs on the main queue with the published metrics.
    private func runAutoSubDetection(on points: [TrackPoint]) {
        guard let detector = autoSubDetector else { return }
        let latestHeartRate = heartRate > 0 ? heartRate : nil
        for point in points {
            guard let event = detector.process(point: point, heartRate: latestHeartRate) else { continue }
            append(event, haptic: false)
            onPitch = event.kind != .subOut
            WKInterfaceDevice.current().play(.directionUp)
            showAutoSubBanner(event.kind == .subOut ? "Subbed out (auto)" : "Subbed in (auto)")
        }
    }

    /// Raise the auto-sub banner and clear it after a moment.
    private func showAutoSubBanner(_ message: String) {
        autoSubBanner = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.autoSubBanner == message { self?.autoSubBanner = nil }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    static func trackPoint(from location: CLLocation) -> TrackPoint {
        TrackPoint(
            coordinate: Coordinate2D(latitude: location.coordinate.latitude,
                                     longitude: location.coordinate.longitude),
            timestamp: location.timestamp,
            speedMetersPerSecond: location.speed,
            courseDegrees: location.course,
            horizontalAccuracy: location.horizontalAccuracy
        )
    }
}
