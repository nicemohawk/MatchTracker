//
//  LiveMatchView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Sideline view of a match in progress, rendered from the watch's live stream. The caller
/// supplies the store and, when a field is known, a projector for the position dot.
struct LiveMatchView: View {
    let store: LiveMatchStore
    var projector: FieldProjector?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let update = store.latest {
                    header(update)
                    metricsGrid(update)
                    pitchCard(update)
                    eventFeed
                } else {
                    ContentUnavailableView("Waiting for the watch…",
                                           systemImage: "applewatch.radiowaves.left.and.right")
                }
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Live Match")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ update: LiveMatchUpdate) -> some View {
        VStack(spacing: 6) {
            HStack {
                Label(update.onPitch ? "On pitch" : "On bench",
                      systemImage: update.onPitch ? "figure.soccer" : "chair")
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundStyle(update.onPitch ? Theme.turf : Theme.bench)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background((update.onPitch ? Theme.turf : Theme.bench).opacity(0.15))
                    .clipShape(Capsule())
                Spacer()
                if !store.isLive {
                    Label("Signal lost", systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(Theme.heart)
                }
            }
            Text("\(update.usGoals ?? 0) – \(update.themGoals ?? 0)")
                .heroNumeral()
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

    /// Extrapolates elapsed time between updates so the clock ticks smoothly.
    private func elapsedText(_ update: LiveMatchUpdate) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let drift = store.isLive
                ? timeline.date.timeIntervalSince(store.lastReceivedAt ?? timeline.date)
                : 0
            Text(MatchTrackerFormat.hoursMinutesSeconds(update.elapsed + max(0, drift)))
        }
    }

    private func metricsGrid(_ update: LiveMatchUpdate) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                metricTile("heart.fill", update.heartRate.map { "\(Int($0))" } ?? "—", "BPM", Theme.heart)
                metricTile("figure.run", String(format: "%.2f km", update.distanceMeters / 1000), "Distance", Theme.pace)
            }
            GridRow {
                metricTile("speedometer",
                           update.currentSpeed.map { String(format: "%.1f", $0 * 3.6) } ?? "—",
                           "km/h", Theme.sprint)
                metricTile("calendar.badge.clock",
                           "\(store.events.count)", "Events", Theme.signal)
            }
        }
    }

    private func metricTile(_ symbol: String, _ value: String, _ caption: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).statNumeral()
            Text(caption).captionLabel()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .metricTile(tint: tint)
    }

    private func pitchCard(_ update: LiveMatchUpdate) -> some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size)
            SoccerPitch.fillTurf(&context, rect: rect)
            SoccerPitch.draw(in: &context, rect: rect)

            if let projector,
               let point = update.latestPoints.last ?? store.recentPoints.last,
               let normalized = projector.normalizedPoint(for: point.coordinate) {
                let dot = CGPoint(x: rect.minX + normalized.x * rect.width,
                                  y: rect.minY + normalized.y * rect.height)
                let tint = update.onPitch ? Theme.signal : Theme.bench
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: tint.opacity(0.7), radius: 6))
                    layer.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)),
                               with: .color(tint))
                }
            }
        }
        .frame(height: 180)
        .background(Theme.pitchTurfBottom)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(projector == nil ? 0.4 : 1)
        .overlay {
            if projector == nil {
                Text("No field matched yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Events")
                .font(.headline)
                .padding(.bottom, 6)
            if store.events.isEmpty {
                Text("Nothing logged yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.events.reversed()) { event in
                    HStack {
                        Image(systemName: event.kind.systemImage)
                            .foregroundStyle(event.kind.tint)
                        Text(event.kind.title)
                        Spacer()
                        Text(event.date, style: .time)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 6)
                    if event.id != store.events.first?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .themedCard(cornerRadius: 16)
    }
}
