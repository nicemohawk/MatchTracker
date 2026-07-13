//
//  SummaryView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Post-match summary, styled after Apple's workout summary. Shows duration, time on pitch,
/// distance, average heart rate, calories, run/sprint counts and the score/event recap. Sends
/// the finished record to the phone and, if a new field was inferred, offers to save it.
struct SummaryView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(ConnectivityManager.self) private var connectivity
    @State private var showFieldPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Match Complete")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)

                if let fieldName {
                    Label(fieldName, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                summaryRow("Duration", value: durationString, tint: .yellow)
                if WatchSettings.refereeMode {
                    // Officiating summary: the referee's own athletic stats are noise here.
                    summaryRow("Score", value: "\(workoutManager.score.us)–\(workoutManager.score.them)", tint: .primary)
                    summaryRow("Yellow Cards", value: "\(count(of: .yellowCard))", tint: .yellow)
                    summaryRow("Red Cards", value: "\(count(of: .redCard))", tint: .red)
                    summaryRow("Fouls", value: "\(count(of: .foul))", tint: .orange)
                    summaryRow("Events", value: "\(workoutManager.loggedEventCount)", tint: .purple)
                } else {
                    summaryRow("Time on Pitch", value: timeOnPitchString, tint: .orange)
                    summaryRow("Distance", value: distanceString, tint: .blue)
                    summaryRow("Avg Heart Rate", value: averageHeartRateString, tint: .red)
                    summaryRow("Active Calories", value: "\(Int(workoutManager.activeCalories)) CAL", tint: .orange)
                    summaryRow("Runs", value: "\(runCounts.runs)", tint: .green)
                    summaryRow("Sprints", value: "\(runCounts.sprints)", tint: .green)
                    summaryRow("Score", value: "\(workoutManager.score.us)–\(workoutManager.score.them)", tint: .primary)
                    summaryRow("Events", value: "\(workoutManager.loggedEventCount)", tint: .purple)
                }

                if autoDetectedSubCount > 0 {
                    Label("\(autoDetectedSubCount) auto sub\(autoDetectedSubCount == 1 ? "" : "s")",
                          systemImage: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                }

                Button("Done") {
                    workoutManager.reset()
                }
                .tint(.green)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .onAppear(perform: finishUp)
        .sheet(isPresented: $showFieldPrompt) {
            ProposedFieldSheet()
        }
    }

    // MARK: Actions

    private func finishUp() {
        if let record = workoutManager.finishedRecord {
            connectivity.send(matchRecord: record)
        }
        if workoutManager.proposedField != nil {
            showFieldPrompt = true
        }
    }

    // MARK: Derived stats

    private var interval: DateInterval? {
        guard let record = workoutManager.finishedRecord, let end = record.endDate else { return nil }
        return DateInterval(start: record.startDate, end: end)
    }

    private var playingIntervals: [DateInterval] {
        guard let interval, let record = workoutManager.finishedRecord else { return [] }
        return SubstitutionTracker.playingIntervals(events: record.events,
                                                    matchStart: interval.start,
                                                    matchEnd: interval.end)
    }

    private var runCounts: (runs: Int, sprints: Int) {
        let runs = RunDetector.detectRuns(in: workoutManager.track, configuration: RunDetectorConfiguration())
        return (runs.filter { $0.intensity == .run }.count,
                runs.filter { $0.intensity == .sprint }.count)
    }

    private var fieldName: String? {
        guard let fieldID = workoutManager.finishedRecord?.fieldID else { return nil }
        return AppGroupStorage.fieldStore.fields.first(where: { $0.id == fieldID })?.name
    }

    private func count(of kind: MatchEventKind) -> Int {
        (workoutManager.finishedRecord?.events ?? workoutManager.events)
            .filter { $0.kind == kind }.count
    }

    /// Substitutions the detector logged automatically during this match.
    private var autoDetectedSubCount: Int {
        (workoutManager.finishedRecord?.events ?? workoutManager.events).filter {
            $0.source == .automatic && ($0.kind == .subIn || $0.kind == .subOut)
        }.count
    }

    // MARK: Formatting

    private var durationString: String {
        MatchTrackerFormat.hoursMinutesSeconds(interval?.duration ?? workoutManager.elapsedAtPause)
    }

    private var timeOnPitchString: String {
        guard let interval, let record = workoutManager.finishedRecord else { return "--" }
        let onPitch = SubstitutionTracker.timeOnPitch(events: record.events,
                                                      matchStart: interval.start,
                                                      matchEnd: interval.end)
        return MatchTrackerFormat.hoursMinutesSeconds(onPitch)
    }

    private var distanceString: String {
        String(format: "%.2f MI", workoutManager.distanceMeters / 1609.344)
    }

    private var averageHeartRateString: String {
        guard let bpm = workoutManager.summaryAverageHeartRate, bpm > 0 else { return "--" }
        return "\(Int(bpm)) BPM"
    }

    private func summaryRow(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(.green)
                Text("New field detected — save?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                TextField("Field name", text: $name)

                Button("Save Field") {
                    saveProposedField()
                    dismiss()
                }
                .tint(.green)

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
