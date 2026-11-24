// EffortRatingView.swift
// MatchTracker

import HealthKit
import MatchTrackerKit
import SwiftUI

/// Where a match's effort is rated, and read once it has been. Nothing without a saved workout to
/// rate, or before iOS 18.
struct EffortRatingRow: View {
    let workout: HKWorkout?

    var body: some View {
        if #available(iOS 18.0, *), let workout {
            RatedEffort(workout: workout)
        }
    }
}

@available(iOS 18.0, *)
private struct RatedEffort: View {
    let workout: HKWorkout
    @State private var score: Int?
    @State private var isRating = false

    var body: some View {
        Button { isRating = true } label: {
            HStack {
                if let score {
                    Text("You rated it")
                    Spacer()
                    Text("\(EffortRating.word(for: score)), \(score)").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Rate your effort").foregroundStyle(.tint)
                    Spacer()
                }
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        .font(.system(size: 80, weight: .bold, design: .rounded))
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
