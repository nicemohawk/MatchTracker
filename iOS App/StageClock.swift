// StageClock.swift
// MatchTracker

import MatchTrackerKit
import QuartzCore
import SwiftUI

/// Where the stage is in the match and what it's showing. One per match screen, so any minute
/// mentioned on it can be sent to the picture.
@MainActor
@Observable
final class StageClock {
    enum Mode: String, CaseIterable, Identifiable {
        case heat = "Match", runs = "Runs", season = "Season"
        var id: String { rawValue }
    }

    private(set) var mode: Mode = .heat
    /// Seconds into the match while scrubbing or playing; nil shows the whole match.
    private(set) var time: TimeInterval?
    private(set) var isPlaying = false
    /// The first time a match is opened, its picture builds itself up.
    private(set) var isOpening = false
    /// The run being shown on its own.
    private(set) var spotlight: UUID?
    /// Counts what the reader picks, for the haptic.
    private(set) var choices = 0
    private(set) var film: StageFilm?
    private(set) var buildUp: HeatBuildUp?

    @ObservationIgnored private var analytics: MatchAnalytics?
    @ObservationIgnored private var events: [MatchEvent] = []
    @ObservationIgnored private var frames: FrameTimer?
    /// Whether the film is a stretch of the match rather than all of it.
    @ObservationIgnored private var isClip = false

    private static let filmSeconds = 15.0
    private static let calmFilmSeconds = 8.0
    private static let openingSeconds = 5.5
    /// Screen seconds before the opening starts, while the screen is still sliding in.
    private static let openingLead = 0.5
    /// A run or a moment plays at twice its speed.
    private static let clipSpeed = 2.0

    var duration: TimeInterval { analytics?.interval.duration ?? 0 }

    /// Takes on an analysis, without interrupting whatever is playing: one often follows another as
    /// a match is opened.
    func load(_ analytics: MatchAnalytics, events: [MatchEvent]) {
        self.analytics = analytics
        self.events = events
        buildUp = HeatBuildUp(analytics)
        // Its runs are new ones.
        spotlight = nil
        if !isPlaying, !isOpening { filmWholeMatch() }
    }

    func select(_ mode: Mode) {
        choices += 1
        self.mode = mode
        spotlight = nil
        if mode == .season { showWholeMatch() }
    }

    // MARK: Time

    func play() {
        spotlight = nil
        filmWholeMatch()
        guard let film else { return }
        let begin = time ?? 0
        run(from: film.screenTime(of: begin) < film.duration ? begin : 0) { $0.showWholeMatch() }
    }

    func pause() {
        if isOpening { endOpening() } else { stop() }
    }

    func scrub(to time: TimeInterval) {
        stop()
        spotlight = nil
        if isClip { filmWholeMatch() }
        self.time = min(max(time, 0), duration)
    }

    func showWholeMatch() {
        stop()
        time = nil
        spotlight = nil
    }

    /// Plays a run from just before it to just after, drawing it.
    func show(_ run: KeyRun) {
        choices += 1
        mode = .runs
        spotlight = run.id
        playClip(from: run.fromT - 3, to: run.toT + 2)
    }

    /// Plays the lead-up to a moment.
    func show(_ event: MatchEvent) {
        guard let analytics else { return }
        choices += 1
        mode = .heat
        spotlight = nil
        let moment = event.date.timeIntervalSince(analytics.interval.start)
        playClip(from: moment - 12, to: moment + 4)
    }

    /// Once per match, and never for somebody who'd rather things kept still.
    func playOpening(of match: UUID) {
        guard let analytics, time == nil, OpenedMatches.insert(match),
              !UIAccessibility.isReduceMotionEnabled, !UIAccessibility.isVoiceOverRunning,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        film = StageFilm(analytics: analytics, events: events, duration: Self.openingSeconds, lead: Self.openingLead)
        run(from: 0) { $0.endOpening() }
        isPlaying = false
        isOpening = true
    }

    func endOpening() {
        guard isOpening else { return }
        showWholeMatch()
        filmWholeMatch()
    }

    private func filmWholeMatch() {
        isClip = false
        film = analytics.map {
            StageFilm(analytics: $0, events: events,
                      duration: UIAccessibility.isReduceMotionEnabled ? Self.calmFilmSeconds : Self.filmSeconds)
        }
    }

    private func playClip(from: TimeInterval, to: TimeInterval) {
        guard let analytics else { return }
        let from = min(max(from, 0), duration), to = min(max(to, from), duration)
        film = StageFilm(analytics: analytics, from: from, to: to, speed: Self.clipSpeed)
        isClip = true
        if UIAccessibility.isReduceMotionEnabled {
            hold(at: to)
        } else {
            run(from: from) { $0.hold(at: to) }
        }
    }

    private func hold(at time: TimeInterval) {
        stop()
        self.time = time
    }

    private func run(from begin: TimeInterval, then finish: @escaping (StageClock) -> Void) {
        stop()
        guard let film else { return }
        time = begin
        isPlaying = true
        let offset = film.screenTime(of: begin)
        // Without motion, the match steps forward rather than flying past.
        let framesPerSecond = UIAccessibility.isReduceMotionEnabled ? 4 : 60
        frames = FrameTimer(framesPerSecond: framesPerSecond) { [weak self] elapsed in
            guard let self else { return }
            if offset + elapsed < film.duration {
                time = min(film.time(at: offset + elapsed), duration)
            } else {
                finish(self)
            }
        }
    }

    private func stop() {
        frames?.stop()
        frames = nil
        isPlaying = false
        isOpening = false
    }
}

/// Calls back on every frame until stopped.
@MainActor
private final class FrameTimer: NSObject {
    private var link: CADisplayLink?
    private var started: CFTimeInterval?
    private let onFrame: (TimeInterval) -> Void

    init(framesPerSecond: Int, onFrame: @escaping (TimeInterval) -> Void) {
        self.onFrame = onFrame
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(framesPerSecond, 30)),
                                                        maximum: Float(framesPerSecond), preferred: Float(framesPerSecond))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The link holds on to its target until it's told to stop.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let started = started ?? link.timestamp
        self.started = started
        onFrame(link.timestamp - started)
    }
}

/// Which matches have had their opening.
private enum OpenedMatches {
    /// Enough that nobody scrolls back far enough to see one twice.
    private static let limit = 500

    /// - Returns: Whether this is the first time.
    static func insert(_ match: UUID) -> Bool {
        var opened = AppGroup.defaults.stringArray(forKey: AppGroup.DefaultsKey.openedMatches) ?? []
        guard !opened.contains(match.uuidString) else { return false }
        opened.append(match.uuidString)
        AppGroup.defaults.set(Array(opened.suffix(limit)), forKey: AppGroup.DefaultsKey.openedMatches)
        return true
    }
}

// MARK: - What plays

/// Which moment of the match is on screen at each moment of playing it, and where the player was.
/// The share film's rules: half-time flies by, goals linger, and the path is smoothed in screen time
/// so the dot glides rather than jumps.
struct StageFilm {
    private static let ticksPerSecond = 60.0
    /// How much of the path the dot drags behind it.
    private static let trailSeconds = 1.1
    /// A longer hole than this is the bench, a break or lost GPS.
    private static let longestGap = 15.0

    /// Seconds into the match at each tick of the screen, never going back.
    private let times: [TimeInterval]
    /// Nil off the pitch or between halves.
    private let path: [PitchPoint?]

    var duration: Double { Double(times.count - 1) / Self.ticksPerSecond }

    /// The whole match.
    /// - Parameter lead: Screen seconds before kickoff.
    init(analytics: MatchAnalytics, events: [MatchEvent], duration: Double, lead: Double = 0) {
        // A recording left running isn't worth watching run.
        let end = analytics.playingIntervals.map(\.end).max() ?? analytics.interval.end
        let whole = DateInterval(start: analytics.interval.start, end: max(end, analytics.interval.start))
        var periods = [whole]
        if let halftime = analytics.halftime, whole.contains(halftime.start), whole.contains(halftime.end) {
            periods = [DateInterval(start: whole.start, end: halftime.start),
                       DateInterval(start: halftime.end, end: whole.end)]
        }
        let moments = events.compactMap { event -> ReplayTimeline.Moment? in
            switch event.kind {
            case .goalMine, .goalForUs, .goalAgainstUs, .assist:
                return ReplayTimeline.Moment(interval: DateInterval(start: event.date.addingTimeInterval(-6), duration: 16),
                                             extraScreenSeconds: event.kind == .assist ? 0.3 : 0.5)
            default: return nil
            }
        }
        let timeline = ReplayTimeline(periods: periods, playing: analytics.playingIntervals, moments: moments,
                                      duration: lead + duration, opening: lead, pause: 0.6, closing: 0)
        let count = Int((lead + duration) * Self.ticksPerSecond)
        self.init(analytics: analytics, times: (0...count).map { tick in
            let screen = Double(tick) / Self.ticksPerSecond
            switch timeline.phase(at: screen) {
            case .opening: return 0
            case .playing(let index):
                return timeline.matchDate(at: screen, in: timeline.chapters[index]).timeIntervalSince(whole.start)
            case .pause(let index, let progress):
                let from = timeline.chapters[index].period.end, to = timeline.chapters[index + 1].period.start
                return from.timeIntervalSince(whole.start) + to.timeIntervalSince(from) * progress
            case .closing: return whole.duration
            }
        })
    }

    /// A stretch of it, `speed` times as fast as it happened.
    init(analytics: MatchAnalytics, from: TimeInterval, to: TimeInterval, speed: Double) {
        let count = max(1, Int((to - from) / speed * Self.ticksPerSecond))
        self.init(analytics: analytics, times: (0...count).map { from + (to - from) * Double($0) / Double(count) })
    }

    private init(analytics: MatchAnalytics, times: [TimeInterval]) {
        self.times = times
        let samples = analytics.pitchPath.filter(\.onPitch)
        var index = 0
        let raw = times.map { time -> PitchPoint? in
            while index + 1 < samples.count, samples[index + 1].t <= time { index += 1 }
            return samples.isEmpty ? nil : Self.place(at: time, after: index, in: samples)
        }
        let sigma = 0.11 * Self.ticksPerSecond
        let radius = Int(sigma * 2.5)
        path = raw.indices.map { position in
            guard raw[position] != nil else { return nil }
            var across = 0.0, up = 0.0, total = 0.0
            for neighbor in max(0, position - radius)...min(raw.count - 1, position + radius) {
                guard let point = raw[neighbor] else { continue }
                let offset = Double(neighbor - position) / sigma
                let weight = exp(-offset * offset / 2)
                across += point.across * weight
                up += point.up * weight
                total += weight
            }
            return PitchPoint(across: across / total, up: up / total)
        }
    }

    private static func place(at time: TimeInterval, after index: Int, in samples: [PitchSample]) -> PitchPoint? {
        let from = samples[index]
        guard index + 1 < samples.count, time >= from.t, samples[index + 1].t - from.t < longestGap else {
            return abs(time - from.t) < longestGap ? PitchPoint(from) : nil
        }
        let to = samples[index + 1]
        let share = to.t > from.t ? (time - from.t) / (to.t - from.t) : 0
        return PitchPoint(across: from.x + (to.x - from.x) * share, up: from.y + (to.y - from.y) * share)
    }

    func time(at screenTime: Double) -> TimeInterval {
        let position = min(max(screenTime * Self.ticksPerSecond, 0), Double(times.count - 1))
        let index = min(Int(position), times.count - 2)
        return times[index] + (times[index + 1] - times[index]) * (position - Double(index))
    }

    func screenTime(of time: TimeInterval) -> Double { tick(of: time) / Self.ticksPerSecond }

    private func tick(of time: TimeInterval) -> Double {
        var low = 0, high = times.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if times[middle] < time { low = middle } else { high = middle }
        }
        let span = times[high] - times[low]
        return Double(low) + (span > 0 ? min(max((time - times[low]) / span, 0), 1) : 0)
    }

    func player(at time: TimeInterval) -> PitchPoint? {
        // Half a second's grace: the last tick and the final whistle can differ by a rounding.
        guard let first = times.first, let last = times.last, time >= first - 0.5, time <= last + 0.5 else { return nil }
        let position = tick(of: time)
        let index = Int(position)
        guard let from = path[index] else { return nil }
        guard index + 1 < path.count, let to = path[index + 1] else { return from }
        let share = position - Double(index)
        return PitchPoint(across: from.across + (to.across - from.across) * share, up: from.up + (to.up - from.up) * share)
    }

    /// Where the player has just been, oldest first, ending where they are.
    func trail(at time: TimeInterval) -> [PitchPoint] {
        guard let player = player(at: time) else { return [] }
        var points = [player]
        var index = Int(tick(of: time))
        let oldest = max(0, index - Int(Self.trailSeconds * Self.ticksPerSecond))
        while index >= oldest, let point = path[index] {
            points.append(point)
            index -= 1
        }
        return points.reversed()
    }
}

/// The heat as it stood at any moment, so playing the match builds the picture up.
@MainActor
final class HeatBuildUp {
    private let samples: [(time: TimeInterval, point: PitchPoint, seconds: Double)]
    private let wholeMatch: Float
    private var accumulator = PitchHeat.Accumulator()
    private var count = 0

    init(_ analytics: MatchAnalytics) {
        let path = analytics.pitchPath
        samples = path.indices.compactMap { index in
            guard path[index].onPitch else { return nil }
            let gap = index + 1 < path.count ? path[index + 1].t - path[index].t : 0
            return (path[index].t, PitchPoint(path[index]), min(gap, 10))
        }
        wholeMatch = HeatImage.reference(for: PitchHeat(samples: samples.map { ($0.point, $0.seconds) }),
                                         size: PitchSize(analytics.rectangle))
    }

    /// - Returns: The heat, and the level that counts as fully hot.
    func heat(at time: TimeInterval) -> (heat: PitchHeat, reference: Float) {
        if count > 0, samples[count - 1].time > time {
            accumulator = PitchHeat.Accumulator()
            count = 0
        }
        while count < samples.count, samples[count].time <= time {
            accumulator.add(samples[count].point, seconds: samples[count].seconds)
            count += 1
        }
        // Early on, judge heat against less than the full match so something shows.
        let share = samples.isEmpty ? 0 : Float(count) / Float(samples.count)
        return (accumulator.heat, wholeMatch * (0.22 + 0.78 * share))
    }
}
