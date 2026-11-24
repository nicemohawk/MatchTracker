// MatchStage.swift
// MatchTracker

import MatchTrackerKit
import SwiftUI

/// The match as a picture you can play: where you were, then — scrubbing or playing — when.
struct MatchStage: View {
    let analytics: MatchAnalytics
    let events: [MatchEvent]
    let matchStart: Date
    let seasonHeat: [Float]?

    enum Mode: String, CaseIterable, Identifiable {
        case heat = "Match", runs = "Runs", season = "Season"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .heat
    /// Seconds into the match while scrubbing or playing; nil shows the whole match.
    @State private var time: TimeInterval?
    @State private var playback: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var duration: TimeInterval { analytics.interval.duration }
    private var modes: [Mode] { seasonHeat == nil ? [.heat, .runs] : Mode.allCases }

    var body: some View {
        VStack(spacing: 14) {
            HeatPitch(heat: heat, size: size,
                      marks: mode == .season ? [] : marks,
                      runs: mode == .runs ? runs : [],
                      currentPosition: currentPosition,
                      directionIsKnown: analytics.isDirectionConfident)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 320 : 430)
                .overlay(alignment: .topLeading) { clock }
                .gesture(scrub)
                .accessibilityAdjustableAction { direction in
                    let step: TimeInterval = 300
                    let now = time ?? 0
                    time = min(max(now + (direction == .increment ? step : -step), 0), duration)
                }
                .accessibilityValue(time.map { "At \(minute($0)) minutes" } ?? "")

            VStack(spacing: 14) {
                timeline
                if modes.count > 1 {
                    Picker("Show", selection: $mode) {
                        ForEach(modes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal)
        }
        .onDisappear { playback?.cancel() }
        .sensoryFeedback(.selection, trigger: mode)
    }

    // MARK: - Picture

    private var size: PitchSize {
        PitchSize(lengthMeters: analytics.rectangle.lengthMeters, widthMeters: analytics.rectangle.widthMeters)
    }

    private var heat: PitchHeat {
        switch mode {
        case .season: return seasonHeat.map { PitchHeat(digestHeat: $0) } ?? PitchHeat(analytics) ?? .empty
        case .heat, .runs: return time.map(heat(upTo:)) ?? PitchHeat(analytics) ?? .empty
        }
    }

    /// The heat as it stood at `time`, so playing the match builds the picture up.
    private func heat(upTo time: TimeInterval) -> PitchHeat {
        // Steps of two minutes: the picture is rendered off the main thread and cached per step.
        let step = (time / 120).rounded(.up) * 120
        var accumulator = PitchHeat.Accumulator()
        var previous: PitchSample?
        for sample in analytics.pitchPath {
            guard sample.t <= step else { break }
            if sample.onPitch, let previous {
                accumulator.add(PitchPoint(across: sample.x, up: sample.y), seconds: min(sample.t - previous.t, 10))
            }
            previous = sample
        }
        return accumulator.heat
    }

    private var marks: [PitchMark] {
        events.compactMap { event in
            let kind: PitchMark.Kind
            switch event.kind {
            case .goalMine: kind = .goal
            case .assist: kind = .assist
            default: return nil
            }
            let offset = event.date.timeIntervalSince(matchStart)
            if let time, offset > time { return nil }
            return position(at: offset).map { PitchMark(kind: kind, point: $0) }
        }
    }

    private var runs: [PitchRun] {
        analytics.keyRuns.map { run in
            PitchRun(points: run.points.map { PitchPoint(across: $0.x, up: $0.y) },
                     isBest: run.categories.contains(.fastest))
        }
    }

    private var currentPosition: PitchPoint? {
        guard mode != .season, let time else { return nil }
        return position(at: time)
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

    @ViewBuilder
    private var clock: some View {
        if let time {
            Text("\(minute(time))′")
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(16)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Time

    private func minute(_ time: TimeInterval) -> Int { Int(time / 60) + 1 }

    private var timeline: some View {
        HStack(spacing: 14) {
            Button(playback == nil ? "Play" : "Pause", systemImage: playback == nil ? "play.fill" : "pause.fill") {
                playback == nil ? play() : pause()
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)

            Slider(value: Binding(get: { time ?? duration }, set: { pause(); time = $0 }), in: 0...max(duration, 1))
                .accessibilityLabel("Match time")
                .accessibilityValue("\(minute(time ?? duration)) minutes")

            if time != nil {
                Button("Whole Match", systemImage: "arrow.counterclockwise") { pause(); time = nil }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                pause()
                let fraction = min(max(value.location.x / max(UIScreen.main.bounds.width, 1), 0), 1)
                time = fraction * duration
            }
    }

    /// The whole match in fifteen seconds.
    private func play() {
        let begin = (time ?? duration) >= duration ? 0 : time ?? 0
        time = begin
        let rate = duration / (reduceMotion ? 8 : 15)
        let started = Date()
        playback = Task { @MainActor in
            while !Task.isCancelled {
                let now = begin + Date().timeIntervalSince(started) * rate
                guard now < duration else { break }
                time = now
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 33))
            }
            if !Task.isCancelled { time = nil }
            playback = nil
        }
    }

    private func pause() {
        playback?.cancel()
        playback = nil
    }
}
