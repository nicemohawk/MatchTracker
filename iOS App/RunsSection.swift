// RunsSection.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

struct RunsSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics
    @State private var selectedRun: RunSegment.ID?

    private var runs: [RunSegment] { analytics.runs }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                SummaryChip(value: "\(runs.count)", label: "Runs", tint: Theme.sprint)
                SummaryChip(value: "\(runs.filter { $0.intensity == .sprint }.count)", label: "Sprints", tint: Theme.heart)
                SummaryChip(value: MatchFormat.distance(longestRun), label: "Longest", tint: Theme.turf)
            }

            RunsMap(track: detail.track, runs: runs, region: analytics.rectangle.mapRegion, selection: selectedRun)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if runs.isEmpty {
                Text("No runs detected in this match.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs) { run in
                        RunRow(run: run, isSelected: run.id == selectedRun)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.selection()
                                selectedRun = (selectedRun == run.id) ? nil : run.id
                            }
                        if run.id != runs.last?.id { Divider() }
                    }
                }
                .themedCard(cornerRadius: 16)
            }
        }
    }

    private var longestRun: Double {
        runs.map(\.distanceMeters).max() ?? 0
    }
}

struct RunRow: View {
    let run: RunSegment
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(run.intensity.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.intensity.label).font(.subheadline.weight(.semibold))
                Text(run.interval.start, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MatchFormat.distance(run.distanceMeters)).font(.subheadline).monospacedDigit()
                Text("\(MatchFormat.speed(run.peakSpeed)) peak · \(MatchFormat.duration(run.interval.duration))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? run.intensity.color.opacity(0.12) : .clear)
    }
}

/// Map with per-run polylines colored by intensity; the faint full track sits underneath.
struct RunsMap: View {
    let track: [TrackPoint]
    let runs: [RunSegment]
    let region: MKCoordinateRegion
    let selection: RunSegment.ID?

    var body: some View {
        Map(initialPosition: .region(region)) {
            if track.count > 1 {
                MapPolyline(coordinates: track.map(\.coordinate.clCoordinate))
                    .stroke(.white.opacity(0.35), lineWidth: 2)
            }
            ForEach(runs) { run in
                let coordinates = coordinates(for: run)
                if coordinates.count > 1 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(run.intensity.color,
                                style: StrokeStyle(lineWidth: run.id == selection ? 6 : 3, lineCap: .round))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func coordinates(for run: RunSegment) -> [CLLocationCoordinate2D] {
        let lower = max(0, run.pointRange.lowerBound)
        let upper = min(track.count, run.pointRange.upperBound)
        guard lower < upper else { return [] }
        return track[lower..<upper].map(\.coordinate.clCoordinate)
    }
}
