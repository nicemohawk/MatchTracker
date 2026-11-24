// MatchStage.swift
// MatchTracker

import MatchTrackerKit
import SwiftUI

/// The match as a picture you can play: where you were, then — scrubbing or playing — when.
struct MatchStage: View {
    let clock: StageClock
    let analytics: MatchAnalytics
    let events: [MatchEvent]
    let seasonHeat: [Float]?
    let height: CGFloat
    /// Told whether the wearer attacked up the screen, when that isn't known.
    var onDirection: ((Bool) -> Void)?

    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duration: TimeInterval { analytics.interval.duration }
    private var runsHeight: CGFloat { min(height, 350) }
    private var isSeason: Bool { clock.mode == .season }
    /// Whether a moment, rather than the whole match, was asked for.
    private var isTimed: Bool { clock.time != nil && !clock.isOpening }

    private var modes: [StageClock.Mode] {
        StageClock.Mode.allCases.filter { mode in
            switch mode {
            case .heat: return true
            case .runs: return !analytics.matchRuns.isEmpty
            case .season: return seasonHeat != nil
            }
        }
    }

    var body: some View {
        let marks = isSeason ? [] : marks
        VStack(spacing: 14) {
            pitch(marks: marks)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .gesture(scrub)
                .accessibilityAdjustableAction { direction in
                    guard !isSeason, clock.mode != .runs else { return }
                    clock.scrub(to: (clock.time ?? 0) + (direction == .increment ? 300 : -300))
                }
                .accessibilityValue(spokenValue)
                .overlay(alignment: .topLeading) { time }
                .overlay(alignment: .bottom) { controls }

            VStack(spacing: 14) {
                if modes.count > 1 {
                    Picker("Show", selection: Binding(get: { clock.mode }, set: { clock.select($0) })) {
                        ForEach(modes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if clock.mode == .runs {
                    RunStrip(clock: clock, analytics: analytics, events: events)
                    RunDetailCard(clock: clock, analytics: analytics, report: analytics.runReport,
                                  onDirection: analytics.isDirectionConfident ? nil : onDirection)
                } else if isTimed {
                    timeline.transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal)
            .animation(reduceMotion ? nil : .snappy, value: isTimed)
        }
        .onChange(of: modes) { _, modes in
            if !modes.contains(clock.mode) { clock.select(.heat) }
        }
        .sensoryFeedback(.selection, trigger: clock.choices)
        .sensoryFeedback(.impact(weight: .light), trigger: marks.count) { before, after in
            after > before && (clock.isPlaying || clock.isOpening)
        }
    }

    // MARK: - Picture

    private func pitch(marks: [PitchMark]) -> some View {
        let picture = heat
        let player = isTimed ? clock.time : nil
        return HeatPitch(heat: picture.heat, heatReference: picture.reference,
                         heatOpacity: clock.mode == .runs ? 0.12 : 1,
                         size: PitchSize(analytics.rectangle), marks: marks,
                         runs: clock.mode == .runs ? runs : [],
                         currentPosition: player.flatMap { clock.film?.player(at: $0) },
                         trail: player.flatMap { clock.film?.trail(at: $0) } ?? [],
                         insets: Self.insets,
                         directionIsKnown: analytics.isDirectionConfident)
            // The runs share the screen with what's said about them.
            .frame(height: clock.mode == .runs ? runsHeight : height)
            .onTapGesture { location in pickRun(at: location) }
    }

    /// The run nearest a tap, if it was on one.
    private func pickRun(at location: CGPoint) {
        guard clock.mode == .runs, width > 0 else { return }
        let artist = PitchArtist(size: PitchSize(analytics.rectangle), canvas: CGSize(width: width, height: runsHeight),
                                 insets: Self.insets)
        let nearest = analytics.matchRuns.compactMap { run -> (id: UUID, distance: CGFloat)? in
            run.points.map { point in
                let place = artist.place(PitchPoint(point))
                return hypot(place.x - location.x, place.y - location.y)
            }.min().map { (run.id, $0) }
        }.min { $0.distance < $1.distance }
        clock.pick(nearest.flatMap { $0.distance < 28 ? $0.id : nil })
    }

    private static let insets = EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 12)

    private var heat: (heat: PitchHeat, reference: Float?) {
        if isSeason, let seasonHeat { return (PitchHeat(digestHeat: seasonHeat), nil) }
        if let time = clock.time, let built = clock.buildUp?.heat(at: time) { return (built.heat, built.reference) }
        return (PitchHeat(analytics), nil)
    }

    private var marks: [PitchMark] {
        events.compactMap { event in
            let kind: PitchMark.Kind
            switch event.kind {
            case .goalMine: kind = .goal
            case .assist: kind = .assist
            default: return nil
            }
            let offset = event.date.timeIntervalSince(analytics.interval.start)
            if let time = clock.time, offset > time { return nil }
            return position(at: offset).map { PitchMark(kind: kind, point: $0, scale: landing(of: offset)) }
        }
    }

    /// A goal lands rather than appearing.
    private func landing(of offset: TimeInterval) -> Double {
        guard clock.isPlaying || clock.isOpening, let film = clock.film, let time = clock.time,
              offset >= film.time(at: 0) else { return 1 }
        let age = film.screenTime(of: time) - film.screenTime(of: offset)
        return 1 + 0.9 * pow(max(0, 1 - age / 0.4), 2)
    }

    private var runs: [PitchRun] {
        analytics.matchRuns.filter { $0.points.count >= 2 }.map { run in
            let isPicked = run.id == clock.spotlight
            var line = PitchRun(points: run.points.map { PitchPoint($0) }, isBest: isPicked, yarn: run.heading?.yarn)
            guard clock.spotlight != nil else { return line }
            if isPicked {
                line.label = UnitSystem.current.speed(run.peakSpeed).text
                line.yarn = KitColors.ivory
                if let time = clock.time, run.toT > run.fromT {
                    line.progress = min(max((time - run.fromT) / (run.toT - run.fromT), 0), 1)
                }
            } else {
                line.opacity = 0.22
            }
            return line
        }
    }

    private func position(at time: TimeInterval) -> PitchPoint? {
        let path = analytics.pitchPath
        guard !path.isEmpty else { return nil }
        var low = 0, high = path.count - 1
        while low < high {
            let middle = (low + high) / 2
            if path[middle].t < time { low = middle + 1 } else { high = middle }
        }
        let after = path[low], before = path[max(low - 1, 0)]
        guard abs(after.t - time) < 30 else { return nil }
        let span = after.t - before.t
        let fraction = span > 0 ? min(max((time - before.t) / span, 0), 1) : 0
        return PitchPoint(across: before.x + (after.x - before.x) * fraction,
                          up: before.y + (after.y - before.y) * fraction)
    }

    // MARK: - Time

    private var minutes: MatchMinutes { MatchMinutes(kickoff: analytics.interval.start, halftime: analytics.halftime) }

    private func date(at time: TimeInterval) -> Date { analytics.interval.start.addingTimeInterval(time) }

    private var spokenValue: String {
        let runs = analytics.runReport
        return [clock.time.map { minutes.spoken(for: date(at: $0)) },
                clock.mode == .runs ? "\(runs.runs.count) runs. \(runs.headline ?? "")" : nil].compactMap { $0 }.joined(separator: ". ")
    }

    @ViewBuilder
    private var time: some View {
        if let time = clock.time {
            Text(minutes.text(for: date(at: time)))
                .font(.system(.title, weight: .heavy).width(.compressed))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(16)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if !isSeason {
            HStack {
                // Among the runs there's only one worth playing: the one picked out.
                if clock.mode != .runs || clock.spotlight != nil {
                    Button { clock.isPlaying ? clock.pause() : play() } label: {
                        StageSymbol(title: clock.isPlaying ? "Pause" : "Play", name: clock.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                Spacer()
                if isTimed, clock.mode != .runs {
                    Button { clock.showWholeMatch() } label: {
                        StageSymbol(title: "Whole Match", name: "arrow.counterclockwise")
                    }
                }
            }
            .modifier(StageButtons())
            .padding(12)
        }
    }

    private func play() {
        if clock.mode == .runs, let run = analytics.matchRuns.first(where: { $0.id == clock.spotlight }) {
            clock.show(run)
        } else {
            clock.play()
        }
    }

    private var timeline: some View {
        let time = clock.time ?? duration
        return Slider(value: Binding(get: { time }, set: { clock.scrub(to: $0) }), in: 0...max(duration, 1))
            .accessibilityLabel("Match time")
            .accessibilityValue(minutes.spoken(for: date(at: time)))
            .frame(minHeight: 44)
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !isSeason, clock.mode != .runs, width > 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                clock.scrub(to: value.location.x / width * duration)
            }
    }
}

/// One size, whatever the symbol: 44 points once the button has its padding.
private struct StageSymbol: View {
    let title: String
    let name: String
    @ScaledMetric(relativeTo: .title3) private var side = 24.0

    var body: some View {
        Image(systemName: name).frame(width: side, height: side).accessibilityLabel(title)
    }
}

/// Round system buttons that sit on the turf, which is dark whatever the appearance.
private struct StageButtons: ViewModifier {
    func body(content: Content) -> some View {
        let buttons = content
            .font(.title3)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(.white)
        Group {
            if #available(iOS 26.0, *) {
                buttons.buttonStyle(.glass)
            } else {
                buttons.buttonStyle(.bordered)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
