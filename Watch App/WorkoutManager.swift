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

    /// Wall-clock pause accounting. The builder's elapsed time honors pauses by itself, but it
    /// only exists while HealthKit is collecting — this keeps Pause meaningful when it isn't.
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    @ObservationIgnored private var pauseStarted: Date?

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
    var startFailure: StartFailure?

    /// A failed start in words that say what to do about it, with the raw error kept for the
    /// developer underneath. HealthKit's own text ("Client application cannot start a workout
    /// session while in the background") describes its rule, not the player's situation.
    struct StartFailure: Equatable {
        var message: String
        var detail: String?

        init(_ error: Error) {
            detail = error.localizedDescription
            let nsError = error as NSError
            guard nsError.domain == HKError.errorDomain,
                  let code = HKError.Code(rawValue: nsError.code) else {
                message = "Couldn't start the match."
                return
            }
            switch code {
            case .errorBackgroundWorkoutSessionNotAllowed:
                message = "The watch was asleep when the match tried to start. Wake it and tap Start again."
            case .errorAnotherWorkoutSessionStarted:
                message = "Another app is already recording a workout. End that one, then start again."
            case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorRequiredAuthorizationDenied:
                message = "MatchTracker needs permission to record workouts. Allow it under Health in the Watch app."
            case .errorDatabaseInaccessible:
                message = "Health data is locked. Unlock the watch and start again."
            case .errorHealthDataUnavailable, .errorHealthDataRestricted:
                message = "This watch can't record workouts."
            default:
                message = "Couldn't start the match."
            }
        }
    }
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
    /// GPS for the match: warm-up, recording, retries and the on-disk copy of the route.
    @ObservationIgnored let routeRecorder = RouteRecorder()
    @ObservationIgnored private var recentLocations: [RouteFix] = []

    /// HealthKit refused or dropped the session mid-match. GPS keeps recording; the session is
    /// retried whenever the app is frontmost.
    @ObservationIgnored private var sessionLost = false
    @ObservationIgnored private var sessionStarting = false
    @ObservationIgnored private var sessionAttempts = 0
    /// Earlier matches still being saved. A new session waits (briefly) for them: starting one
    /// ends any session still open.
    @ObservationIgnored private var healthSavesInFlight = 0
    @ObservationIgnored private var recoveryInFlight = false

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
        routeRecorder.onFixes = { [weak self] fixes in self?.ingest(fixes) }
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

    /// Live elapsed time at a given instant.
    ///
    /// The builder is the source of truth while HealthKit is collecting (it honors pauses for
    /// us); without it the wall clock takes over, minus time spent paused. A session that never
    /// reached `beginCollection` used to read a frozen 0:00 that was indistinguishable from a
    /// timer that had never started.
    func elapsedTime(at date: Date) -> TimeInterval {
        if collectionBegan, let builder { return builder.elapsedTime(at: date) }
        guard phase == .active else { return elapsedAtPause }
        let paused = pausedTotal + (pauseStarted.map { date.timeIntervalSince($0) } ?? 0)
        return max(0, date.timeIntervalSince(matchStartDate) - paused)
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
    }

    // MARK: - Match lifecycle

    /// When the pre-kickoff countdown runs out. Kickoff is driven by this wall-clock deadline
    /// rather than by counting timer ticks: the watch suspends the app the moment the wrist
    /// drops, and a swallowed tick used to strand the countdown on "1" forever with no way out.
    private(set) var countdownDeadline = Date()

    /// Start the match. **Recording begins here, on the tap** — the countdown is only a display.
    ///
    /// HealthKit won't start a session from the background, and Core Location won't continue in
    /// the background unless updates began in the foreground. The tap is the one moment both are
    /// guaranteed; three seconds later the wrist is usually down. (One match sat suspended in its
    /// countdown for 37 minutes, none of it recorded.)
    @MainActor
    func beginCountdown(field: FieldModel?, format: MatchFormat, seconds: TimeInterval = 3) {
        guard phase == .idle else { return }
        // Anything a previous match left behind goes out before this one writes over it.
        salvageInterruptedMatch()
        matchFormat = format
        detectedField = field
        resetForNewMatch(field: field)
        let start = Date()
        matchStartDate = start
        countdownDeadline = start.addingTimeInterval(seconds)
        phase = .countdown
        MatchLog.info("user: start tapped (format \(format.rawValue), field \(field?.name ?? "none"), referee \(WatchSettings.refereeMode))",
                      category: "workout")

        // Indoor: no location updates, route, field detection, auto-sub or heading capture.
        if !isIndoor {
            routeRecorder.arm()
            routeRecorder.beginRecording(matchID: matchID, start: start)
            headingRecorder.start()
        } else {
            routeRecorder.coolDown()
        }
        startWorkoutSession()
        log(.matchStart, haptic: false)
        liveStreamer.start { [weak self] in self?.makeLiveUpdate() }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Loops on the wall clock: a sleep can be starved or resume late.
            while phase == .countdown, countdownDeadline.timeIntervalSinceNow > 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            kickoffIfCountdownElapsed(trigger: "deadline")
        }
    }

    /// Reveal the live screen if the countdown has run out. Safe to call from every redundant
    /// trigger — the deadline task, a display tick, or the app coming back to the foreground.
    @MainActor
    func kickoffIfCountdownElapsed(trigger: String) {
        guard phase == .countdown, countdownDeadline.timeIntervalSinceNow <= 0 else { return }
        phase = .active
        MatchLog.info("kickoff: phase -> active (trigger \(trigger), \(Int(Date().timeIntervalSince(matchStartDate))) s after the tap)",
                      category: "workout")
    }

    /// Skip the rest of the countdown.
    @MainActor
    func skipCountdown() {
        guard phase == .countdown else { return }
        countdownDeadline = Date()
        kickoffIfCountdownElapsed(trigger: "skipped")
    }

    private var isRecording: Bool { phase == .countdown || phase == .active }

    /// Create and start the HealthKit session for the current match, dated from the Start tap.
    /// Also the retry path: the match (and its GPS) carries on without a session until one takes.
    @MainActor
    private func startWorkoutSession() {
        guard !sessionStarting else { return }
        sessionStarting = true
        sessionLost = false
        sessionAttempts += 1
        let id = matchID
        let start = matchStartDate
        let attempt = sessionAttempts
        let configuration = makeWorkoutConfiguration()
        let store = healthStore

        // Say so on the session screen if collection doesn't begin: a wedged healthd otherwise
        // reads as a heart rate that mysteriously never arrives.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.matchID == id, self.isRecording, !self.collectionBegan else { return }
            MatchLog.error("session: collection has not begun after 10s", category: "workout")
            self.healthCollectionStalled = true
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { sessionStarting = false }
            let patience = Date().addingTimeInterval(5)
            while healthSavesInFlight > 0, Date() < patience {
                try? await Task.sleep(for: .milliseconds(100))
            }
            do {
                let (session, builder) = try await Task.detached(priority: .userInitiated) {
                    let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
                    let builder = session.associatedWorkoutBuilder()
                    builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                                 workoutConfiguration: configuration)
                    session.delegate = self
                    builder.delegate = self
                    session.startActivity(with: start)
                    return (session, builder)
                }.value
                // Ended (or replaced) while HealthKit was working: don't leave a session running.
                guard matchID == id, isRecording else {
                    session.end()
                    builder.discardWorkout()
                    return
                }
                self.session = session
                self.builder = builder
                try await builder.beginCollection(at: start)
                guard matchID == id, isRecording else { return }
                // A refused session fails asynchronously, and collection still "begins" on it.
                guard session.state != .ended, session.state != .stopped else {
                    sessionFailed(nil, matchID: id)
                    return
                }
                collectionBegan = true
                healthCollectionStalled = false
                applySessionState(session.state)
                MatchLog.info("session: collecting (attempt \(attempt), \(Int(Date().timeIntervalSince(start))) s after the tap)",
                              category: "workout")
            } catch {
                sessionFailed(error, matchID: id)
            }
        }
    }

    /// HealthKit couldn't start or keep the session. Without permission there is nothing to
    /// record, so the start is abandoned; anything else keeps the match going on GPS alone and
    /// tries again — losing the heart rate is bad, losing the match is worse.
    @MainActor
    private func sessionFailed(_ error: Error?, matchID id: UUID) {
        guard matchID == id, isRecording, !sessionLost else { return }
        MatchLog.error("session failed (attempt \(sessionAttempts)): \(error?.localizedDescription ?? "ended before collecting")",
                       category: "workout")
        let code = (error as? HKError)?.code
        session = nil
        builder = nil
        collectionBegan = false

        switch code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorRequiredAuthorizationDenied,
             .errorHealthDataUnavailable, .errorHealthDataRestricted, .errorWorkoutActivityNotAllowed:
            startFailure = error.map { StartFailure($0) }
            abandonMatch()
            return
        case .errorAnotherWorkoutSessionStarted:
            // The wearer chose the other app; taking the session back would end their workout.
            healthCollectionStalled = true
            return
        default:
            break
        }
        sessionLost = true
        healthCollectionStalled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.retryWorkoutSessionIfNeeded()
        }
    }

    /// Only from the foreground (HealthKit's rule), and not forever.
    @MainActor
    private func retryWorkoutSessionIfNeeded() {
        guard isRecording, sessionLost, sessionAttempts < 6,
              WKApplication.shared().applicationState == .active else { return }
        MatchLog.info("session: retrying", category: "workout")
        startWorkoutSession()
    }

    /// Throw the current match away: nothing is saved anywhere.
    @MainActor
    private func abandonMatch() {
        let abandonedID = matchID
        let endingSession = session
        let endingBuilder = builder
        _ = routeRecorder.finish()
        routeRecorder.removeJournal(matchID: abandonedID)
        headingRecorder.reset()
        liveStreamer.stop()
        clearInProgress(matchID: abandonedID)
        reset()
        Task.detached(priority: .userInitiated) {
            endingSession?.end()
            endingBuilder?.discardWorkout()
        }
    }

    // MARK: - App state

    /// The app is frontmost: restore whatever can only be restored from here.
    @MainActor
    func appBecameActive() {
        switch phase {
        case .idle:
            routeRecorder.warmUp()
        case .countdown, .active:
            kickoffIfCountdownElapsed(trigger: "app became active")
            routeRecorder.appBecameActive()
            retryWorkoutSessionIfNeeded()
        case .summary:
            break
        }
    }

    @MainActor
    func appResignedActive() {
        if phase == .idle { routeRecorder.coolDown() }
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

    /// Pause the match. The visible state flips here rather than waiting for HealthKit's
    /// delegate callback: a session that failed to start (or a wedged healthd) never sends one,
    /// and the button then reads as a dead control that only buzzes. The delegate still
    /// reconciles `sessionState` when it does arrive.
    @MainActor
    func pause() {
        MatchLog.info("pause: entered (phase \(phase), sessionState \(sessionState.rawValue), session \(session == nil ? "absent" : "live"))",
                      category: "workout")
        guard phase == .active, sessionState != .paused else {
            MatchLog.error("pause: ignored — guard rejected the tap", category: "workout")
            return
        }
        // GPS stays on: a forgotten (or accidental — both side buttons together pause a workout)
        // pause must not cost the route, and updates stopped here may not restart wrist-down.
        applySessionState(.paused)
        session?.pause()
    }

    /// Resume a paused match. Mirror of `pause()` — optimistic, then forwarded to HealthKit.
    @MainActor
    func resume() {
        MatchLog.info("resume: entered (phase \(phase), sessionState \(sessionState.rawValue), session \(session == nil ? "absent" : "live"))",
                      category: "workout")
        guard phase == .active, sessionState == .paused else {
            MatchLog.error("resume: ignored — guard rejected the tap", category: "workout")
            return
        }
        applySessionState(.running)
        session?.resume()
    }

    /// The one place `sessionState` changes, so the pause clock can't drift from it — whether the
    /// change came from a button tap or from HealthKit's delegate contradicting one. Main queue
    /// only, like every other observable mutation here.
    private func applySessionState(_ state: HKWorkoutSessionState) {
        sessionState = state
        switch state {
        case .paused where pauseStarted == nil:
            pauseStarted = Date()
        case .running:
            if let pauseStarted { pausedTotal += Date().timeIntervalSince(pauseStarted) }
            pauseStarted = nil
        default:
            break
        }
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

    /// Everything a finished match needs to be saved. Captured once, when the match ends: saving
    /// takes seconds and the wearer may tap Done — or start the next match — long before it's
    /// over. Reading live state after that point used to save an empty match.
    private struct FinishingMatch {
        let id: UUID
        let start: Date
        let end: Date
        let format: MatchFormat
        let fieldID: UUID?
        let events: [MatchEvent]
        let fixes: [RouteFix]
        let headings: [HeadingSample]?
        let context: MatchContext
        let session: HKWorkoutSession?
        let builder: HKLiveWorkoutBuilder?
        let elapsed: TimeInterval
        let distanceMeters: Double
        let score: (us: Int, them: Int)

        var track: [TrackPoint] { fixes.map(\.point) }

        func record(id: UUID, events: [MatchEvent]) -> MatchRecord {
            var record = MatchRecord(id: id, startDate: start, endDate: end, fieldID: fieldID, events: events,
                                     teamCode: AppGroupStorage.teamCode,
                                     sportID: WatchSettings.sportProfile.id,
                                     headings: headings)
            // Set explicitly so a formal match records `.match` rather than relying on nil.
            record.format = format
            // The full-resolution track travels with the record too, so the phone can analyze the
            // match even if the HealthKit route was never saved.
            record.track = fixes.isEmpty ? nil : track
            return record
        }
    }

    /// End the match: show the summary, then save everything behind it.
    /// Sessions shorter than `minimumMatchDuration` are discarded without saving or transferring.
    @MainActor
    @discardableResult
    func endMatch() async -> MatchOutcome {
        let end = Date()
        guard isRecording else { return .discardedTooShort }
        MatchLog.info("endMatch: begun (collectionBegan \(collectionBegan), session \(session == nil ? "absent" : "live"))",
                      category: "workout")

        // `elapsedTime` falls back to the wall clock when HealthKit never began collecting, so a
        // real match isn't discarded as an accident on the builder's meaningless 0.
        let elapsed = elapsedTime(at: end)
        if elapsed < minimumMatchDuration {
            MatchLog.info("endMatch: discarding too-short session (\(Int(elapsed))s)", category: "workout")
            abandonMatch()
            return .discardedTooShort
        }

        log(.matchEnd, haptic: false)
        elapsedAtPause = elapsed
        // Built while the match is still live, because that's what `makeLiveUpdate` reports on.
        let finalUpdate = makeLiveUpdate()
        headingRecorder.stop()
        let match = FinishingMatch(
            id: matchID, start: matchStartDate, end: end, format: matchFormat, fieldID: fieldID,
            events: events, fixes: isIndoor ? [] : routeRecorder.finish(),
            headings: headingRecorder.collected, context: matchContext,
            session: session, builder: builder, elapsed: elapsed,
            distanceMeters: distanceMeters, score: score)
        session = nil
        builder = nil
        collectionBegan = false

        // The summary's hero stats are already known; the record-driven rows fill in when
        // `finishedRecord` publishes.
        phase = .summary
        MatchLog.info("endMatch: phase -> summary", category: "workout")
        // One final live delta so the sideline sees matchEnd instead of timing out.
        liveStreamer.sendFinalUpdate(finalUpdate)
        liveStreamer.stop()
        return await save(match)
    }

    /// Save a finished match. Independent of live state: results are published only if this match
    /// is still the one on screen.
    @MainActor
    private func save(_ match: FinishingMatch) async -> MatchOutcome {
        func publish(_ update: () -> Void) {
            if matchID == match.id, phase == .summary { update() }
        }

        // Safe on disk before anything that can be suspended or fail. If nothing below ever runs,
        // this is what the next launch sends, and the phone pairs it with the workout by time.
        let provisional = match.record(id: match.id, events: match.events)
        let provisionalSaved = await Task.detached(priority: .userInitiated) {
            AppGroupStorage.persistFinished(provisional) != nil
        }.value
        if provisionalSaved { clearInProgress(matchID: match.id) }

        // Bounded: HealthKit has been seen never to answer, and the phone should get this match
        // regardless. A save that lands later still pairs up there, by time.
        healthSavesInFlight += 1
        let saving = Task { () -> HKWorkout? in
            let workout = await self.saveWorkout(match) { average in
                publish { self.summaryAverageHeartRate = average }
            }
            self.healthSavesInFlight -= 1
            return workout
        }
        let workout = await Self.value(of: saving, within: 30)

        // Automatic period detection: no-op when the wearer tagged periods manually. A formal
        // match expects two halves; pickup/indoor sessions have variable breaks (expectedPeriods 0).
        let projector = match.fieldID
            .flatMap { id in AppGroupStorage.fieldStore.fields.first { $0.id == id } }
            .map { FieldProjector(rectangle: $0.rectangle) }
        var periodConfiguration = PeriodDetectorConfiguration()
        periodConfiguration.expectedPeriods = match.format == .match ? 2 : 0
        let configuration = periodConfiguration
        let runConfiguration = RunDetectorConfiguration.scaled(for: match.context)
        let track = match.track
        let recordID = workout?.uuid ?? match.id

        // Off the main actor: the detectors sweep the whole track and the record is megabytes.
        let (record, runCounts, recordSaved) = await Task.detached(priority: .userInitiated) {
            let periods = PeriodDetector.detectPeriods(track: track, events: match.events,
                                                       projector: projector, configuration: configuration)
            if !periods.isEmpty {
                let boundaries = periods.map { String(Int($0.date.timeIntervalSince(match.start)) / 60) }
                MatchLog.info("endMatch: detected \(periods.count) period events at minutes [\(boundaries.joined(separator: ", "))]",
                              category: "workout")
            }
            let record = match.record(id: recordID, events: (match.events + periods).sorted { $0.date < $1.date })
            let saved = AppGroupStorage.persistFinished(record) != nil
            let runs = RunDetector.detectRuns(in: track, configuration: runConfiguration)
            let counts = (runs: runs.filter { $0.intensity == .run }.count,
                          sprints: runs.filter { $0.intensity == .sprint }.count)
            return (record, counts, saved)
        }.value

        if recordSaved, recordID != match.id { AppGroupStorage.removeFinished(id: match.id) }
        if recordSaved || provisionalSaved { routeRecorder.removeJournal(matchID: match.id) }
        MatchLog.info("endMatch: saved (record \(recordSaved), workout \(workout != nil), fixes \(match.fixes.count))",
                      category: "workout")
        ConnectivityManager.shared.send(matchRecord: record)
        ConnectivityManager.shared.sendJournal()

        // Only now: the session is what keeps the app running wrist-down. Ending it first left
        // matches whose record was never written because the app was suspended mid-save.
        if let session = match.session {
            await Task.detached(priority: .userInitiated) { session.end() }.value
        }

        publish {
            events = record.events
            summaryRunCounts = runCounts
            finishedWorkout = workout
            // Last: SummaryView refreshes off the record, so the rest must already be in place.
            finishedRecord = record
        }
        writeLastMatchSnapshot(match, record: record, sprintCount: runCounts.sprints)

        // Field learning sweeps the whole track through the fitter, so nothing waits on it.
        if match.format != .indoor,
           case .proposed(let field) = AppGroupStorage.fieldStore.recordObservation(track: track) {
            publish { proposedField = field }
        }
        return .finished(workout: workout, record: record)
    }

    /// Save the workout and its route to HealthKit, in Apple's order: stop, end collection, finish,
    /// route — with the session still open throughout (`.stopped` keeps the app running).
    private func saveWorkout(_ match: FinishingMatch,
                             onAverageHeartRate: @escaping @MainActor (Double?) -> Void) async -> HKWorkout? {
        guard let session = match.session, let builder = match.builder else { return nil }
        let heartRateUnit = Self.heartRateUnit
        let average = await Task.detached(priority: .userInitiated) { () -> Double? in
            session.stopActivity(with: match.end)
            let patience = Date().addingTimeInterval(3)
            while session.state != .stopped, session.state != .ended, Date() < patience {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // An unanswered stop blocks `endCollection` indefinitely; ending outright releases it.
            if session.state != .stopped, session.state != .ended { session.end() }
            return builder.statistics(for: HKQuantityType(.heartRate))?
                .averageQuantity()?.doubleValue(for: heartRateUnit)
        }.value
        await onAverageHeartRate(average)
        MatchLog.info("endMatch: session \(session.state.rawValue), ending collection", category: "workout")

        var workout: HKWorkout?
        do {
            try await builder.endCollection(at: match.end)
            do {
                workout = try await builder.finishWorkout()
            } catch {
                // finishWorkout can fail transiently (HealthKit XPC); one retry rescues it.
                MatchLog.error("finishWorkout failed, retrying once: \(error.localizedDescription)", category: "workout")
                workout = try await builder.finishWorkout()
            }
        } catch {
            MatchLog.error("Finishing workout failed: \(error.localizedDescription)", category: "workout")
        }
        if let workout, !match.fixes.isEmpty {
            await saveRoute(match.fixes, to: workout)
        }
        return workout
    }

    /// A task's value, or nil if it takes longer than `seconds` (the task itself carries on).
    private static func value<Value>(of task: Task<Value?, Never>, within seconds: TimeInterval) async -> Value? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func resume(_ value: Value?, timedOut: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                if timedOut {
                    MatchLog.error("HealthKit hasn't answered after \(Int(seconds)) s, moving on", category: "workout")
                }
                continuation.resume(returning: value)
            }
            Task { resume(await task.value, timedOut: false) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resume(nil, timedOut: true)
            }
        }
    }

    /// Write the whole route at once, from the fixes we kept.
    ///
    /// Not inserted live: a route builder loses everything if the app goes away, and a single
    /// failed insert is fatal to it (per its header) — the rest of the match then goes nowhere,
    /// silently. From a complete copy, a failure costs one retry with a fresh builder.
    private func saveRoute(_ fixes: [RouteFix], to workout: HKWorkout) async {
        let locations = fixes.map(\.location)
        for attempt in 1...2 {
            do {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
                for batchStart in stride(from: 0, to: locations.count, by: 1000) {
                    let batch = locations[batchStart..<min(batchStart + 1000, locations.count)]
                    try await routeBuilder.insertRouteData(Array(batch))
                }
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
                MatchLog.info("endMatch: route saved to HealthKit (\(locations.count) points, attempt \(attempt))",
                              category: "workout")
                return
            } catch {
                MatchLog.error("endMatch: route save attempt \(attempt) failed: \(error.localizedDescription)",
                               category: "workout")
            }
        }
    }

    /// Feeds the widget's last-match Smart Stack card.
    private func writeLastMatchSnapshot(_ match: FinishingMatch, record: MatchRecord, sprintCount: Int) {
        let fieldName = record.fieldID
            .flatMap { id in AppGroupStorage.fieldStore.fields.first { $0.id == id }?.name }
        let snapshot = LastMatchSnapshot(
            matchID: record.id,
            endDate: match.end,
            fieldName: fieldName,
            durationSeconds: match.elapsed,
            timeOnPitchSeconds: SubstitutionTracker.timeOnPitch(events: record.events,
                                                                matchStart: record.startDate,
                                                                matchEnd: match.end),
            distanceMeters: match.distanceMeters,
            goalsUs: match.score.us,
            goalsThem: match.score.them,
            sprintCount: sprintCount
        )
        do {
            try snapshot.save(to: AppGroupStorage.containerURL)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            MatchLog.error("Snapshot write failed: \(error.localizedDescription)", category: "widgets")
        }
    }

    /// Return to the start screen. Clears what's on screen only — a match still being saved has
    /// its own copy of everything (`FinishingMatch`).
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
        pausedTotal = 0
        pauseStarted = nil
        onPitch = true
        autoSubDetector = nil
        autoSubBanner = nil
        session = nil
        builder = nil
        collectionBegan = false
        sessionState = .notStarted
        phase = .idle
    }

    private func resetForNewMatch(field: FieldModel?) {
        matchID = UUID()
        fieldID = isIndoor ? nil : field?.id
        startFailure = nil
        sessionState = .notStarted
        sessionLost = false
        sessionStarting = false
        sessionAttempts = 0
        healthCollectionStalled = false
        collectionBegan = false
        autoSubDetector = field.flatMap(makeAutoSubDetector)
        autoSubBanner = nil
        events = []
        track = []
        recentLocations = []
        heartRate = 0
        activeCalories = 0
        distanceMeters = 0
        currentSpeed = 0
        elapsedAtPause = 0
        pausedTotal = 0
        pauseStarted = nil
        onPitch = true
        finishedWorkout = nil
        finishedRecord = nil
        proposedField = nil
        summaryAverageHeartRate = nil
        summaryRunCounts = nil
    }

    /// A resolved field gives the detector a touchline to reason about; without one, automatic
    /// substitution detection is off. Referees are never "subbed", and indoor has no GPS.
    private func makeAutoSubDetector(for field: FieldModel) -> AutoSubDetector? {
        guard !WatchSettings.refereeMode, !isIndoor else { return nil }
        return AutoSubDetector(projector: FieldProjector(rectangle: field.rectangle), initiallyOnPitch: onPitch)
    }

    private func persistInProgress() {
        // Snapshot the observable state here (cheap); build, encode and write on the serial
        // persist queue (ordered, so a later snapshot can never be clobbered). `teamCode` reads
        // shared preferences, which is a system round-trip and belongs off the event path with
        // the rest of it — this runs after every logged event, match start and match end included.
        let id = matchID
        let start = matchStartDate
        let field = fieldID
        let loggedEvents = events
        let format = matchFormat
        persistQueue.async {
            var record = MatchRecord(
                id: id,
                startDate: start,
                endDate: nil,
                fieldID: field,
                events: loggedEvents,
                teamCode: AppGroupStorage.teamCode
            )
            record.format = format
            AppGroupStorage.persistInProgress(record)
        }
    }

    /// Clears one match's crash-safety record on the persist queue, behind any queued writes —
    /// never another's: the next match may already be writing to the same file.
    private func clearInProgress(matchID: UUID) {
        persistQueue.async {
            guard AppGroupStorage.loadInProgress()?.id == matchID else { return }
            AppGroupStorage.clearInProgress()
        }
    }

    // MARK: - Location

    /// New fixes from the recorder (already on disk). Runs on the main queue.
    private func ingest(_ fixes: [RouteFix]) {
        let points = fixes.map(\.point)
        track.append(contentsOf: points)
        recentLocations.append(contentsOf: fixes)
        if recentLocations.count > 10 {
            recentLocations.removeFirst(recentLocations.count - 10)
        }
        recomputeCurrentSpeed()
        resolveFieldIfNeeded()
        runAutoSubDetection(on: points)
    }

    /// Match the field from the route's own fixes when the start screen hadn't yet. Most matches
    /// start within a couple of seconds of opening the app, before a one-shot lookup can answer.
    private func resolveFieldIfNeeded() {
        guard fieldID == nil, !isIndoor, track.count >= 10, track.count <= 600, track.count.isMultiple(of: 10)
        else { return }
        let samples = track.suffix(30).filter { $0.horizontalAccuracy <= 20 }.map(\.coordinate)
        guard samples.count >= 5, let field = AppGroupStorage.fieldStore.bestMatch(for: samples) else { return }
        fieldID = field.id
        autoSubDetector = makeAutoSubDetector(for: field)
        MatchLog.info("field: resolved \(field.name) after \(track.count) fixes", category: "location")
        persistInProgress()
    }

    private func recomputeCurrentSpeed() {
        let speeds = recentLocations.suffix(5).map(\.point.speedMetersPerSecond).filter { $0 >= 0 }
        currentSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
    }

    // MARK: - Session recovery

    /// Called on launch to reattach to a session that survived the app being suspended/killed, or
    /// failing that to save whatever an interrupted match left on disk.
    ///
    /// Reached from both the launch task and the crash-recovery delegate; only one may run, or the
    /// second replaces the session the first just restored.
    @MainActor
    func recoverActiveWorkoutSession() async {
        guard phase == .idle, session == nil, !recoveryInFlight else { return }
        recoveryInFlight = true
        defer { recoveryInFlight = false }
        let store = healthStore
        let recovering = Task { try? await store.recoverActiveWorkoutSession() }
        let recovered = await Self.value(of: recovering, within: 4)
        // Start was tapped while HealthKit was answering: that match owns the session now.
        guard phase == .idle, session == nil else {
            MatchLog.info("recovery: skipped, a match is already under way", category: "workout")
            return
        }
        if let recovered, recovered.state == .running || recovered.state == .paused {
            restore(recovered)
        } else {
            recovered?.end()
            // The session is gone (or HealthKit isn't answering), but the match may not be.
            if let interrupted = interruptedMatch(), Date().timeIntervalSince(interrupted.lastSeen) < resumableInterval {
                restore(nil)
            } else {
                salvageInterruptedMatch()
            }
        }
    }

    /// An interrupted match seen this recently is still being played.
    private let resumableInterval: TimeInterval = 15 * 60

    /// The match on disk that was never ended, with its route and when it last recorded anything.
    private func interruptedMatch() -> (record: MatchRecord, track: [TrackPoint], lastSeen: Date)? {
        guard let record = AppGroupStorage.loadInProgress() else { return nil }
        let track = RouteJournal(directory: AppGroupStorage.containerURL, matchID: record.id).load().map(\.point)
        let lastSeen = [track.last?.timestamp, record.events.map(\.date).max()].compactMap { $0 }.max()
        return (record, track, lastSeen ?? record.startDate)
    }

    /// Reattach delegates/metrics to a recovered session and pick the match back up from disk —
    /// events from the in-progress record, the route from its journal.
    /// Without a session, the match carries on from disk alone and asks HealthKit for a new one.
    @MainActor
    private func restore(_ recovered: HKWorkoutSession?) {
        // Only if it's this session's record, not one an earlier match left behind.
        var saved = AppGroupStorage.loadInProgress()
        let sessionStart = recovered?.startDate ?? saved?.startDate ?? Date()
        if let record = saved, abs(record.startDate.timeIntervalSince(sessionStart)) > 180 {
            salvageInterruptedMatch()
            saved = nil
        }

        // Falls back to the config's location type, which distinguishes indoor from outdoor.
        matchFormat = saved?.format
            ?? (recovered?.workoutConfiguration.locationType == .indoor ? .indoor : .match)
        resetForNewMatch(field: nil)
        if let recovered {
            let builder = recovered.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                         workoutConfiguration: recovered.workoutConfiguration)
            recovered.delegate = self
            builder.delegate = self
            session = recovered
            self.builder = builder
            collectionBegan = true
            sessionState = recovered.state
        }
        matchID = saved?.id ?? matchID
        matchStartDate = saved?.startDate ?? sessionStart
        fieldID = saved?.fieldID
        events = saved?.events ?? []
        // Restore on-pitch state from the last substitution event (a subIn or subOut), ignoring
        // any later non-sub events that would otherwise mask it.
        onPitch = events.last { $0.kind == .subIn || $0.kind == .subOut }?.kind != .subOut
        autoSubDetector = AppGroupStorage.fieldStore.fields.first { $0.id == fieldID }
            .flatMap(makeAutoSubDetector)

        if !isIndoor {
            routeRecorder.arm()
            routeRecorder.beginRecording(matchID: matchID, start: matchStartDate, resuming: true)
            track = routeRecorder.fixes.map(\.point)
            headingRecorder.start()
        }
        liveStreamer.start { [weak self] in self?.makeLiveUpdate() }
        phase = .active
        persistInProgress()
        if recovered == nil { startWorkoutSession() }
        MatchLog.info("recovery: match restored (session \(recovered == nil ? "gone" : "recovered"), \(Int(Date().timeIntervalSince(matchStartDate))) s in, \(events.count) events, \(track.count) fixes)",
                      category: "workout")
    }

    /// Turn a match that was never ended — the app and its session both died — into a finished
    /// record, so its events and route reach the phone instead of being overwritten by the next.
    @MainActor
    private func salvageInterruptedMatch() {
        guard let interrupted = interruptedMatch() else { return }
        var record = interrupted.record
        let track = interrupted.track
        let lastSeen = interrupted.lastSeen
        if lastSeen.timeIntervalSince(record.startDate) >= minimumMatchDuration {
            record.endDate = lastSeen
            record.track = track.isEmpty ? nil : track
            guard AppGroupStorage.persistFinished(record) != nil else { return }
            MatchLog.info("recovery: salvaged an interrupted match (\(record.events.count) events, \(track.count) fixes)",
                          category: "workout")
            ConnectivityManager.shared.send(matchRecord: record)
        }
        routeRecorder.removeJournal(matchID: record.id)
        AppGroupStorage.clearInProgress()
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
            // A previous match's session finishing must not touch this one.
            guard workoutSession === self.session else { return }
            self.applySessionState(toState)
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        MatchLog.error("workout session failed: \(error.localizedDescription)", category: "workout")
        DispatchQueue.main.async {
            guard workoutSession === self.session else { return }
            self.sessionFailed(error, matchID: self.matchID)
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
            guard workoutBuilder === self.builder else { return }
            if let newHeartRate { self.heartRate = newHeartRate }
            if let newCalories { self.activeCalories = newCalories }
            if let newDistance { self.distanceMeters = newDistance }
        }
    }
}

// MARK: - Automatic substitutions

extension WorkoutManager {
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
}
