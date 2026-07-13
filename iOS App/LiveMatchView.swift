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
        .navigationTitle("Live Match")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ update: LiveMatchUpdate) -> some View {
        VStack(spacing: 4) {
            HStack {
                Label(update.onPitch ? "On pitch" : "On bench",
                      systemImage: update.onPitch ? "figure.soccer" : "chair")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(update.onPitch ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .clipShape(Capsule())
                Spacer()
                if !store.isLive {
                    Label("Signal lost", systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            Text("\(update.usGoals ?? 0) – \(update.themGoals ?? 0)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
            elapsedText(update)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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
                metricTile("heart.fill", update.heartRate.map { "\(Int($0))" } ?? "—", "BPM", .red)
                metricTile("figure.run", String(format: "%.2f km", update.distanceMeters / 1000), "Distance", .blue)
            }
            GridRow {
                metricTile("speedometer",
                           update.currentSpeed.map { String(format: "%.1f", $0 * 3.6) } ?? "—",
                           "km/h", .orange)
                metricTile("calendar.badge.clock",
                           "\(store.events.count)", "Events", .purple)
            }
        }
    }

    private func metricTile(_ symbol: String, _ value: String, _ caption: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func pitchCard(_ update: LiveMatchUpdate) -> some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 4),
                         with: .color(Color.green.opacity(0.25)))
            SoccerPitch.draw(in: &context, rect: rect)

            if let projector,
               let point = update.latestPoints.last ?? store.recentPoints.last,
               let normalized = projector.normalizedPoint(for: point.coordinate) {
                let dot = CGPoint(x: rect.minX + normalized.x * rect.width,
                                  y: rect.minY + normalized.y * rect.height)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)),
                             with: .color(update.onPitch ? .blue : .orange))
            }
        }
        .frame(height: 180)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
