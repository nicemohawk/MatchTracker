// EffortRatingView.swift
// MatchTracker

import HealthKit
import MatchTrackerKit
import SwiftUI

/// How hard it was, in one word: the player's own once they've said, the heart's until then.
struct EffortVerdict: View {
    let workout: HKWorkout?
    let measured: String?

    var body: some View {
        if #available(iOS 18.0, *), let workout {
            RatedEffort(workout: workout, measured: measured)
        } else if let measured {
            Text(measured).font(.title3)
        }
    }
}

@available(iOS 18.0, *)
private struct RatedEffort: View {
    let workout: HKWorkout
    let measured: String?
    @State private var score: Int?
    @State private var isRating = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let score {
                Text("\(EffortRating.word(for: score)), \(score) of 10").font(.title3).monospacedDigit()
            } else if let measured {
                Text(measured).font(.title3)
            }
            Spacer()
            Button(score == nil ? "Rate" : "Change") { isRating = true }
                .accessibilityLabel(score == nil ? "Rate your effort" : "Change your effort rating")
        }
        .frame(minHeight: 44)
        .task(id: workout.uuid) { score = await EffortRating.score(of: workout, in: HealthKitService.shared.healthStore) }
        .sheet(isPresented: $isRating) {
            RateEffortSheet(workout: workout, score: $score)
                .presentationDetents([.medium])
        }
    }
}

@available(iOS 18.0, *)
private struct RateEffortSheet: View {
    let workout: HKWorkout
    @Binding var score: Int?

    @State private var draft = 5.0
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 0) {
                    Text("\(Int(draft))")
                        .font(.system(size: 80, weight: .heavy).width(.compressed))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(EffortRating.word(for: Int(draft))).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                Slider(value: $draft, in: 1...10, step: 1) { Text("Effort") }
                    .accessibilityValue("\(Int(draft)) of 10, \(EffortRating.word(for: Int(draft)))")
                    .sensoryFeedback(.selection, trigger: draft)
                Text("Counts toward your training load in Fitness.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .animation(.snappy, value: draft)
            .navigationTitle("How hard was it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
            }
            .alert("Couldn’t Save Your Effort", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                   presenting: failure) { _ in } message: { Text($0) }
        }
        .onAppear { if let score { draft = Double(score) } }
    }

    private func save() async {
        do {
            try await EffortRating.rate(workout, Int(draft), in: HealthKitService.shared.healthStore)
            score = Int(draft)
            dismiss()
        } catch {
            failure = (error as? HKError)?.code == .errorAuthorizationDenied
                ? "Turn on Workout Effort for MatchTracker in Health, under Sharing, Apps."
                : error.localizedDescription
        }
    }
}
