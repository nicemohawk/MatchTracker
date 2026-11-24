//
//  LiveMatchView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// The match as it happens, for whoever is holding the phone. The scoreline and the clock first,
/// then where they are, then three numbers and what's happened.
struct LiveMatchView: View {
    let store: LiveMatchStore
    /// Set when a caller already knows the field; otherwise it's worked out from the trail.
    var projector: FieldProjector?
    /// For a sheet; pushed onto a stack it has a Back button already.
    var showsClose = false

    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The score is the hero but must still fit beside itself at the largest text sizes.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 88
    @State private var showingCamera = false

    private let units = UnitSystem.current

    var body: some View {
        ScrollView {
            if let state = store.state {
                VStack(alignment: .leading, spacing: 28) {
                    hero(state)
                    pitch(state)
                    measures(state)
                    eventList(state)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
                .readableWidth()
            } else {
                ContentUnavailableView("No Live Match", systemImage: "applewatch",
                                       description: Text("Start a match on your Apple Watch and it appears here."))
                    .containerRelativeFrame(.vertical)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Live match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsClose {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Record Video", systemImage: "video") { showingCamera = true }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            // No match UUID exists on the phone until the watch's record syncs, so capture opens
            // with the live feed for the ticker and resolves its save target via the recent-match
            // picker on stop. Alignment stays nudge-free regardless — the clip carries its exact
            // wall-clock start.
            SidelineCameraView(preassociatedMatchID: nil, liveStore: store)
        }
        .sensoryFeedback(.impact, trigger: store.state?.score)
    }

    // MARK: Hero

    private func hero(_ state: LiveMatchState) -> some View {
        VStack(spacing: 4) {
            if let us = state.goalsUs, let them = state.goalsThem {
                Text("\(us)–\(them)")
                    .font(.system(size: min(heroSize, 132), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy, value: state.score)
                    .accessibilityLabel(state.spokenScore)
                clock(state, font: .system(.title, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                // Nobody has logged a goal, which isn't the same as 0–0.
                clock(state, font: .system(size: min(heroSize, 132) * 0.8, weight: .bold, design: .rounded))
            }
            status(state)
                .font(.headline)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func clock(_ state: LiveMatchState, font: Font) -> some View {
        LiveClock(store: store)
            .font(font)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityElement()
            .accessibilityLabel("Match clock")
            .accessibilityValue(UnitSystem.minutes(state.elapsed).spoken)
    }

    @ViewBuilder private func status(_ state: LiveMatchState) -> some View {
        if state.hasEnded {
            Label("Full time", systemImage: "flag.checkered")
                .foregroundStyle(.secondary)
        } else if !store.isLive {
            Label {
                Text("Last update at \(state.updatedAt, style: .time)")
            } icon: {
                Image(systemName: "wifi.slash")
            }
            .foregroundStyle(.secondary)
        } else {
            Label(state.status, systemImage: state.statusSymbol)
                .foregroundStyle(state.isPlaying ? AnyShapeStyle(Theme.turf) : AnyShapeStyle(.secondary))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
    }

    // MARK: Pitch

    private var fieldProjector: FieldProjector? {
        if let projector { return projector }
        let coordinates = store.recentPoints.suffix(30).map(\.coordinate)
        guard !coordinates.isEmpty else { return nil }
        return fields.store.bestMatch(for: coordinates).map { FieldProjector(rectangle: $0.rectangle) }
    }

    /// Only drawn when there's a position to draw on it.
    @ViewBuilder private func pitch(_ state: LiveMatchState) -> some View {
        if let projector = fieldProjector {
            let trail = store.recentPoints.suffix(60).compactMap { projector.normalizedPoint(for: $0.coordinate) }
            if !trail.isEmpty {
                LivePitch(trail: trail, isOn: state.onPitch != false)
                    .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel("Pitch. \(Self.whereabouts(trail.last)).")
            }
        }
    }

    private static func whereabouts(_ point: CGPoint?) -> String {
        guard let point else { return "Position unknown" }
        let along = point.x < 1 / 3 ? "left third" : point.x > 2 / 3 ? "right third" : "middle third"
        let across = point.y < 1 / 3 ? ", near the top touchline" : point.y > 2 / 3 ? ", near the bottom touchline" : ""
        return "Currently in the \(along)\(across)"
    }

    // MARK: Numbers

    private func measures(_ state: LiveMatchState) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        let distance = units.roughDistance(state.distanceMeters)
        let speed = store.isLive ? store.latest?.currentSpeed.map { units.speed($0) } : nil
        return layout {
            measure("Distance", value: state.distanceMeters > 0 ? distance.value : "—",
                    unit: state.distanceMeters > 0 ? distance.unit : "", spoken: distance.spoken)
            measure("Heart rate", value: store.isLive ? state.heartRate.map(String.init) ?? "—" : "—",
                    unit: state.heartRate == nil || !store.isLive ? "" : "bpm",
                    spoken: state.heartRate.map { "\($0) beats per minute" } ?? "unknown",
                    tint: Theme.heart)
            measure("Speed", value: speed?.value ?? "—", unit: speed?.unit ?? "", spoken: speed?.spoken ?? "unknown")
        }
    }

    private func measure(_ title: String, value: String, unit: String, spoken: String,
                         tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy, value: value)
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("\(title), \(value == "—" ? "unknown" : spoken)")
    }

    // MARK: Events

    @ViewBuilder private func eventList(_ state: LiveMatchState) -> some View {
        let shown = store.events.filter { $0.kind != .matchStart }.suffix(8).reversed()
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("What's happened")
                    .font(.title2.bold())
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(shown) { event in
                    HStack(spacing: 12) {
                        Image(systemName: event.kind.systemImage)
                            .foregroundStyle(Self.tint(event.kind))
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text(Self.sentence(event.kind))
                        Spacer(minLength: 8)
                        Text(Self.minute(event.date, since: state.startDate))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.body)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .default, value: store.events.count)
        }
    }

    /// By the wall clock since kickoff, as a referee counts.
    private static func minute(_ date: Date, since start: Date) -> String {
        "\(max(0, Int(date.timeIntervalSince(start) / 60)) + 1)′"
    }

    private static func tint(_ kind: MatchEventKind) -> Color {
        switch kind {
        case .goalForUs, .goalMine, .assist: return Theme.turf
        case .goalAgainstUs, .redCard: return Theme.loss
        case .yellowCard: return Theme.cardYellow
        default: return .secondary
        }
    }

    private static func sentence(_ kind: MatchEventKind) -> String {
        switch kind {
        case .matchStart: return "Kickoff"
        case .matchEnd: return "Full time"
        case .periodStart: return "Play restarted"
        case .periodEnd: return "Half-time"
        case .subIn: return "Came on"
        case .subOut: return "Came off"
        case .goalForUs: return "Goal"
        case .goalMine: return "Scored"
        case .goalAgainstUs: return "Goal against"
        case .assist: return "Assist"
        case .flag: return "Moment flagged"
        case .yellowCard: return "Yellow card"
        case .redCard: return "Red card"
        case .foul: return "Foul"
        case .turnover: return "Turnover"
        case .timeout: return "Timeout"
        }
    }
}

/// The pitch with the last few minutes of movement trailing off behind the player.
private struct LivePitch: View {
    /// Normalized field positions, oldest first.
    let trail: [CGPoint]
    let isOn: Bool

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.pitchTurfBottom))
            let rect = SoccerPitch.fittedRect(in: size)
            SoccerPitch.fillTurf(&context, rect: rect)
            SoccerPitch.draw(in: &context, rect: rect)

            let points = trail.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            let tint = isOn ? Color(red: 0.188, green: 0.820, blue: 0.345) : Color(white: 0.7)
            for index in points.indices.dropFirst() {
                let recency = Double(index) / Double(points.count - 1)
                var segment = Path()
                segment.move(to: points[index - 1])
                segment.addLine(to: points[index])
                context.stroke(segment, with: .color(tint.opacity(0.1 + 0.7 * recency)),
                               style: StrokeStyle(lineWidth: 1.5 + 3 * recency, lineCap: .round, lineJoin: .round))
            }
            guard let head = points.last else { return }
            let dot = Path(ellipseIn: CGRect(x: head.x - 8, y: head.y - 8, width: 16, height: 16))
            context.fill(dot, with: .color(tint))
            context.stroke(dot, with: .color(.white), lineWidth: 3)
        }
    }
}
