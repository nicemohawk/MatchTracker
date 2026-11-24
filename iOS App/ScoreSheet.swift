// ScoreSheet.swift
// MatchTracker

import MatchTrackerKit
import SwiftUI

/// How it went, while it's still fresh: what was logged on the pitch to confirm, and the rest to
/// fill in. Most of a match can be worked out from the watch; this can't.
struct ScoreSheet: View {
    @ObservedObject var detail: MatchDetailModel
    /// The app brought it up, rather than somebody going looking for it.
    var isAsking = false

    @EnvironmentObject private var store: MatchStore
    @Environment(\.dismiss) private var dismiss

    @State private var us = 0
    @State private var them = 0
    @State private var opponent = ""
    @State private var loadedOpponent = ""
    @State private var iScored = 0
    @State private var kinds: [UUID: MatchEventKind] = [:]
    @State private var offersReminders = false
    @State private var didLoad = false

    private var id: UUID { detail.matchIdentifier }

    private var marked: [MatchEvent] {
        detail.events.filter { MomentsChapter.isMoment($0.kind) }.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top) {
                        goals("Us", $us, color: Theme.turf)
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
                if !marked.isEmpty { moments }
                if !spells.isEmpty { bench }
                if offersReminders {
                    Section {
                        Button("Remind Me After Every Match") {
                            Task {
                                _ = await MatchReminders.shared.askToRemind()
                                offersReminders = false
                            }
                        }
                    }
                }
            }
            .navigationTitle("How Did It End?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isAsking ? "Not Now" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(marked.isEmpty && spells.isEmpty ? [.medium, .large] : [.large])
        .onChange(of: us) { _, value in iScored = min(iScored, value) }
        .sensoryFeedback(.selection, trigger: us + them * 100)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            let score = detail.record?.score
            us = score?.us ?? 0
            them = score?.them ?? 0
            iScored = score?.mine ?? 0
            opponent = detail.record?.opponent ?? ""
            loadedOpponent = opponent
        }
        .task { if isAsking { offersReminders = await MatchReminders.shared.remindsQuietly() } }
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

    // MARK: What was marked

    private var moments: some View {
        Section {
            ForEach(marked) { event in
                Picker(detail.minutes.text(for: event.date), selection: kind(of: event)) {
                    ForEach(Self.kinds, id: \.self) { Text($0 == .flag ? "Just a moment" : $0.momentTitle).tag($0) }
                }
            }
        } header: {
            Text("What you marked")
        }
    }

    private static let kinds: [MatchEventKind] = [.flag, .goalForUs, .goalMine, .assist, .goalAgainstUs,
                                                  .yellowCard, .redCard, .foul]

    /// Saying what a moment was moves the score with it.
    private func kind(of event: MatchEvent) -> Binding<MatchEventKind> {
        Binding(get: { kinds[event.id] ?? event.kind }, set: { new in
            let old = kinds[event.id] ?? event.kind
            kinds[event.id] = new
            us = max(0, us + Self.ours(new) - Self.ours(old))
            them = max(0, them + (new == .goalAgainstUs ? 1 : 0) - (old == .goalAgainstUs ? 1 : 0))
            iScored = min(max(0, iScored + (new == .goalMine ? 1 : 0) - (old == .goalMine ? 1 : 0)), us)
        })
    }

    private static func ours(_ kind: MatchEventKind) -> Int { kind == .goalForUs || kind == .goalMine ? 1 : 0 }

    // MARK: When they were off

    private struct Spell: Identifiable {
        let off: MatchEvent
        let on: MatchEvent?
        var id: UUID { off.id }
    }

    private var spells: [Spell] {
        let subs = detail.events.filter { $0.kind == .subOut || $0.kind == .subIn }.sorted { $0.date < $1.date }
        return subs.indices.compactMap { index in
            guard subs[index].kind == .subOut else { return nil }
            let next = index + 1 < subs.count ? subs[index + 1] : nil
            return Spell(off: subs[index], on: next?.kind == .subIn ? next : nil)
        }
    }

    private var bench: some View {
        Section {
            ForEach(spells) { spell in
                LabeledContent("\(detail.minutes.text(for: spell.off.date)) to \(spell.on.map { detail.minutes.text(for: $0.date) } ?? "the end")") {
                    Button("Wrong") {
                        for event in [spell.off, spell.on].compactMap({ $0 }) { _ = store.deleteEvent(event.id, from: id) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("When you were off")
        }
    }

    /// A result, not a list of goals: nobody remembers every minute. The ones logged as they
    /// happened keep theirs. 0–0 is a result too.
    private func save() {
        store.review(id, score: FinalScore(us: us, them: them, mine: iScored), kinds: kinds)
        if opponent != loadedOpponent { store.setOpponent(opponent, for: id) }
        MatchReminders.shared.reviewed(detail.recordedInterval.start)
    }
}
