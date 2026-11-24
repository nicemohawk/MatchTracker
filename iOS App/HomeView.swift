// HomeView.swift
// MatchTracker

import MatchTrackerKit
import SwiftUI

/// The Summary tab: the last match, then the season it belongs to.
struct HomeView: View {
    /// A match to open, from a widget, Siri or a notification. Cleared once opened.
    @Binding var openedMatch: UUID?

    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var fields: FieldsModel
    @State private var path = NavigationPath()
    @State private var showingSettings = false
    @State private var selectedTerm: SeasonSummary.Term?
    @State private var scoring: ScoringMatch?
    @Namespace private var transition

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let last = matches.latestDigest {
                    content(last: last)
                } else if matches.didCompleteInitialLoad, matches.matches.isEmpty {
                    NoMatchesView()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Summary")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "person.crop.circle") { showingSettings = true }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let summary = matches.matches.first(where: { $0.id == id }) {
                    MatchDetailView(summary: summary)
                        .zoomDestination(id: id, in: transition)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .fields: FieldsView()
                }
            }
            .refreshable { await matches.refresh() }
            .sheet(item: $scoring) { ScoreSheet(detail: $0.detail) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .onChange(of: openedMatch, initial: true) { _, id in
                guard let id else { return }
                path = NavigationPath([id])
                openedMatch = nil
            }
        }
    }

    private enum Destination: Hashable { case fields }

    private struct ScoringMatch: Identifiable {
        let detail: MatchDetailModel
        var id: UUID { detail.matchIdentifier }
    }

    private func scorable(_ digest: MatchDigest) -> MatchDetailModel? {
        matches.matches.first { $0.id == digest.id }.map(matches.detailModel(for:))
    }

    private func content(last: MatchDigest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                LiveMatchCard()
                LastMatchCard(digest: last, headline: matches.headline(for: last.id), isBest: matches.isBest(last))
                    .zoomSource(id: last.id, in: transition)
                    .onTapGesture { path.append(last.id) }
                    .accessibilityAddTraits(.isButton)
                if last.result == nil, keepsScore(last), let detail = scorable(last) {
                    Button {
                        scoring = ScoringMatch(detail: detail)
                    } label: {
                        Label("Add the Score", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .padding(.top, -16)
                }
                // A match to look forward to comes first; being asked to set that up can wait.
                let isFixture = FixtureStore.shared.isConnected
                if isFixture { nextMatch }
                season
                bests
                if !isFixture { nextMatch }
                places
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .readableWidth()
        }
    }

    private func keepsScore(_ digest: MatchDigest) -> Bool {
        let said = matches.matches.first { $0.id == digest.id }?.record?.keepsScore
        return said ?? settings.playHabits[digest.format].keepsScore ?? true
    }

    @ViewBuilder
    private var nextMatch: some View {
        if NextMatchCard.hasContent {
            NextMatchCard()
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: .rect(cornerRadius: 24))
        }
    }

    // MARK: - Season

    private var terms: [SeasonSummary.Term] {
        Array(Set(matches.playedDigests.map { SeasonSummary.Term(containing: $0.startDate) })).sorted(by: >)
    }

    private var term: SeasonSummary.Term? { selectedTerm ?? terms.first }

    private var termSummary: SeasonSummary {
        SeasonSummary(matches.playedDigests.filter { SeasonSummary.Term(containing: $0.startDate) == term })
    }

    @ViewBuilder
    private var season: some View {
        let summary = termSummary
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Season").font(.name(.title3))
                Spacer()
                if let term {
                    Menu(term.title) {
                        Picker("Season", selection: Binding(get: { term }, set: { selectedTerm = $0 })) {
                            ForEach(terms, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    .font(.body)
                }
            }
            VStack(alignment: .leading, spacing: 20) {
                SeasonHeader(summary: summary)
                if summary.matches.count >= 2 {
                    SeasonWall(matches: summary.matches, transition: transition) { path.append($0) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 24))
        }
    }

    // MARK: - Bests

    @ViewBuilder
    private var bests: some View {
        let all = SeasonSummary(matches.playedDigests)
        let holders = PersonalBest.allCases.compactMap { best in all.holder(of: best).map { (best, $0.digest, $0.value) } }
        if !holders.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Personal bests").font(.name(.title3))
                VStack(spacing: 0) {
                    ForEach(holders, id: \.0) { best, digest, value in
                        Button { path.append(digest.id) } label: {
                            BestRow(best: best, value: value, date: digest.startDate,
                                    isRecent: digest.id == matches.latestDigest?.id)
                        }
                        .buttonStyle(.plain)
                        if best != holders.last?.0 { Divider().padding(.leading, 60) }
                    }
                }
                .background(Theme.surface, in: .rect(cornerRadius: 24))
            }
        }
    }

    private var places: some View {
        NavigationLink(value: Destination.fields) {
            HStack {
                Label("Fields", systemImage: "map")
                Spacer()
                Text("\(fields.fields.count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(20)
            .background(Theme.surface, in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Last match

/// The match just played: the score and the numbers on the turf, beside the heat of it.
struct LastMatchCard: View {
    let digest: MatchDigest
    let headline: String?
    /// Better than every match before it, at something.
    var isBest = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isWide: Bool { horizontalSizeClass == .regular }

    private var isStacked: Bool {
        dynamicTypeSize.isAccessibilitySize || (digest.heat == nil && digest.strip == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let scoreline = digest.scoreline {
                    KitNumber(scoreline, size: 56).accessibilityLabel(scoreline.replacingOccurrences(of: "–", with: " to "))
                } else {
                    Text(digest.place).font(.name(.title)).lineLimit(2).minimumScaleFactor(0.7)
                }
                Text(digest.subtitle(beside: digest.scoreline ?? digest.place))
                    .font(.headline)
                    .opacity(0.8)
            }
            if isStacked {
                DigestNumbers(digest: digest, style: .kit)
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    DigestNumbers(digest: digest, style: .kit)
                    Spacer(minLength: 0)
                    pitch.modifier(WovenIn(id: digest.id))
                }
            }
            if let headline {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isBest ? Theme.trimOnCloth : Theme.ivory)
            }
        }
        .foregroundStyle(Theme.ivory)
        .padding(22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Cloth(isBest: isBest) }
        .contentShape(.rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pitch: some View {
        if let heat = digest.heat {
            HeatPitch(heat: PitchHeat(digestHeat: heat), surface: .clear, insets: EdgeInsets(),
                      directionIsKnown: digest.heatIsDirected ?? false)
                .background(Theme.cloth)
                .aspectRatio(HeatPitch.aspectRatio(for: .standard), contentMode: .fit)
                .frame(maxWidth: isWide ? 260 : 176)
                .accessibilityHidden(true)
        } else if let strip = digest.strip {
            EffortStripView(levels: strip)
                .aspectRatio(HeatPitch.aspectRatio(for: .standard), contentMode: .fit)
                .frame(maxWidth: isWide ? 260 : 176)
        }
    }
}

/// The first time a match is seen, its cloth is knitted from the bottom row up.
private struct WovenIn: ViewModifier {
    let id: UUID
    @AppStorage("lastWovenMatch") private var lastWoven = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1
    @State private var completions = 0

    func body(content: Content) -> some View {
        content
            .mask(alignment: .bottom) { Rectangle().scaleEffect(x: 1, y: progress, anchor: .bottom) }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: completions)
            .task(id: id) {
                guard lastWoven != id.uuidString else { return }
                lastWoven = id.uuidString
                guard !reduceMotion else { return }
                progress = 0
                withAnimation(.easeOut(duration: 1.1).delay(0.35)) { progress = 1 } completion: { completions += 1 }
            }
    }
}

/// The three numbers a match is remembered by. Fewer when fewer are known.
struct DigestNumbers: View {
    let digest: MatchDigest
    /// `.kit` is for cloth: the first number big and cut, the others beneath it.
    enum Style { case row, kit }
    var style = Style.row

    private struct Number {
        let label: String
        let value: String
        let unit: String
        let spoken: String
    }

    private var numbers: [Number] {
        let units = UnitSystem.current
        var numbers: [Number] = []
        if let meters = digest.distanceMeters, meters > 100 {
            let distance = units.distance(meters)
            numbers.append(Number(label: "Distance", value: distance.value, unit: distance.unit, spoken: distance.spoken))
        }
        let minutes = Int((digest.secondsOnPitch / 60).rounded())
        numbers.append(Number(label: "Played", value: "\(minutes)", unit: "min", spoken: "\(minutes) minutes"))
        if let speed = digest.topSpeedMetersPerSecond {
            let measure = units.speed(speed)
            numbers.append(Number(label: "Top speed", value: measure.value, unit: measure.unit, spoken: measure.spoken))
        } else if let bpm = digest.averageHeartRate {
            numbers.append(Number(label: "Heart rate", value: "\(Int(bpm))", unit: "bpm", spoken: "\(Int(bpm)) beats per minute"))
        }
        return numbers
    }

    var body: some View {
        switch style {
        case .kit:
            VStack(alignment: .leading, spacing: 14) {
                if let first = numbers.first { big(first) }
                ForEach(numbers.dropFirst(), id: \.label) { view($0) }
            }
        case .row:
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    ForEach(numbers, id: \.label) { number in
                        view(number).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(numbers, id: \.label) { view($0) }
                }
            }
        }
    }

    private func big(_ number: Number) -> some View {
        VStack(alignment: .leading, spacing: -4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                KitNumber(number.value, size: 76)
                Text(number.unit).font(.title3.weight(.semibold)).opacity(0.8)
            }
            Text(number.label).font(.subheadline).opacity(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number.label), \(number.spoken)")
    }

    private var supporting: Color { style == .kit ? Theme.ivory.opacity(0.8) : Theme.secondaryLabel }

    private func view(_ number: Number) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number.value)
                    .font(.system(.largeTitle, weight: .heavy).width(.compressed))
                    .monospacedDigit()
                Text(number.unit).font(.subheadline.weight(.medium)).foregroundStyle(supporting)
            }
            Text(number.label).font(.subheadline).foregroundStyle(supporting)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number.label), \(number.spoken)")
    }
}

/// The way to the live match where the tab bar can't carry one.
private struct LiveMatchCard: View {
    @Environment(LiveMatchStore.self) private var liveMatches
    @State private var isShowing = false

    private var isNeeded: Bool {
        if #available(iOS 26.1, *) { return false }
        return liveMatches.isLive
    }

    var body: some View {
        if isNeeded, let state = liveMatches.state {
            Button { isShowing = true } label: {
                HStack {
                    Label(state.status, systemImage: "dot.radiowaves.left.and.right").font(.headline)
                    Spacer()
                    if let score = state.score { Text(score).font(.title2.bold()).monospacedDigit() }
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(20)
                .background(Theme.surface, in: .rect(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the live match")
            .sheet(isPresented: $isShowing) {
                NavigationStack { LiveMatchView(store: liveMatches, showsClose: true) }
            }
        }
    }
}

// MARK: - Season pieces

/// The record when enough of the season has one, or else how much was played. A record of three
/// results in thirty matches isn't the season.
private struct SeasonHeader: View {
    let summary: SeasonSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var results: Int { summary.won + summary.drawn + summary.lost }
    private var recordLeads: Bool { results > 0 && results * 2 >= summary.matches.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if recordLeads {
                record
            } else {
                piece(summary.matches.count, summary.matches.count == 1 ? "match" : "matches", .primary)
            }
            Text(sentence).font(.headline).foregroundStyle(.secondary)
        }
    }

    private var record: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 24))
        return layout {
            piece(summary.won, "won", Theme.turf)
            piece(summary.drawn, "drawn", Theme.draw)
            piece(summary.lost, "lost", Theme.loss)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Won \(summary.won), drawn \(summary.drawn), lost \(summary.lost)")
    }

    private func piece(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            KitNumber("\(count)", size: 54)
                .foregroundStyle(count == 0 ? Theme.secondaryLabel : color)
            Text(label).font(.body).foregroundStyle(.secondary)
        }
    }

    private var sentence: String {
        func counted(_ count: Int, _ noun: String) -> String? { count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s")" : nil }
        var parts: [String?] = []
        if recordLeads {
            if results != summary.matches.count { parts.append("\(summary.matches.count) matches") }
        } else if results > 0 {
            let record = [summary.won > 0 ? "won \(summary.won)" : nil, summary.drawn > 0 ? "drew \(summary.drawn)" : nil,
                          summary.lost > 0 ? "lost \(summary.lost)" : nil].compactMap { $0 }.joined(separator: ", ")
            parts.append(record.prefix(1).uppercased() + record.dropFirst())
        }
        if summary.distanceMeters > 500 { parts.append(UnitSystem.current.totalDistance(summary.distanceMeters).text) }
        parts += [counted(summary.goals, "goal"), counted(summary.assists, "assist")]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// The season as it was played: every match's pitch in order, newest first, ringed by its result.
/// Touch one to open it.
private struct SeasonWall: View {
    let matches: [MatchDigest]
    let transition: Namespace.ID
    let onOpen: (UUID) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsAll = false

    private static let firstRows = 24

    private var shown: [MatchDigest] {
        let newestFirst = Array(matches.reversed())
        return showsAll ? newestFirst : Array(newestFirst.prefix(Self.firstRows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 76 : 50), spacing: 3)],
                      spacing: 3) {
                ForEach(shown) { digest in
                    Button { onOpen(digest.id) } label: { SeasonTile(digest: digest) }
                        .buttonStyle(.plain)
                        .zoomSource(id: digest.id, in: transition)
                }
            }
            if matches.count > shown.count {
                Button("Show All \(matches.count)") { withAnimation { showsAll = true } }
                    .frame(minHeight: 44)
            }
        }
    }
}

private struct SeasonTile: View {
    let digest: MatchDigest

    var body: some View {
        ZStack {
            if let heat = digest.heat {
                HeatPitch(heat: PitchHeat(digestHeat: heat), insets: EdgeInsets(),
                          directionIsKnown: digest.heatIsDirected ?? false)
            } else if let strip = digest.strip {
                EffortStripView(levels: strip)
            } else {
                Cloth(cornerRadius: 0, hasPinstripe: false, hasHem: false)
                Image(systemName: digest.format == .indoor ? "house.fill" : "soccerball").foregroundStyle(Theme.ivory.opacity(0.7))
            }
        }
        .aspectRatio(HeatPitch.aspectRatio(for: .standard), contentMode: .fit)
        .overlay(alignment: .bottom) { hem }
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(digest.startDate.formatted(date: .abbreviated, time: .omitted))
        .accessibilityValue([digest.scoreline ?? digest.place, digest.distanceMeters.map { UnitSystem.current.distance($0).spoken }]
            .compactMap { $0 }.joined(separator: ", "))
    }

    /// A win has a hem, a draw a thin one. What it was is also in the words.
    @ViewBuilder
    private var hem: some View {
        switch digest.result {
        case .won: Theme.ivory.frame(height: 5)
        case .drawn: Theme.ivory.frame(height: 1.5).padding(.bottom, 2)
        case .lost, nil: EmptyView()
        }
    }
}

private struct BestRow: View {
    let best: PersonalBest
    let value: Double
    let date: Date
    let isRecent: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: best.symbolName)
                .font(.title2)
                .foregroundStyle(Theme.turf)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(best.title).font(.body)
                Text(isRecent ? "Your last match" : date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(best.formatted(value))
                .font(.figure(.title2))
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Words

extension PersonalBest {
    var title: String {
        switch self {
        case .topSpeed: return "Top speed"
        case .distance: return "Farthest"
        case .sprints: return "Most sprints"
        case .goals: return "Most goals"
        case .longestMatch: return "Most minutes"
        case .recovery: return "Quickest recovery"
        }
    }

    var symbolName: String {
        switch self {
        case .topSpeed: return "hare.fill"
        case .distance: return "figure.run"
        case .sprints: return "bolt.fill"
        case .goals: return "soccerball"
        case .longestMatch: return "clock.fill"
        case .recovery: return "heart.fill"
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .topSpeed: return UnitSystem.current.speed(value).text
        case .distance: return UnitSystem.current.distance(value).text
        case .sprints, .goals: return "\(Int(value))"
        case .longestMatch: return "\(Int((value / 60).rounded())) min"
        case .recovery: return "\(Int(value)) bpm"
        }
    }
}

extension MatchTrackerKit.MatchFormat {
    var title: String {
        switch self {
        case .match: return "Match"
        case .smallSided: return "Pickup"
        case .indoor: return "Indoor"
        }
    }
}

extension MatchDigest {
    /// "Won 3–1", or nil when no score was logged.
    var scoreline: String? {
        if let games { return games.title }
        guard let result, let goalsUs, let goalsThem else { return nil }
        let word: String
        switch result {
        case .won: word = "Won"
        case .drawn: word = "Drew"
        case .lost: word = "Lost"
        }
        return "\(word) \(goalsUs)–\(goalsThem)"
    }

    /// What a match is called before anyone says who won: who it was against, or where.
    var place: String { opponent.map { "vs \($0)" } ?? fieldName ?? format.title }

    /// "Sunday · Demo Park", "Nov 7 · vs Rovers · Field 2": whatever `title` doesn't already say.
    func subtitle(beside title: String) -> String {
        let day: String
        if Calendar.current.isDateInToday(startDate) {
            day = "Today"
        } else if Calendar.current.isDateInYesterday(startDate) {
            day = "Yesterday"
        } else if startDate > Date().addingTimeInterval(-6 * 86_400) {
            day = startDate.formatted(.dateTime.weekday(.wide))
        } else {
            let sameYear = Calendar.current.isDate(startDate, equalTo: Date(), toGranularity: .year)
            day = startDate.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
        }
        let kind = format == .match ? nil : format.title
        return ([day] + [opponent.map { "vs \($0)" }, fieldName, kind].compactMap { $0 }.filter { $0 != title })
            .joined(separator: " · ")
    }
}

// MARK: - Zoom transitions

extension View {
    /// The tapped picture becomes the screen it opens (iOS 18 and later; a plain push before).
    @ViewBuilder
    func zoomSource(id: UUID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomDestination(id: UUID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
