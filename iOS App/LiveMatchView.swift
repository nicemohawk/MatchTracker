//
//  LiveMatchView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Sideline view of a match in progress, rendered from the watch's live stream — the app's
/// adrenaline screen. The caller supplies the store and, when a field is known, a projector for
/// the position dot and its comet trail.
struct LiveMatchView: View {
    let store: LiveMatchStore
    var projector: FieldProjector?

    /// Rising-edge sprint threshold (m/s). ~5.5 m/s ≈ 19.8 km/h — a genuine burst, not a jog.
    private static let sprintSpeed = 5.5

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let update = store.latest {
                    header(update)
                    statBand(update)
                    pitchCard(update)
                    eventFeed
                } else {
                    ContentUnavailableView("Waiting for the watch…",
                                           systemImage: "applewatch.radiowaves.left.and.right")
                        .padding(.top, 60)
                }
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Live Match")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private func header(_ update: LiveMatchUpdate) -> some View {
        VStack(spacing: 8) {
            HStack {
                pitchStatusPill(update)
                Spacer()
                if store.isLive {
                    HStack(spacing: 6) {
                        LivePulseDot(diameter: 7)
                        Text("LIVE").captionLabel().foregroundStyle(Theme.heart)
                    }
                } else {
                    Label("Signal lost", systemImage: "wifi.slash")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.heart)
                }
            }
            LiveScoreView(us: update.usGoals ?? 0, them: update.themGoals ?? 0)
            elapsedText(update)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(
            ZStack {
                Theme.surface
                Theme.turfFlow.opacity(0.10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
    }

    private func pitchStatusPill(_ update: LiveMatchUpdate) -> some View {
        let tint = update.onPitch ? Theme.turf : Theme.bench
        return Label(update.onPitch ? "On pitch" : "On bench",
                     systemImage: update.onPitch ? "figure.soccer" : "chair")
            .font(.system(.subheadline, design: .rounded).bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.chipFill(tint), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.chipStroke(tint), lineWidth: 1))
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: update.onPitch)
    }

    /// Extrapolates elapsed time between updates so the clock ticks smoothly.
    private func elapsedText(_ update: LiveMatchUpdate) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let drift = store.isLive
                ? timeline.date.timeIntervalSince(store.lastReceivedAt ?? timeline.date)
                : 0
            Text(MatchTrackerFormat.hoursMinutesSeconds(update.elapsed + max(0, drift)))
        }
    }

    // MARK: - Stat band

    private func statBand(_ update: LiveMatchUpdate) -> some View {
        HStack(spacing: 12) {
            heroStat("figure.run",
                     String(format: "%.2f", update.distanceMeters / 1000),
                     "KM", Theme.pace)
            heroStat("bolt.fill",
                     "\(sprintCount(store.recentPoints))",
                     "Sprints", Theme.sprint)
            heroStat("heart.fill",
                     update.heartRate.map { "\(Int($0))" } ?? "—",
                     "BPM", Theme.heart)
        }
    }

    private func heroStat(_ symbol: String, _ value: String, _ caption: String, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .statNumeral()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(caption).captionLabel()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .metricTile(tint: tint)
    }

    /// Rising-edge sprint count over the recent track: each time speed climbs past the threshold
    /// (with hysteresis so a jitter around the line isn't counted twice) is one sprint.
    private func sprintCount(_ points: [TrackPoint]) -> Int {
        var count = 0
        var inSprint = false
        for point in points {
            let speed = point.speedMetersPerSecond
            if !inSprint, speed >= Self.sprintSpeed {
                count += 1
                inSprint = true
            } else if inSprint, speed < Self.sprintSpeed * 0.8 {
                inSprint = false
            }
        }
        return count
    }

    // MARK: - Pitch

    private func pitchCard(_ update: LiveMatchUpdate) -> some View {
        Group {
            if let projector {
                Canvas { context, size in
                    let rect = SoccerPitch.fittedRect(in: size)
                    SoccerPitch.fillTurf(&context, rect: rect)
                    SoccerPitch.draw(in: &context, rect: rect)

                    // Project the last ~30 points into the fitted pitch rect for the comet trail.
                    let trail: [CGPoint] = store.recentPoints.suffix(30).compactMap { point in
                        guard let n = projector.normalizedPoint(for: point.coordinate) else { return nil }
                        return CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height)
                    }
                    guard let head = trail.last else { return }
                    let tint = update.onPitch ? Theme.signal : Theme.bench

                    // Comet trail: segments fade and thin toward the tail.
                    if trail.count > 1 {
                        for index in 1..<trail.count {
                            let t = Double(index) / Double(trail.count - 1)
                            var segment = Path()
                            segment.move(to: trail[index - 1])
                            segment.addLine(to: trail[index])
                            context.stroke(segment,
                                           with: .color(tint.opacity(0.06 + 0.5 * t)),
                                           style: StrokeStyle(lineWidth: 1 + 3 * t, lineCap: .round, lineJoin: .round))
                        }
                    }

                    // Heat glow beneath the current position.
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - 24, y: head.y - 24, width: 48, height: 48)),
                        with: .radialGradient(Gradient(colors: [tint.opacity(0.38), .clear]),
                                              center: head, startRadius: 0, endRadius: 24))

                    // Position dot with a soft glow, then a bright core.
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: tint.opacity(0.8), radius: 8))
                        layer.fill(Path(ellipseIn: CGRect(x: head.x - 6, y: head.y - 6, width: 12, height: 12)),
                                   with: .color(tint))
                    }
                    context.fill(Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)),
                                 with: .color(.white.opacity(0.9)))
                }
            } else {
                waitingForFieldLock
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
    }

    /// Graceful placeholder while no field is matched: a dimmed pitch with a pulsing lock cue,
    /// rather than a blank rectangle.
    private var waitingForFieldLock: some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size)
            SoccerPitch.fillTurf(&context, rect: rect)
            SoccerPitch.draw(in: &context, rect: rect)
        }
        .opacity(0.5)
        .overlay {
            VStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.signal)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Waiting for field lock")
                    .font(.subheadline.weight(.semibold))
                Text("Live position appears once a field is matched")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    // MARK: - Events

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.headline)
            if store.events.isEmpty {
                Text("Nothing logged yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(recentEvents) { event in
                        eventChip(event)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: recentEvents.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .themedCard(cornerRadius: 16)
    }

    /// Last handful of events, newest first, so the freshest chip springs in at the top.
    private var recentEvents: [MatchEvent] {
        store.events.suffix(6).reversed()
    }

    private func eventChip(_ event: MatchEvent) -> some View {
        let tint = event.kind.tint
        return HStack(spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.chipFill(tint)))
            Text(event.kind.title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Text(event.date, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Live score

/// The big live scoreline: rolling `numericText` digits, a semantic tint (turf when ahead or level,
/// loss when behind) and a brief scale "pop" whenever either side scores.
private struct LiveScoreView: View {
    let us: Int
    let them: Int
    @State private var pop = false

    var body: some View {
        Text("\(us)–\(them)")
            .heroNumeral()
            .contentTransition(.numericText())
            .foregroundStyle(tint)
            .animation(.snappy, value: us)
            .animation(.snappy, value: them)
            .scaleEffect(pop ? 1.12 : 1)
            .onChange(of: us) { animatePop() }
            .onChange(of: them) { animatePop() }
    }

    private var tint: Color {
        if us > them { return Theme.turf }
        if us < them { return Theme.loss }
        return .primary
    }

    private func animatePop() {
        Haptics.impact(.rigid)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { pop = true }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.16)) { pop = false }
    }
}
