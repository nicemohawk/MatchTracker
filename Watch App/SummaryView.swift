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
    @State private var celebrated = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                celebrationHeader

                VStack(spacing: 0) {
                    if WatchSettings.refereeMode {
                        // Officiating summary: the referee's own athletic stats are noise here.
                        statRow("Score", value: "\(workoutManager.score.us)–\(workoutManager.score.them)", tint: .primary)
                        statRow("Yellow Cards", value: "\(count(of: .yellowCard))", tint: WatchTheme.cardYellow)
                        statRow("Red Cards", value: "\(count(of: .redCard))", tint: WatchTheme.loss)
                        statRow("Fouls", value: "\(count(of: .foul))", tint: WatchTheme.sprint)
                        statRow("Events", value: "\(workoutManager.loggedEventCount)", tint: WatchTheme.signal, isLast: true)
                    } else if isIndoor {
                        // Indoor: GPS-derived distance/runs/sprints are unavailable; effort is HR-driven.
                        statRow("Time on Pitch", value: timeOnPitchString, tint: WatchTheme.sprint)
                        statRow("Avg Heart Rate", value: averageHeartRateString, tint: WatchTheme.heart)
                        statRow("Active Calories", value: "\(Int(workoutManager.activeCalories)) CAL", tint: WatchTheme.sprint)
                        statRow("Score", value: "\(workoutManager.score.us)–\(workoutManager.score.them)", tint: .primary)
                        statRow("Events", value: "\(workoutManager.loggedEventCount)", tint: WatchTheme.signal, isLast: true)
                    } else {
                        statRow("Time on Pitch", value: timeOnPitchString, tint: WatchTheme.sprint)
                        statRow("Distance", value: distanceString, tint: WatchTheme.pace)
                        statRow("Avg Heart Rate", value: averageHeartRateString, tint: WatchTheme.heart)
                        statRow("Active Calories", value: "\(Int(workoutManager.activeCalories)) CAL", tint: WatchTheme.sprint)
                        statRow("Runs", value: "\(runCounts.runs)", tint: WatchTheme.turf)
                        statRow("Sprints", value: "\(runCounts.sprints)", tint: WatchTheme.turf)
                        statRow("Score", value: "\(workoutManager.score.us)–\(workoutManager.score.them)", tint: .primary)
                        statRow("Events", value: "\(workoutManager.loggedEventCount)", tint: WatchTheme.signal, isLast: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .watchCard()

                if isIndoor {
                    Label("Indoor session — effort from heart rate", systemImage: "house")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if autoDetectedSubCount > 0 {
                    Label("\(autoDetectedSubCount) auto sub\(autoDetectedSubCount == 1 ? "" : "s")",
                          systemImage: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.signal)
                }

                Button("Done") {
                    WatchHaptics.click()
                    workoutManager.reset()
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 44, prominent: true))
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .onAppear(perform: finishUp)
        .sheet(isPresented: $showFieldPrompt) {
            ProposedFieldSheet()
        }
    }

    /// Duration hero with the field name, styled after Apple's workout summary. Springs in on
    /// appear as a small celebration.
    private var celebrationHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Match Complete")
                .watchCaptionLabel()
                .foregroundStyle(WatchTheme.turf)
            Text(durationString)
                .watchHeroNumeral()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            if let fieldName {
                Label(fieldName, systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(celebrated ? 1.0 : 0.9)
        .opacity(celebrated ? 1.0 : 0.0)
    }

    // MARK: Actions

    private func finishUp() {
        if let record = workoutManager.finishedRecord {
            connectivity.send(matchRecord: record)
        }
        if workoutManager.proposedField != nil {
            showFieldPrompt = true
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            celebrated = true
        }
    }

    // MARK: Derived stats

    /// Indoor sessions hide the GPS-derived athletic rows in favor of an HR-effort summary.
    private var isIndoor: Bool {
        (workoutManager.finishedRecord?.format ?? workoutManager.matchFormat) == .indoor
    }

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
        let runs = RunDetector.detectRuns(in: workoutManager.track,
                                          configuration: .scaled(for: workoutManager.matchContext))
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

    // Metric to match the iOS app (MatchFormat.distance renders km everywhere).
    private var distanceString: String {
        String(format: "%.2f km", workoutManager.distanceMeters / 1000)
    }

    private var averageHeartRateString: String {
        guard let bpm = workoutManager.summaryAverageHeartRate, bpm > 0 else { return "--" }
        return "\(Int(bpm)) BPM"
    }

    /// One labeled stat row: uppercase caption on the left, a colored monospaced value on the
    /// right, with a hairline divider beneath (suppressed on the final row).
    private func statRow(_ title: String, value: String, tint: Color, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            .padding(.vertical, 7)
            if !isLast {
                Divider().overlay(WatchTheme.surfaceStroke)
            }
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
