// ScoreSheet.swift
// MatchTracker

import MatchTrackerKit
import SwiftUI

/// How it went, while it's still fresh: what was logged on the pitch to confirm, and the rest to
/// fill in. It starts from how this player said the last match like it was played: not everyone
/// counts, and not every session is one match.
struct ScoreSheet: View {
    @ObservedObject var detail: MatchDetailModel
    /// The app brought it up, rather than somebody going looking for it.
    var isAsking = false

    @EnvironmentObject private var store: MatchStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var keepsScore = true
    @State private var us = 0
    @State private var them = 0
    @State private var myGoals = 0
    @State private var myAssists = 0
    @State private var opponent = ""
    @State private var loadedOpponent = ""
    @State private var isSeveral = false
    @State private var games: [GameResult] = []
    @State private var kinds: [UUID: MatchEventKind] = [:]
    @State private var offersReminders = false
    @State private var didLoad = false

    private var id: UUID { detail.matchIdentifier }
    private var format: MatchTrackerKit.MatchFormat { detail.matchFormat }

    private var marked: [MatchEvent] {
        detail.events.filter { MomentsChapter.isMoment($0.kind) }.sorted { $0.date < $1.date }
    }

    /// Worth asking when there were breaks in the playing, or last time there were several.
    private var maybeSeveral: Bool {
        (detail.analytics?.stints?.games.count ?? 0) > 1 || settings.playHabits[format].playsSeveralGames == true
            || detail.record?.games != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if keepsScore, !isSeveral {
                    Section {
                        HStack(alignment: .top) {
                            goals("Us", $us, color: Theme.turf)
                            goals("Them", $them, color: .red)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if maybeSeveral { session }
                Section {
                    Stepper(value: $myGoals, in: 0...30) {
                        LabeledContent("You scored", value: "\(myGoals)")
                    }
                    Stepper(value: $myAssists, in: 0...30) {
                        LabeledContent("You set up", value: "\(myAssists)")
                    }
                }
                if !marked.isEmpty { moments }
                if !spells.isEmpty { bench }
                Section {
                    if keepsScore {
                        TextField("Opponent", text: $opponent)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                        OpponentSuggestionButton(start: detail.matchStart, end: detail.matchEnd,
                                                 coordinate: detail.track.first?.coordinate) { opponent = $0 }
                    }
                    Toggle("We keep score", isOn: $keepsScore.animation())
                } footer: {
                    Text("Remembered for \(format.plural).")
                }
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
            .navigationTitle(keepsScore ? "How Did It End?" : "How Did It Go?")
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
        .presentationDetents([.large])
        // Mine are some of ours.
        .onChange(of: us) { _, value in if keepsScore, !isSeveral { myGoals = min(myGoals, value) } }
        .onChange(of: myGoals) { _, value in us = max(us, value) }
        .sensoryFeedback(.selection, trigger: us + them * 100)
        .onAppear(perform: load)
        .task { if isAsking { offersReminders = await MatchReminders.shared.remindsQuietly() } }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let record = detail.record, habit = settings.playHabits[format]
        keepsScore = record?.keepsScore ?? habit.keepsScore ?? true
        let score = record?.finalScore ?? record?.loggedScore
        us = score?.us ?? 0
        them = score?.them ?? 0
        myGoals = detail.digest?.myGoals ?? 0
        myAssists = detail.digest?.myAssists ?? 0
        opponent = record?.opponent ?? ""
        loadedOpponent = opponent
        isSeveral = record?.games != nil || (record?.finalScore == nil && habit.playsSeveralGames == true)
        games = suggestedGames
    }

    private var suggestedGames: [GameResult] {
        Games.inSession(record: detail.record, stints: detail.analytics?.stints, interval: detail.playedInterval,
                        length: settings.playHabits[format].gameSeconds)
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

    // MARK: One match or several

    private var session: some View {
        Section {
            Picker("It was", selection: $isSeveral.animation()) {
                Text("One match").tag(false)
                Text("Several games").tag(true)
            }
            if isSeveral {
                Stepper(value: gameCount, in: 2...20) { LabeledContent("Games", value: "\(max(games.count, 2))") }
                if keepsScore {
                    ForEach($games) { $game in
                        Picker(game.start.formatted(date: .omitted, time: .shortened), selection: $game.outcome) {
                            Text("Not sure").tag(MatchDigest.Result?.none)
                            Text("Won").tag(MatchDigest.Result?.some(.won))
                            Text("Drew").tag(MatchDigest.Result?.some(.drawn))
                            Text("Lost").tag(MatchDigest.Result?.some(.lost))
                        }
                    }
                }
            }
        }
        .onChange(of: isSeveral) { _, several in
            if several, games.count < 2 { setGameCount(2) }
        }
    }

    private var gameCount: Binding<Int> {
        Binding(get: { max(games.count, 2) }, set: setGameCount)
    }

    /// As many as they say, over the time that was played. Outcomes already given stay where they are.
    private func setGameCount(_ count: Int) {
        let played = detail.analytics?.playingIntervals ?? [detail.playedInterval]
        let length = played.reduce(0) { $0 + $1.duration } / Double(count)
        var fresh = Games.inSession(record: nil, stints: detail.analytics?.stints, interval: detail.playedInterval, length: length)
        if fresh.count != count {
            let slice = detail.playedInterval.duration / Double(count)
            fresh = (0..<count).map {
                let start = detail.playedInterval.start.addingTimeInterval(slice * Double($0))
                return GameResult(start: start, end: start.addingTimeInterval(slice))
            }
        }
        for index in fresh.indices where index < games.count { fresh[index].outcome = games[index].outcome }
        withAnimation { games = fresh }
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

    /// Saying what a moment was moves the count with it.
    private func kind(of event: MatchEvent) -> Binding<MatchEventKind> {
        Binding(get: { kinds[event.id] ?? event.kind }, set: { new in
            let old = kinds[event.id] ?? event.kind
            kinds[event.id] = new
            func change(_ kind: MatchEventKind) -> Int { (new == kind ? 1 : 0) - (old == kind ? 1 : 0) }
            us = max(0, us + change(.goalForUs) + change(.goalMine))
            them = max(0, them + change(.goalAgainstUs))
            myGoals = max(0, myGoals + change(.goalMine))
            myAssists = max(0, myAssists + change(.assist))
        })
    }

    // MARK: When they were off

    private struct Spell: Identifiable {
        let off: MatchEvent
        let on: MatchEvent?
        var id: UUID { off.id }
    }

    private var spells: [Spell] {
        // Indoors they roll all night, and the stints are the better account of it.
        guard detail.analytics?.stints == nil else { return [] }
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
        let severalGames = isSeveral && games.count > 1 ? games : nil
        store.review(id, MatchStore.Review(
            keepsScore: keepsScore, score: FinalScore(us: max(us, keepsScore ? myGoals : 0), them: them, mine: myGoals),
            games: severalGames, assists: myAssists, kinds: kinds))
        if opponent != loadedOpponent { store.setOpponent(opponent, for: id) }
        let played = detail.analytics?.playingIntervals.reduce(0) { $0 + $1.duration } ?? 0
        settings.playHabits.learn(format: format, keepsScore: keepsScore,
                                  games: maybeSeveral ? severalGames?.count ?? 1 : nil, played: played)
        environment.settingsChanged()
        MatchReminders.shared.reviewed(detail.recordedInterval.start)
    }
}

private extension MatchTrackerKit.MatchFormat {
    var plural: String {
        switch self {
        case .match: return "matches"
        case .smallSided: return "pickup matches"
        case .indoor: return "indoor matches"
        }
    }
}
