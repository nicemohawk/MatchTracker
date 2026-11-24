// HomeView.swift
// MatchTracker

import Charts
import MatchTrackerKit
import SwiftUI

/// The Summary tab: the last match, then the season it belongs to.
struct HomeView: View {
    /// A match to open, from a widget, Siri or a notification. Cleared once opened.
    @Binding var openedMatch: UUID?

    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var fields: FieldsModel
    @State private var path = NavigationPath()
    @State private var showingSettings = false
    @State private var selectedTerm: SeasonSummary.Term?
    @State private var selectedDay: Date?
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
            .background(Color(.systemGroupedBackground))
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
                LastMatchCard(digest: last, headline: matches.headline(for: last.id))
                    .zoomSource(id: last.id, in: transition)
                    .onTapGesture { path.append(last.id) }
                    .accessibilityAddTraits(.isButton)
                if last.result == nil, let detail = scorable(last) {
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
                if NextMatchCard.hasContent {
                    NextMatchCard()
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                }
                season
                bests
                places
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .readableWidth()
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
                Text("Season").font(.title2.bold())
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
                if summary.hasResults { RecordLine(summary: summary) }
                SeasonTotals(summary: summary)
                if summary.matches.count >= 2 {
                    SeasonChart(matches: summary.matches, selection: $selectedDay) { path.append($0) }
                        .frame(height: 180)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        }
    }

    // MARK: - Bests

    @ViewBuilder
    private var bests: some View {
        let all = SeasonSummary(matches.playedDigests)
        let holders = PersonalBest.allCases.compactMap { best in all.holder(of: best).map { (best, $0.digest, $0.value) } }
        if !holders.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Personal bests").font(.title2.bold())
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
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
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
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Last match

/// The match just played: the score and the numbers on the turf, beside the heat of it.
struct LastMatchCard: View {
    let digest: MatchDigest
    let headline: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(digest.scoreline ?? digest.format.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text(digest.subtitle)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if dynamicTypeSize.isAccessibilitySize || digest.heat == nil {
                DigestNumbers(digest: digest)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    DigestNumbers(digest: digest, isStacked: true)
                    Spacer(minLength: 0)
                    pitch
                }
            }
            if let headline {
                Text(headline).font(.title3.weight(.medium))
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.05, green: 0.20, blue: 0.14), Color(red: 0.02, green: 0.10, blue: 0.08)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(.rect(cornerRadius: 28))
        .contentShape(.rect(cornerRadius: 28))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pitch: some View {
        if let heat = digest.heat {
            HeatPitch(heat: PitchHeat(digestHeat: heat), surface: .clear, insets: EdgeInsets(),
                      directionIsKnown: digest.heatIsDirected ?? false)
                .frame(width: 168, height: 168 / HeatPitch.aspectRatio(for: .standard))
                .accessibilityHidden(true)
        }
    }
}

/// The three numbers a match is remembered by. Fewer when fewer are known.
struct DigestNumbers: View {
    let digest: MatchDigest
    var isStacked = false

    private var numbers: [(value: String, unit: String?, spoken: String)] {
        let units = UnitSystem.current
        var numbers: [(String, String?, String)] = []
        if let meters = digest.distanceMeters, meters > 100 {
            let distance = units.distance(meters)
            numbers.append((distance.value, distance.unit, distance.spoken))
        }
        let minutes = Int((digest.secondsOnPitch / 60).rounded())
        numbers.append(("\(minutes)", "min", "\(minutes) minutes played"))
        if let speed = digest.topSpeedMetersPerSecond {
            let measure = units.speed(speed)
            numbers.append((measure.value, "\(measure.unit) top", "top speed \(measure.spoken)"))
        } else if let bpm = digest.averageHeartRate {
            numbers.append(("\(Int(bpm))", "bpm", "average heart rate \(Int(bpm))"))
        }
        return numbers
    }

    var body: some View {
        if isStacked {
            stack
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    ForEach(numbers, id: \.spoken) { number in
                        view(number).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                stack
            }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(numbers, id: \.spoken) { view($0) }
        }
    }

    private func view(_ number: (value: String, unit: String?, spoken: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(number.value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
            if let unit = number.unit {
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(number.spoken)
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
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
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

private struct RecordLine: View {
    let summary: SeasonSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 24))
        layout {
            piece(summary.won, "Won", Theme.turf)
            piece(summary.drawn, "Drew", .secondary)
            piece(summary.lost, "Lost", .red)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Won \(summary.won), drew \(summary.drawn), lost \(summary.lost)")
    }

    private func piece(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(count)")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? .secondary : color)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct SeasonTotals: View {
    let summary: SeasonSummary

    private var sentence: String {
        let matches = summary.matches.count
        var parts = ["\(matches) \(matches == 1 ? "match" : "matches")"]
        if summary.distanceMeters > 500 { parts.append(UnitSystem.current.distance(summary.distanceMeters).text) }
        if summary.goals > 0 { parts.append("\(summary.goals) \(summary.goals == 1 ? "goal" : "goals")") }
        if summary.assists > 0 { parts.append("\(summary.assists) \(summary.assists == 1 ? "assist" : "assists")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Text(sentence).font(.headline)
    }
}

/// One bar per match, tall as the ground covered and colored by the result. Tap a bar for the match.
private struct SeasonChart: View {
    let matches: [MatchDigest]
    @Binding var selection: Date?
    let onOpen: (UUID) -> Void

    var body: some View {
        Chart(Array(matches.enumerated()), id: \.element.id) { index, digest in
            BarMark(x: .value("Match", String(index)),
                    y: .value("Distance", distance(digest)))
                .foregroundStyle(color(digest))
                .cornerRadius(4)
                .accessibilityLabel(digest.startDate.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue([digest.scoreline, digest.distanceMeters.map { UnitSystem.current.distance($0).spoken }]
                    .compactMap { $0 }.joined(separator: ", "))
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...max((matches.map(distance).max() ?? 1) * 1.1, 1))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .chartYAxisLabel(UnitSystem.current.distance(0).unit)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame,
                              let label: String = proxy.value(atX: location.x - geometry[frame].origin.x),
                              let index = Int(label), matches.indices.contains(index) else { return }
                        onOpen(matches[index].id)
                    }
            }
        }
    }

    private func distance(_ digest: MatchDigest) -> Double {
        let meters = digest.distanceMeters ?? 0
        return UnitSystem.current == .imperial ? meters / 1609.344 : meters / 1000
    }

    private func color(_ digest: MatchDigest) -> Color {
        switch digest.result {
        case .won: return Theme.turf
        case .lost: return .red
        case .drawn, nil: return Color(.systemGray3)
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
                .foregroundStyle(.green)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(best.title).font(.body)
                Text(isRecent ? "Your last match" : date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(best.formatted(value))
                .font(.system(.title3, design: .rounded, weight: .semibold))
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
        }
    }

    var symbolName: String {
        switch self {
        case .topSpeed: return "hare.fill"
        case .distance: return "figure.run"
        case .sprints: return "bolt.fill"
        case .goals: return "soccerball"
        case .longestMatch: return "clock.fill"
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .topSpeed: return UnitSystem.current.speed(value).text
        case .distance: return UnitSystem.current.distance(value).text
        case .sprints, .goals: return "\(Int(value))"
        case .longestMatch: return "\(Int((value / 60).rounded())) min"
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
        guard let result, let goalsUs, let goalsThem else { return nil }
        let word: String
        switch result {
        case .won: word = "Won"
        case .drawn: word = "Drew"
        case .lost: word = "Lost"
        }
        return "\(word) \(goalsUs)–\(goalsThem)"
    }

    /// "Sunday · Demo Park", "Nov 7 · vs Rovers · Field 2".
    var subtitle: String {
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
        return [day, opponent.map { "vs \($0)" }, fieldName].compactMap { $0 }.joined(separator: " · ")
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
