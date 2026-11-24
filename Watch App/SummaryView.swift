//
//  SummaryView.swift
//  MatchTracker
//

import HealthKit
import SwiftUI
import MatchTrackerKit

/// Post-match summary: the result, whether it's saved — the one thing worth knowing before walking
/// off — then the match drawn large, then its numbers.
struct SummaryView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showFieldPrompt = false
    @State private var hasPromptedForField = false
    @State private var isLeaving = false
    @State private var enteredScore = FinalScore(us: 0, them: 0)
    @State private var hasSkippedScore = false
    @State private var field: FieldModel?
    @State private var hasNoHeat = false
    /// What the heart rate says of a match GPS couldn't see.
    @State private var indoor: MatchAnalytics?

    private var record: MatchRecord? { workoutManager.finishedRecord }
    private var track: [TrackPoint] { record?.track ?? workoutManager.track }
    private var format: MatchFormat { record?.format ?? workoutManager.matchFormat }
    private var isIndoor: Bool { format == .indoor }
    private var asksForScore: Bool {
        score == nil && !hasSkippedScore && workoutManager.keepsScore && !WatchSettings.refereeMode
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if asksForScore {
                    FinalScoreQuestion(score: $enteredScore) {
                        workoutManager.setFinalScore(enteredScore)
                    } onSkip: {
                        hasSkippedScore = true
                    }
                }
                picture
                stats
                Button("Done") {
                    WatchHaptics.click()
                    leave()
                }
                .font(.headline)
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 52, prominent: true))
                if #available(watchOS 11.0, *), let workout = workoutManager.finishedWorkout {
                    EffortButton(workout: workout)
                }
            }
            .scenePadding(.horizontal)
            .animation(.snappy, value: asksForScore)
        }
        .onAppear {
            field = AppGroupStorage.fieldStore.resolve(recordFieldID: workoutManager.fieldID, track: track)
            promptForFieldIfNeeded()
        }
        .task(id: record?.id) { await analyzeIndoors() }
        // Field learning finishes after the record publishes, so the prompt waits for it. It also
        // waits for the score, rather than landing under a finger.
        .onChange(of: workoutManager.proposedField?.id) { _, _ in promptForFieldIfNeeded() }
        .onChange(of: asksForScore) { _, _ in promptForFieldIfNeeded() }
        .sheet(isPresented: $showFieldPrompt) {
            if isLeaving { workoutManager.reset() }
        } content: {
            ProposedFieldSheet()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let resultText {
                    KitNumber(resultText, size: 64)
                } else {
                    Text(fieldName ?? format.startTitle)
                        .font(.system(.title2, weight: .heavy).width(.expanded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(WatchTheme.ivory)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .background { Cloth(cornerRadius: 14) }
            .padding(.bottom, 6)
            saveState
        }
    }

    private var score: FinalScore? {
        let logged = workoutManager.score
        return workoutManager.finalScore ?? (logged.us + logged.them > 0 ? FinalScore(us: logged.us, them: logged.them) : nil)
    }

    private var resultText: String? {
        MatchResultText.title(goalsUs: score?.us, goalsThem: score?.them)
    }

    private var fieldName: String? {
        guard let fieldID = record?.fieldID ?? workoutManager.fieldID else { return nil }
        return AppGroupStorage.fieldStore.fields.first { $0.id == fieldID }?.name
    }

    @ViewBuilder
    private var picture: some View {
        if isIndoor, indoor == nil ? workoutManager.heartRates.count >= 60 : indoor?.stints != nil {
            EffortStripView(levels: indoor?.stints?.strip ?? [], axis: .horizontal)
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement()
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(stripSentence)
        } else if !isIndoor, track.count > 20 {
            if let field, !hasNoHeat {
                MatchHeat(field: field, record: record) { hasNoHeat = true }
            } else {
                RouteSketch(track: track)
                    .frame(height: 110)
                    .accessibilityElement()
                    .accessibilityLabel("Your route")
            }
        }
    }

    @ViewBuilder
    private var stats: some View {
        VStack(alignment: .leading, spacing: 10) {
            if WatchSettings.refereeMode {
                stat("Yellow cards", "\(count(of: .yellowCard))")
                stat("Red cards", "\(count(of: .redCard))")
                stat("Fouls", "\(count(of: .foul))")
            }
            if isIndoor {
                indoorStats
                stat("Distance", UnitSystem.current.distance(workoutManager.distanceMeters).text)
            } else {
                stat("Distance", UnitSystem.current.distance(workoutManager.distanceMeters).text)
                if !WatchSettings.refereeMode { stat("Played", timeOnPitch ?? "—") }
            }
            let bpm = Int(workoutManager.summaryAverageHeartRate ?? 0)
            stat("Average heart rate", bpm > 0 ? "\(bpm) BPM" : "—", tint: WatchTheme.heart)
            stat("Match time", MatchTrackerFormat.hoursMinutesSeconds(workoutManager.elapsedAtPause))
            if !isIndoor {
                stat("Sprints", workoutManager.summaryRunCounts.map { "\($0.sprints)" } ?? "—")
            }
            stat("Active calories", "\(Int(workoutManager.activeCalories)) CAL")
        }
    }

    @ViewBuilder
    private var indoorStats: some View {
        if !WatchSettings.refereeMode {
            stat("Played", indoor.map { UnitSystem.minutes($0.workrate.timeOnPitch).text } ?? timeOnPitch ?? "—")
            if let stints = indoor?.stints {
                stat("Stints", "\(stints.playing.count)")
                stat("Longest stint", UnitSystem.minutes(stints.longest).text)
                if let recovery = stints.recovery, recovery >= 1 {
                    stat("Recovery in a minute", "\(Int(recovery.rounded())) BPM", tint: WatchTheme.heart)
                }
            }
        }
    }

    private var stripSentence: String {
        guard let indoor, let stints = indoor.stints else { return "Playing time" }
        let count = stints.playing.count == 1 ? "one stint" : "\(stints.playing.count) stints"
        return "Played \(UnitSystem.minutes(indoor.workrate.timeOnPitch).spoken) in \(count)."
    }

    private func stat(_ title: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.kit(.title2))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var saveState: some View {
        Group {
            if record == nil {
                Label {
                    Text("Saving. Safe to leave.")
                } icon: {
                    ProgressView().frame(width: 18, height: 18)
                }
                .foregroundStyle(.secondary)
            } else {
                Label(workoutManager.finishedWorkout == nil ? "Saved to MatchTracker" : "Saved to Health",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(WatchTheme.turf)
            }
        }
        .font(.headline)
        // One line from saving to saved, so nothing below it moves under a finger.
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        .minimumScaleFactor(0.7)
        .frame(minHeight: 24)
        if let earlyEnd = workoutManager.earlyEnd {
            Text("Ended at \(earlyEnd.date.formatted(date: .omitted, time: .shortened)), \(earlyEnd.hadLeft ? "before you left" : "when play stopped")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if !isIndoor, track.isEmpty {
            Label("No GPS was recorded", systemImage: "location.slash.fill")
                .font(.footnote)
                .foregroundStyle(WatchTheme.sprint)
        }
    }

    private var timeOnPitch: String? {
        guard let record, let end = record.endDate else { return nil }
        return UnitSystem.minutes(
            SubstitutionTracker.timeOnPitch(events: record.events, matchStart: record.startDate, matchEnd: end)).text
    }

    private func count(of kind: MatchEventKind) -> Int {
        workoutManager.events.filter { $0.kind == kind }.count
    }

    private func promptForFieldIfNeeded() {
        guard workoutManager.proposedField != nil, !asksForScore, !hasPromptedForField else { return }
        hasPromptedForField = true
        showFieldPrompt = true
    }

    private func analyzeIndoors() async {
        guard isIndoor, let record, let end = record.endDate else { return }
        let heartRate = workoutManager.heartRates
        indoor = await Task.detached(priority: .utility) {
            MatchAnalyzer.analyze(MatchAnalysisInput(
                record: record, interval: DateInterval(start: record.startDate, end: end), format: .indoor, track: [],
                heartRate: heartRate, healthDistanceMeters: nil, savedField: nil))
        }.value
    }

    /// Goals tapped in are an answer, whether or not Save was.
    private func leave() {
        if asksForScore {
            if enteredScore != FinalScore(us: 0, them: 0) { workoutManager.setFinalScore(enteredScore) }
            hasSkippedScore = true
        }
        promptForFieldIfNeeded()
        isLeaving = true
        if !showFieldPrompt { workoutManager.reset() }
    }
}

/// How the match ended, when no goal was logged. The same two tiles that count goals during it.
private struct FinalScoreQuestion: View {
    @Binding var score: FinalScore
    let onSave: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How did it end?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                side("Us", value: $score.us, tint: WatchTheme.turf)
                side("Them", value: $score.them, tint: WatchTheme.loss)
            }
            HStack(spacing: 8) {
                Button("Skip") {
                    WatchHaptics.click()
                    onSkip()
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.bench, minHeight: 52))
                Button("Save") {
                    WatchHaptics.success()
                    onSave()
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 52, prominent: true))
                .accessibilityHint("Saves the score")
            }
            .font(.headline)
        }
    }

    private func side(_ name: String, value: Binding<Int>, tint: Color) -> some View {
        VStack(spacing: 4) {
            Button {
                WatchHaptics.click()
                value.wrappedValue += 1
            } label: {
                VStack(spacing: 0) {
                    Text("\(value.wrappedValue)")
                        .font(.kit(52))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(name)
                        .font(.headline)
                }
            }
            .buttonStyle(WatchTileButtonStyle(tint: tint, minHeight: 80))
            .accessibilityLabel("\(name), goals")
            .accessibilityValue("\(value.wrappedValue)")
            .accessibilityHint("Adds a goal")
            Button {
                WatchHaptics.click()
                value.wrappedValue -= 1
            } label: {
                Image(systemName: "minus")
                    .font(.headline)
            }
            .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.bench, minHeight: 44))
            .opacity(value.wrappedValue > 0 ? 1 : 0.4)
            .disabled(value.wrappedValue == 0)
            .accessibilityLabel("\(name), take one off")
        }
        .animation(.snappy, value: value.wrappedValue)
    }
}

/// Rated while the legs still remember, on Apple's scale, for Training Load.
@available(watchOS 11.0, *)
private struct EffortButton: View {
    let workout: HKWorkout
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var score: Int?
    @State private var isRating = false

    var body: some View {
        Button { isRating = true } label: {
            HStack {
                Text(score.map { "Effort: \(EffortRating.word(for: $0)), \($0)" } ?? "Rate Effort")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isRating) {
            EffortSheet(initial: score ?? 5) { chosen in
                score = chosen
                Task {
                    do {
                        try await EffortRating.rate(workout, chosen, in: workoutManager.healthStore)
                    } catch {
                        MatchLog.error("effort rating failed: \(error.localizedDescription)", category: "workout")
                        score = nil
                        WatchHaptics.failure()
                    }
                }
            }
        }
    }
}

@available(watchOS 11.0, *)
private struct EffortSheet: View {
    let onRate: (Int) -> Void
    @State private var value: Double
    @Environment(\.dismiss) private var dismiss

    init(initial: Int, onRate: @escaping (Int) -> Void) {
        self.onRate = onRate
        _value = State(initialValue: Double(initial))
    }

    private var score: Int { Int(value.rounded()) }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(score)")
                .font(.kit(72))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(EffortRating.word(for: score)).font(.title3.weight(.semibold)).foregroundStyle(WatchTheme.sprint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .digitalCrownRotation($value, from: 1, through: 10, by: 1, sensitivity: .low, isHapticFeedbackEnabled: true)
        .animation(.snappy, value: score)
        .accessibilityElement()
        .accessibilityLabel("Effort")
        .accessibilityValue("\(score) of 10, \(EffortRating.word(for: score))")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 1 : -1), 1), 10)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") {
                    WatchHaptics.click()
                    onRate(score)
                    dismiss()
                }
            }
        }
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
