// ScoreSheet.swift
// MatchTracker

import MatchTrackerKit
import SwiftUI

/// How it ended, while it's still fresh: two big numbers and who it was against. The rest of a
/// match can be worked out from the watch; this can't.
struct ScoreSheet: View {
    @ObservedObject var detail: MatchDetailModel
    @EnvironmentObject private var store: MatchStore
    @Environment(\.dismiss) private var dismiss

    @State private var us = 0
    @State private var them = 0
    @State private var opponent = ""
    @State private var loadedOpponent = ""
    @State private var iScored = 0
    @State private var didLoad = false

    private var id: UUID { detail.matchIdentifier }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top) {
                        goals("Us", $us, color: .green)
                        goals("Them", $them, color: .red)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("Opponent", text: $opponent)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                    OpponentSuggestionButton(start: detail.matchStart, end: detail.matchEnd,
                                             coordinate: detail.track.first?.coordinate) { opponent = $0 }
                    if us > 0 {
                        Stepper(value: $iScored, in: 0...us) {
                            LabeledContent("You scored", value: "\(iScored)")
                        }
                    }
                }
            }
            .navigationTitle("How Did It End?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: us) { _, value in iScored = min(iScored, value) }
        .sensoryFeedback(.selection, trigger: us + them * 100)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            us = detail.digest?.goalsUs ?? 0
            them = detail.digest?.goalsThem ?? 0
            iScored = detail.digest?.myGoals ?? 0
            opponent = detail.record?.opponent ?? ""
            loadedOpponent = opponent
        }
    }

    private func goals(_ title: String, _ value: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text("\(value.wrappedValue)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.snappy, value: value.wrappedValue)
                .minimumScaleFactor(0.5)
            Stepper(title, value: value, in: 0...30).labelsHidden()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    /// A result, not a list of goals: nobody remembers every minute. The ones logged as they
    /// happened keep theirs. 0–0 is a result too.
    private func save() {
        store.setFinalScore(FinalScore(us: us, them: them, mine: iScored), for: id)
        if opponent != loadedOpponent { store.setOpponent(opponent, for: id) }
    }
}
