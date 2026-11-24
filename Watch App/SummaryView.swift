//
//  SummaryView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Post-match summary: the match drawn large, then its numbers. Says plainly when everything is
/// saved — the one thing worth knowing before walking off.
struct SummaryView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var showFieldPrompt = false

    private var record: MatchRecord? { workoutManager.finishedRecord }
    private var format: MatchFormat { record?.format ?? workoutManager.matchFormat }
    private var isIndoor: Bool { format == .indoor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let track = record?.track, track.count > 20 {
                    RouteSketch(track: track)
                        .frame(height: 110)
                        .accessibilityLabel("Your route")
                }
                stats
                saveState
                Button("Done") {
                    WatchHaptics.click()
                    workoutManager.reset()
                }
                .font(.headline)
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 52, prominent: true))
            }
            .scenePadding(.horizontal)
        }
        .onAppear(perform: promptForFieldIfNeeded)
        // Field learning finishes after the record publishes, so the prompt waits for it.
        .onChange(of: workoutManager.proposedField?.id) { _, _ in promptForFieldIfNeeded() }
        .sheet(isPresented: $showFieldPrompt) {
            ProposedFieldSheet()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MatchTrackerFormat.hoursMinutesSeconds(workoutManager.elapsedAtPause))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .foregroundStyle(WatchTheme.cardYellow)
            Text([resultText, fieldName].compactMap { $0 }.joined(separator: " · "))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var resultText: String? {
        let score = workoutManager.score
        guard score.us + score.them > 0 else { return nil }
        let outcome = score.us > score.them ? "Won" : score.us < score.them ? "Lost" : "Drew"
        return "\(outcome) \(score.us)–\(score.them)"
    }

    private var fieldName: String? {
        guard let fieldID = record?.fieldID else { return nil }
        return AppGroupStorage.fieldStore.fields.first { $0.id == fieldID }?.name
    }

    @ViewBuilder
    private var stats: some View {
        VStack(alignment: .leading, spacing: 10) {
            if WatchSettings.refereeMode {
                stat("Yellow cards", "\(count(of: .yellowCard))", tint: WatchTheme.cardYellow)
                stat("Red cards", "\(count(of: .redCard))", tint: WatchTheme.loss)
                stat("Fouls", "\(count(of: .foul))", tint: .white)
            }
            if !isIndoor {
                let distance = UnitSystem.current.distance(workoutManager.distanceMeters)
                stat("Distance", distance.text, tint: WatchTheme.pace)
            }
            if !WatchSettings.refereeMode, let timeOnPitch { stat("On the pitch", timeOnPitch, tint: WatchTheme.turf) }
            if let bpm = workoutManager.summaryAverageHeartRate, bpm > 0 {
                stat("Average heart rate", "\(Int(bpm)) BPM", tint: WatchTheme.heart)
            }
            if !isIndoor, let counts = workoutManager.summaryRunCounts {
                stat("Sprints", "\(counts.sprints)", tint: WatchTheme.sprint)
            }
            stat("Active calories", "\(Int(workoutManager.activeCalories)) CAL", tint: .white)
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var saveState: some View {
        if record == nil {
            HStack(spacing: 6) {
                ProgressView().frame(width: 18, height: 18)
                Text("Saving. Safe to leave.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
            Label(workoutManager.finishedWorkout == nil ? "Saved to MatchTracker" : "Saved to Health",
                  systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(WatchTheme.turf)
        }
        if !isIndoor, let record, record.track == nil {
            Label("No GPS was recorded", systemImage: "location.slash.fill")
                .font(.footnote)
                .foregroundStyle(WatchTheme.sprint)
        }
    }

    private var timeOnPitch: String? {
        guard let record, let end = record.endDate else { return nil }
        return MatchTrackerFormat.hoursMinutesSeconds(
            SubstitutionTracker.timeOnPitch(events: record.events, matchStart: record.startDate, matchEnd: end))
    }

    private func count(of kind: MatchEventKind) -> Int {
        workoutManager.events.filter { $0.kind == kind }.count
    }

    private func promptForFieldIfNeeded() {
        if workoutManager.proposedField != nil { showFieldPrompt = true }
    }
}

/// The match's route, drawn to fit: north up, no map, instant.
private struct RouteSketch: View {
    let track: [TrackPoint]

    var body: some View {
        Canvas { context, size in
            let latitudes = track.map(\.coordinate.latitude), longitudes = track.map(\.coordinate.longitude)
            guard let south = latitudes.min(), let north = latitudes.max(),
                  let west = longitudes.min(), let east = longitudes.max() else { return }
            let metersPerDegreeLongitude = cos(south * .pi / 180)
            let width = max((east - west) * metersPerDegreeLongitude, 1e-6), height = max(north - south, 1e-6)
            let scale = min(size.width / width, size.height / height)
            let origin = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
            var path = Path()
            for (index, point) in track.enumerated() {
                let position = CGPoint(
                    x: origin.x + (point.coordinate.longitude - west) * metersPerDegreeLongitude * scale,
                    y: origin.y + (north - point.coordinate.latitude) * scale)
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            context.stroke(path, with: .color(WatchTheme.turf.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Confirmation sheet for a newly inferred field, offering to save and share it.
private struct ProposedFieldSheet: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(ConnectivityManager.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Field"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(WatchTheme.turf)
                Text("New field detected — save?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                TextField("Field name", text: $name)

                Button("Save Field") {
                    WatchHaptics.success()
                    saveProposedField()
                    dismiss()
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 44, prominent: true))

                Button("Not Now") { dismiss() }
                    .tint(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func saveProposedField() {
        guard var field = workoutManager.proposedField else { return }
        field.name = name.isEmpty ? "New Field" : name
        try? AppGroupStorage.fieldStore.save(field)
        connectivity.send(field: field)
        workoutManager.proposedField = nil
    }
}
