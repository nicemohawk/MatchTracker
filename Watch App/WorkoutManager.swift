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

    /// Format chosen on the start screen; drives location/indoor behavior and analytics scaling.
    var matchFormat: MatchFormat = .match

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

    /// Run/sprint counts computed once by the post-match pipeline; nil while still computing.
    /// SummaryView reads this instead of re-running the detector in its body.
    var summaryRunCounts: (runs: Int, sprints: Int)?

    /// Why the last start attempt failed, surfaced on the start screen — a silent bounce back
    /// to idle is indistinguishable from "the countdown just never switched".
    var startFailureMessage: String?
    /// True when the live UI is up but HealthKit collection hasn't begun within the watchdog
    /// window — shown as a banner so a wedged healthd is visible instead of a 0:00 mystery.
    var healthCollectionStalled = false
    @ObservationIgnored private var collectionBegan = false

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

    /// Serial queue for crash-safety record writes: keeps the JSON encode + disk write off the
    /// event-logging path while preserving write order.
    @ObservationIgnored private let persistQueue = DispatchQueue(label: "com.matchtracker.watch.persistInProgress",
                                                                 qos: .utility)

    // Units are immutable; cache them instead of rebuilding per didCollectDataOf callback.
    private static let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
    private static let energyUnit = HKUnit.largeCalorie()
    private static let distanceUnit = HKUnit.meter()

    /// Built per match so the selected sport's activity type is honored.
    private func makeWorkoutConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        let sport = WatchSettings.sportProfile
        configuration.activityType = HKWorkoutActivityType(rawValue: UInt(sport.workoutActivityTypeRawValue)) ?? .soccer
        configuration.locationType = matchFormat == .indoor ? .indoor : .outdoor
        return configuration
    }

    /// Whether this session runs without GPS (indoor court/dome): no location, route, field
    /// detection, auto-sub or heading capture — HR/energy collection is unchanged.
    private var isIndoor: Bool { matchFormat == .indoor }

    /// Analytics context for scaling run/period detection to the format and field size.
    var matchContext: MatchContext {
        let length = fieldID
            .flatMap { id in AppGroupStorage.fieldStore.fields.first { $0.id == id } }?
            .rectangle.lengthMeters
        return MatchContext(format: matchFormat, fieldLengthMeters: length)
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

    @MainActor
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

    /// When the pre-kickoff countdown runs out. Kickoff is driven by this wall-clock deadline
    /// rather than by counting timer ticks: the watch suspends the app the moment the wrist
    /// drops, and a swallowed tick used to strand the countdown on "1" forever with no way out.
    private(set) var countdownDeadline = Date()

    /// Guards against two kickoff triggers (a tick and the deadline task) both getting past the
    /// phase check before `startMatch` flips it.
    @ObservationIgnored private var kickoffInFlight = false

    /// Enter the pre-kickoff countdown. Owns the deadline *and* the timer that fires it, so the
    /// countdown view is only a display of state it can't strand.
    @MainActor
    func beginCountdown(field: FieldModel?, format: MatchFormat, seconds: TimeInterval = 3) {
        guard phase == .idle else { return }
        matchFormat = format
        detectedField = field
        startFailureMessage = nil
        countdownDeadline = Date().addingTimeInterval(seconds)
        phase = .countdown
        MatchLog.info("user: start tapped (format \(format.rawValue), field \(field?.name ?? "none"))",
                      category: "workout")

        Task { @MainActor [weak self] in
            guard let self else { return }
            // A sleep can be starved or resume late (the watch's clock doesn't advance while the
            // CPU sleeps), so this loops on the wall clock instead of trusting a single wait.
            while phase == .countdown, countdownDeadline.timeIntervalSinceNow > 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await kickoffIfCountdownElapsed(trigger: "deadline")
        }
    }

    /// Start the match if the countdown has run out. Safe to call from every redundant trigger —
    /// the deadline task, a display tick, or the app coming back to the foreground.
    @MainActor
    func kickoffIfCountdownElapsed(trigger: String) async {
        guard phase == .countdown, !kickoffInFlight,
              countdownDeadline.timeIntervalSinceNow <= 0 else { return }
        kickoffInFlight = true
        MatchLog.info("countdown elapsed: kicking off (trigger \(trigger))", category: "workout")
        await startMatch(field: detectedField)
        kickoffInFlight = false
    }

    /// Configure and start the workout session for a match on an optional detected field.
    ///
    /// The live UI is shown as soon as the session starts — `beginCollection` is a HealthKit XPC
    /// round-trip that can take seconds, so it completes after the transition and metrics simply
    /// read 0 until the first samples arrive.
    /// @MainActor: `phase` (and every other @Observable property) MUST mutate on the main
    /// thread — off-main mutations happened to render on the simulator but never re-rendered on
    /// a physical watch, leaving the countdown frozen on "1" with the session already live.
    /// The synchronous HealthKit calls here are fast; the awaits suspend without blocking UI.
    @MainActor
    func startMatch(field: FieldModel?) async {
        // Re-entry guard: a stuck countdown view could fire this twice, stacking two live
        // sessions (observed on-device as doubled start breadcrumbs).
        guard phase != .active else {
            MatchLog.error("startMatch: ignored — a session is already active", category: "workout")
            return
        }
        resetForNewMatch(field: field)

        // Flip the UI FIRST: the HealthKit setup below takes real time on-device, and running
        // it before the phase change was the visible beat between "1" and the session screen.
        let start = Date()
        matchStartDate = start
        phase = .active
        log(.matchStart, haptic: false)
        // Indoor: no location updates, route, field detection, auto-sub or heading capture.
        // HR/energy still collect; the track stays empty and currentSpeed stays 0.
        if !isIndoor {
            startLocationUpdates()
            headingRecorder.start()
        }
        liveStreamer.start { [weak self] in self?.makeLiveUpdate() }

        // Watchdog: if collection hasn't begun shortly, say so on the session screen — a wedged
        // healthd otherwise reads as a mysteriously frozen 0:00 timer.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.phase == .active, !self.collectionBegan else { return }
            MatchLog.error("startMatch: collection has not begun after 10s", category: "workout")
            self.healthCollectionStalled = true
        }

        // HealthKit setup off the main actor so the session screen renders instantly. Delegates
        // are set before startActivity (their callbacks hop to main themselves).
        let configuration = makeWorkoutConfiguration()
        let store = healthStore
        MatchLog.info("startMatch: creating session (format \(matchFormat.rawValue), field \(field != nil ? "detected" : "none"), referee \(WatchSettings.refereeMode))",
                      category: "workout")
        do {
            let (session, builder) = try await Task.detached(priority: .userInitiated) { [weak self] in
                let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
                let builder = session.associatedWorkoutBuilder()
                builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                             workoutConfiguration: configuration)
                session.delegate = self
                builder.delegate = self
                MatchLog.info("startMatch: session created", category: "workout")
                session.startActivity(with: start)
                MatchLog.info("startMatch: activity started", category: "workout")
                return (session, builder)
            }.value

            self.session = session
            self.builder = builder
            // Indoor sessions have no usable GPS: skip the route builder entirely.
            self.routeBuilder = isIndoor ? nil : HKWorkoutRouteBuilder(healthStore: store, device: .local())

            try await builder.beginCollection(at: start)
            collectionBegan = true
            healthCollectionStalled = false
            MatchLog.info("startMatch: collection began", category: "workout")
        } catch {
            // Session creation or collection failed: tear down what the optimistic start spun up
            // and fall back to the start screen with a visible reason.
            MatchLog.error("Unable to start workout session: \(error.localizedDescription)", category: "workout")
            startFailureMessage = "Couldn't start the workout: \(error.localizedDescription)"
            stopLocationUpdates()
            headingRecorder.stop()
            headingRecorder.reset()
            liveStreamer.stop()
            session?.end()
            clearInProgressBehindPendingWrites()
            reset()
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
        // The one funnel every match event passes through — manual taps and detectors alike —
        // so the journal gets a complete event timeline. `haptic` distinguishes a user tap
        // (true) from system-generated events.
        let elapsed = Int(event.date.timeIntervalSince(matchStartDate))
        MatchLog.info("event: \(event.kind.rawValue) at \(elapsed / 60):\(String(format: "%02d", elapsed % 60)) (\(haptic ? "user" : "system"))",
                      category: "events")
        events.append(event)
        if haptic {
            WKInterfaceDevice.current().play(.success)
        }
        persistInProgress()
    }

    /// A match shorter than this (builder elapsed time) is treated as an accidental start and
    /// discarded rather than saved.
    private let minimumMatchDuration: TimeInterval = 30

    /// End the match: stop location, finish the builder + route, persist and hand back results.
    /// Sessions shorter than `minimumMatchDuration` are discarded without saving or transferring.
    @discardableResult
    /// @MainActor for the same reason as `startMatch`: observable mutations (phase, summary
    /// fields) must land on the main thread to reliably re-render on device.
    @MainActor
    func endMatch() async -> MatchOutcome {
        let end = Date()
        stopLocationUpdates()
        headingRecorder.stop()
        MatchLog.info("endMatch: begun (collectionBegan \(collectionBegan))", category: "workout")

        // Discard an accidental / too-short session: no matchEnd event, no HealthKit save, no
        // record persistence, no file transfer, no field learning. Return to the start screen.
        // If HealthKit collection never began (wedged healthd), the builder's elapsed time is a
        // meaningless 0 — judge by wall clock so a real match isn't discarded as an accident;
        // the record (with its embedded track) still saves and transfers without HealthKit.
        let elapsed = collectionBegan
            ? (builder?.elapsedTime(at: end) ?? elapsedAtPause)
            : end.timeIntervalSince(matchStartDate)
        if elapsed < minimumMatchDuration {
            MatchLog.info("endMatch: discarding too-short session (\(Int(elapsed))s)", category: "workout")
            liveStreamer.stop()
            session?.end()
            builder?.discardWorkout()
            headingRecorder.reset()
            clearInProgressBehindPendingWrites()
            reset()
            return .discardedTooShort
        }

        log(.matchEnd, haptic: false)
        // One final live delta so the sideline sees matchEnd instead of timing out.
        await liveStreamer.sendFinalUpdate { [weak self] in self?.makeLiveUpdate() }
        liveStreamer.stop()

        // Capture the workout's average heart rate before finishing.
        if let statistics = builder?.statistics(for: HKQuantityType(.heartRate)) {
            summaryAverageHeartRate = statistics.averageQuantity()?.doubleValue(for: Self.heartRateUnit)
        }
        elapsedAtPause = builder?.elapsedTime(at: end) ?? elapsedAtPause

        session?.end()

        // Show the summary now: its hero stats (duration, distance, calories, avg HR) are already
        // known, while the HealthKit finish + analytics pipeline below can take seconds. The
        // record-driven rows fill in when `finishedRecord` publishes at the end.
        phase = .summary

        var workout: HKWorkout?
        do {
            try await builder?.endCollection(at: end)
            do {
                workout = try await builder?.finishWorkout()
            } catch {
                // finishWorkout can fail transiently (HealthKit XPC); one immediate retry rescues
                // the workout + route save. On a second failure the record below still carries the
                // full track, so the route is never lost with the workout.
                MatchLog.error("finishWorkout failed, retrying once: \(error.localizedDescription)", category: "workout")
                workout = try await builder?.finishWorkout()
            }
            if let workout, let routeBuilder {
                _ = try? await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
        } catch {
            MatchLog.error("Finishing workout failed: \(error.localizedDescription)", category: "workout")
            workout = nil
        }

        // Automatic period detection: no-op when the wearer tagged periods manually. A formal
        // match expects two halves; pickup/indoor sessions have variable breaks (expectedPeriods 0).
        let projector = fieldID
            .flatMap { id in AppGroupStorage.fieldStore.fields.first { $0.id == id } }
            .map { FieldProjector(rectangle: $0.rectangle) }
        var periodConfiguration = PeriodDetectorConfiguration()
        periodConfiguration.expectedPeriods = matchFormat == .match ? 2 : 0
        let detectedPeriods = PeriodDetector.detectPeriods(track: track, events: events,
                                                           projector: projector,
                                                           configuration: periodConfiguration)
        if !detectedPeriods.isEmpty {
            let boundaries = detectedPeriods
                .map { Int($0.date.timeIntervalSince(matchStartDate)) / 60 }
                .map(String.init).joined(separator: ", ")
            MatchLog.info("endMatch: detected \(detectedPeriods.count) period events at minutes [\(boundaries)]",
                          category: "workout")
            events.append(contentsOf: detectedPeriods)
            events.sort { $0.date < $1.date }
        }

        let recordID = workout?.uuid ?? matchID
        var record = MatchRecord(
            id: recordID,
            startDate: matchStartDate,
            endDate: end,
            fieldID: fieldID,
            events: events,
            teamCode: AppGroupStorage.teamCode,
            sportID: WatchSettings.sportProfile.id,
            headings: headingRecorder.collected
        )
        // Set explicitly so a formal match records `.match` rather than relying on the nil default.
        record.format = matchFormat
        // Redundant route: the final record carries the full-resolution track so the phone can
        // still render/analyze the match if the HealthKit workout (and thus its route) was lost
        // above. Only the final record gets it — the per-event crash-safety snapshots stay lean.
        record.track = track.isEmpty ? nil : track

        AppGroupStorage.persistFinished(record)
        clearInProgressBehindPendingWrites()

        // Detect runs once, feeding both the summary rows and the widget snapshot.
        let runs = RunDetector.detectRuns(in: track, configuration: .scaled(for: matchContext))
        let runCounts = (runs: runs.filter { $0.intensity == .run }.count,
                         sprints: runs.filter { $0.intensity == .sprint }.count)
        summaryRunCounts = runCounts
        writeLastMatchSnapshot(record: record, end: end, sprintCount: runCounts.sprints)

        // Post-match field learning: refine a known field or propose a newly inferred one.
        // Skipped indoors — there is no GPS track to learn a field from.
        if isIndoor {
            proposedField = nil
        } else {
            switch AppGroupStorage.fieldStore.recordObservation(track: track) {
            case .proposed(let field):
                proposedField = field
            case .matched, .none:
                proposedField = nil
            }
        }

        finishedWorkout = workout
        // Published last: SummaryView refreshes off the record, so run counts and the proposed
        // field must already be in place when it lands.
        finishedRecord = record
        return .finished(workout: workout, record: record)
    }

    /// Feeds the widget's last-match Smart Stack card.
    private func writeLastMatchSnapshot(record: MatchRecord, end: Date, sprintCount: Int) {
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
            sprintCount: sprintCount
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
        summaryRunCounts = nil
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
        startFailureMessage = nil
        healthCollectionStalled = false
        collectionBegan = false
        // A resolved field gives the detector a touchline to reason about; without one, automatic
        // substitution detection is simply off for this match. Referees are never "subbed", and
        // indoor sessions have no GPS to reason about a touchline.
        autoSubDetector = (WatchSettings.refereeMode || isIndoor) ? nil : field.map {
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
        summaryRunCounts = nil
    }

    private func persistInProgress() {
        var record = MatchRecord(
            id: matchID,
            startDate: matchStartDate,
            endDate: nil,
            fieldID: fieldID,
            events: events,
            teamCode: AppGroupStorage.teamCode
        )
        record.format = matchFormat
        // The record snapshot above is cheap; the encode + disk write is not, so it happens on
        // the serial persist queue (ordered, so a later snapshot can never be clobbered).
        persistQueue.async {
            AppGroupStorage.persistInProgress(record)
        }
    }

    /// Clears the crash-safety record on the persist queue, behind any queued writes — clearing
    /// directly could otherwise be overtaken by a pending write that resurrects a stale record.
    private func clearInProgressBehindPendingWrites() {
        persistQueue.async {
            AppGroupStorage.clearInProgress()
        }
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
    @MainActor
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
        // Restore the format from the persisted record (falls back to the recovered config's
        // location type, which distinguishes indoor from outdoor).
        matchFormat = AppGroupStorage.loadInProgress()?.format
            ?? (recovered.workoutConfiguration.locationType == .indoor ? .indoor : .match)
        routeBuilder = isIndoor ? nil : HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
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

            // Rebuild the detector from the recovered field so auto-detection resumes mid-match
            // (never indoors — there is no GPS touchline to reason about).
            if !isIndoor, let fieldID, let field = AppGroupStorage.fieldStore.fields.first(where: { $0.id == fieldID }) {
                autoSubDetector = AutoSubDetector(projector: FieldProjector(rectangle: field.rectangle),
                                                  initiallyOnPitch: onPitch)
            }
        }

        // Indoor sessions never resumed location updates.
        if !isIndoor {
            startLocationUpdates()
        }
        phase = .active
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        MatchLog.info("session state \(fromState.rawValue) -> \(toState.rawValue)", category: "workout")
        DispatchQueue.main.async {
            self.sessionState = toState
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        // A dead session means no samples will ever arrive — swallowing this is how a device
        // failure (e.g. the missing WKBackgroundModes key) stayed invisible for days. Log it
        // and light both failure surfaces; the UI stays responsive either way.
        MatchLog.error("workout session failed: \(error.localizedDescription)", category: "workout")
        DispatchQueue.main.async {
            self.startFailureMessage = "Workout session failed: \(error.localizedDescription)"
            self.healthCollectionStalled = true
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        var newHeartRate: Double?
        var newCalories: Double?
        var newDistance: Double?

        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = workoutBuilder.statistics(for: quantityType) else { continue }

            switch quantityType {
            case HKQuantityType(.heartRate):
                if let value = statistics.mostRecentQuantity()?.doubleValue(for: Self.heartRateUnit), value > 1 {
                    newHeartRate = value
                }
            case HKQuantityType(.activeEnergyBurned):
                newCalories = statistics.sumQuantity()?.doubleValue(for: Self.energyUnit)
            case HKQuantityType(.distanceWalkingRunning):
                newDistance = statistics.sumQuantity()?.doubleValue(for: Self.distanceUnit)
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
            // First accepted fix: the "GPS is alive" journal breadcrumb (accuracy only — the
            // MatchLog privacy contract keeps coordinates out of logs).
            if self.track.isEmpty, let first = filtered.first {
                MatchLog.info("first GPS fix accepted (accuracy \(Int(first.horizontalAccuracy)) m)",
                              category: "location")
            }
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
            let elapsed = Int(point.timestamp.timeIntervalSince(matchStartDate))
            MatchLog.info("auto-sub: \(event.kind == .subOut ? "OUT" : "IN") at \(elapsed / 60):\(String(format: "%02d", elapsed % 60)) (point \(track.count))",
                          category: "autosub")
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
