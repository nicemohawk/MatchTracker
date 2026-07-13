//
//  FieldTrainingView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Modernized touchline-training flow: walk the perimeter of the pitch to define a field.
/// Shows live distance, auto-finishes when the loop closes, then fits a rectangle and saves +
/// shares the trained field.
struct FieldTrainingView: View {
    @Environment(ConnectivityManager.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @State private var trainer = FieldTrainer()
    @State private var name = "New Field"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch trainer.state {
                case .idle:
                    idleContent
                case .walking:
                    walkingContent
                case .finished:
                    finishedContent
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Train Field")
    }

    private var idleContent: some View {
        VStack(spacing: 10) {
            Text("Stand at a corner, then walk the touchline around the pitch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                trainer.start()
            } label: {
                Label("Start Walking", systemImage: "figure.walk")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
        }
    }

    private var walkingContent: some View {
        VStack(spacing: 10) {
            Text(String(format: "%.0f m", trainer.distanceWalked))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .monospacedDigit()
            Text("\(trainer.sampleCount) points")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Return to your start to finish.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Finish Now") { trainer.finish() }
                .tint(.orange)
        }
    }

    private var finishedContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(String(format: "Walked %.0f m", trainer.distanceWalked))
                .font(.headline)
            TextField("Field name", text: $name)
            Button("Save Field") { saveField() }
                .tint(.green)
                .disabled(trainer.makeField(named: name) == nil)
            Button("Discard") { dismiss() }
                .tint(.secondary)
        }
    }

    private func saveField() {
        guard let field = trainer.makeField(named: name) else { return }
        try? AppGroupStorage.fieldStore.save(field)
        connectivity.send(field: field)
        dismiss()
    }
}
