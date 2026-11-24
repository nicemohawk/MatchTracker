// TeamMatchesView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// The team's matches, for everyone on it: who's on right now, who has played how much, and what happened.
/// A plain list on iPhone; on iPad the live pitch sits beside the players.
struct TeamMatchesView: View {
    let teamCode: String

    @Environment(LiveMatchStore.self) private var liveMatches
    @State private var model: TeamMatchesModel
    @State private var chosenPane: Pane?

    enum Pane: String, CaseIterable { case live = "Live", minutes = "Minutes", events = "Events" }

    init(teamCode: String) {
        self.teamCode = teamCode
        _model = State(initialValue: TeamMatchesModel(teamCode: teamCode))
        #if DEBUG
        _chosenPane = State(initialValue: UserDefaults.standard.string(forKey: "TeamPane").flatMap(Pane.init))
        #endif
    }

    /// Opens on whatever there is to see: the match if one is on, otherwise the minutes.
    private var pane: Pane { chosenPane ?? (model.players.isEmpty ? .minutes : .live) }

    var body: some View {
        Group {
            switch pane {
            case .live: TeamLivePane(model: model)
            case .minutes: TeamMinutesPane(model: model)
            case .events: TeamEventsPane(model: model)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: Binding(get: { pane }, set: { chosenPane = $0 })) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .readableWidth()
        }
        .canvasBackground()
        .navigationTitle("Team Matches")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadHistory() }
        .task { await model.follow(liveMatches) }
    }
}

// MARK: - Live

private struct TeamLivePane: View {
    let model: TeamMatchesModel

    @EnvironmentObject private var settings: SettingsStore
    @State private var width: CGFloat = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder private var content: some View {
        if model.players.isEmpty {
            switch model.livePhase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't reach the live match", systemImage: "wifi.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.refreshLive() } }
                        .buttonStyle(.prominentAction)
                }
            case .loaded:
                ContentUnavailableView("Nobody's playing right now", systemImage: "figure.soccer",
                                       description: Text("Players appear here when they start a match on Apple Watch."))
            }
        } else if width > 720 {
            HStack(alignment: .top, spacing: 0) {
                pitch
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                List { Group { playerSections }.listRowBackground(Theme.surface) }
                    .frame(width: 320)
            }
        } else {
            List {
                Group {
                    if model.players.contains(where: \.hasPlace) {
                        Section {
                            pitch
                                .frame(height: 400)
                                .frame(maxWidth: .infinity)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    playerSections
                }
                .listRowBackground(Theme.surface)
            }
            .contentMargins(.top, 8, for: .scrollContent)
        }
    }

    private var pitch: some View {
        GeometryReader { geometry in
            let rect = PortraitPitch.fittedRect(in: geometry.size)
            ZStack {
                PortraitPitch()
                ForEach(model.players.filter(\.hasPlace), id: \.playerName) { player in
                    TeamMarker(player: player, isMe: settings.isMe(player.playerName))
                        .position(PortraitPitch.point(x: player.x ?? 0, y: player.y ?? 0, in: rect))
                }
            }
            .animation(.smooth, value: model.players.map { "\($0.x ?? 0),\($0.y ?? 0)" })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenPitch)
    }

    private var spokenPitch: String {
        let placed = model.players.filter(\.hasPlace)
        return "Live positions. " + placed.map { player in
            "\(player.playerName), \(FormationShape.role(x: player.x ?? 0, y: player.y ?? 0).lowercased())"
        }.joined(separator: ". ")
    }

    @ViewBuilder private var playerSections: some View {
        let current = model.players.filter { !$0.stale }
        section("On the pitch", current.filter(\.onPitch))
        section("On the bench", current.filter { !$0.onPitch })
        section("Not heard from", model.players.filter(\.stale))
    }

    @ViewBuilder
    private func section(_ title: String, _ players: [LivePlayerStatus]) -> some View {
        if !players.isEmpty {
            Section("\(title) (\(players.count))") {
                ForEach(players, id: \.playerName) { player in
                    TeamLiveRow(player: player)
                }
            }
        }
    }
}

private extension LivePlayerStatus {
    var hasPlace: Bool { x != nil && y != nil && onPitch }
}

private struct TeamMarker: View {
    let player: LivePlayerStatus
    let isMe: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(RosterAvatar.initials(from: player.playerName))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(player.stale ? Color.white : Theme.cloth)
                .frame(width: 36, height: 36)
                .background(player.stale ? Color.gray : isMe ? Color(cgColor: Knit.yarns[2]) : Theme.ivory, in: Circle())
            Text(isMe ? "You" : RosterAvatar.shortName(player.playerName))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize()
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

private struct TeamLiveRow: View {
    let player: LivePlayerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TeamPlayerName(name: player.playerName)
            if player.stale {
                Text("Last heard \(player.updatedAt, format: .relative(presentation: .named))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(UnitSystem.current.distance(player.distanceMeters).text)
                    .accessibilityLabel(UnitSystem.current.distance(player.distanceMeters).spoken)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Minutes

private struct TeamMinutesPane: View {
    let model: TeamMatchesModel

    @EnvironmentObject private var settings: SettingsStore
    @State private var chosenOrder: Bool?

    /// A coach is looking for who has played least; everyone else for who has played most.
    private var isLeastFirst: Bool { chosenOrder ?? (settings.team(model.teamCode)?.isCoach ?? false) }

    var body: some View {
        switch model.historyPhase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load minutes", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.loadHistory() } }
                    .buttonStyle(.prominentAction)
            }
        case .loaded where model.matches.isEmpty:
            ContentUnavailableView("No matches to count", systemImage: "clock",
                                   description: Text("Minutes appear once someone records a match on Apple Watch."))
        case .loaded:
            List {
                Group {
                    Section {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                title
                                Spacer()
                                orderPicker
                            }
                            VStack(alignment: .leading) {
                                title
                                orderPicker.padding(.leading, -12)
                            }
                        }
                        ForEach(rows, id: \.name) { row in
                            TeamMinutesRow(name: row.name, load: row.load)
                        }
                    } footer: {
                        Text("Counted from each player's watch, without half-time or time on the bench. A dash means nothing was recorded.")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .contentMargins(.top, 8, for: .scrollContent)
            .readableFormWidth()
            .refreshable { await model.loadHistory() }
        }
    }

    private var title: some View {
        Text(model.matches.count == 1 ? "Last match" : "Last \(min(5, model.matches.count)) matches")
            .font(.name(.title3))
    }

    private var orderPicker: some View {
        Picker("Order", selection: Binding(get: { isLeastFirst }, set: { chosenOrder = $0 })) {
            Text("Least first").tag(true)
            Text("Most first").tag(false)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var rows: [(name: String, load: RecentLoad)] {
        model.squad
            .map { (name: $0, load: RecentLoad(player: $0, matches: model.matches)) }
            .sorted { lhs, rhs in
                if lhs.load.minutes == rhs.load.minutes { return lhs.name < rhs.name }
                return (lhs.load.minutes < rhs.load.minutes) == isLeastFirst
            }
    }
}

private struct TeamMinutesRow: View {
    let name: String
    let load: RecentLoad

    @ScaledMetric private var barHeight: CGFloat = 32
    @ScaledMetric private var barWidth: CGFloat = 8

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                TeamPlayerName(name: name)
                Text(load.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            HStack(spacing: 12) {
                bars
                Text(load.matchesPlayed == 0 ? "—" : "\(Int(load.minutes.rounded())) min")
                    .font(.figure(.body))
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(spoken)
    }

    /// One bar per match, oldest first, filled as far as they played; a dash where nothing was recorded.
    private var bars: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(load.shares.enumerated()), id: \.offset) { _, share in
                if let share, share > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(.systemFill))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.turf).frame(height: max(3, barHeight * share))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .frame(width: barWidth)
                } else {
                    Capsule().fill(.tertiary).frame(width: barWidth, height: 2)
                }
            }
        }
        .frame(height: barHeight, alignment: .bottom)
    }

    private var spoken: String {
        guard load.matchesPlayed > 0 else { return load.summary }
        let matches = load.perMatch.map { $0.map { "\(Int($0.rounded()))" } ?? "none" }.joined(separator: ", ")
        return "\(load.summary). \(Int(load.minutes.rounded())) minutes in total. Match by match, oldest first: \(matches)"
    }
}

// MARK: - Events

private struct TeamEventsPane: View {
    let model: TeamMatchesModel

    @Environment(EntitlementStore.self) private var entitlements
    @State private var isShowingPlan = false
    @State private var labeling: TeamEvent?
    @State private var draft = ""
    @State private var player: String?

    var body: some View {
        switch model.historyPhase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load events", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.loadHistory() } }
                    .buttonStyle(.prominentAction)
            }
        case .loaded where model.keyEvents.isEmpty:
            ContentUnavailableView("No events yet", systemImage: "flag",
                                   description: Text("Goals, cards and flags the team logs on Apple Watch appear here."))
        case .loaded:
            List {
                Group {
                    ForEach(days, id: \.day) { day in
                        Section(day.day.formatted(.dateTime.weekday(.wide).month().day())) {
                            ForEach(day.events) { event in
                                if entitlements.entitledToTeam {
                                    noteButton(event)
                                } else {
                                    row(event)
                                }
                            }
                        }
                    }
                    if !entitlements.entitledToTeam {
                        Section {
                            Button("Add Notes with MatchTracker Team") { isShowingPlan = true }
                        } footer: {
                            Text("Reading the team's moments and notes is free. Writing notes is a paid extra.")
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .contentMargins(.top, 8, for: .scrollContent)
            .readableFormWidth()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Player", selection: $player) {
                            Text("Everyone").tag(String?.none)
                            ForEach(model.squad, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    } label: {
                        Label(player ?? "Filter by player",
                              systemImage: player == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .refreshable { await model.loadHistory() }
            .sheet(isPresented: $isShowingPlan) { PaywallView(entitlements: entitlements) }
            .alert("Note", isPresented: Binding(get: { labeling != nil }, set: { if !$0 { labeling = nil } }),
                   presenting: labeling) { event in
                TextField("Great finish", text: $draft)
                Button("Save") { Task { await model.annotate(event, note: draft) } }
                Button("Cancel", role: .cancel) {}
            } message: { event in
                Text("\(model.sentence(event)). Your team sees this note.")
            }
            .alert("Couldn't save the note", isPresented: Binding(get: { model.noteProblem != nil }, set: { if !$0 { model.noteProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.noteProblem ?? "")
            }
        }
    }

    private var days: [(day: Date, events: [TeamEvent])] {
        let events = model.keyEvents.filter { player == nil || $0.playerName == player }
        return Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    private func noteButton(_ event: TeamEvent) -> some View {
        Button {
            draft = event.coachLabel ?? ""
            labeling = event
        } label: {
            row(event).contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityHint("Adds a note")
    }

    private func row(_ event: TeamEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: event.kind?.systemImage ?? "circle")
                .foregroundStyle(.secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sentence(event))
                if let note = event.note, !note.isEmpty {
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
                if let label = event.coachLabel, !label.isEmpty {
                    Text("Note: \(label)").font(.subheadline).foregroundStyle(Theme.turf)
                }
            }
            Spacer(minLength: 8)
            Text(event.date, format: .dateTime.hour().minute())
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model

@Observable
@MainActor
final class TeamMatchesModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var livePhase: Phase = .loading
    private(set) var historyPhase: Phase = .loading
    private(set) var players: [LivePlayerStatus] = []
    /// Newest first.
    private(set) var matches: [TeamMatchMinutes] = []
    private(set) var keyEvents: [TeamEvent] = []
    private(set) var squad: [String] = []
    var noteProblem: String?

    private var events: [UUID: TeamEvent] = [:]
    let teamCode: String
    private static let historyHours = 8 * 7 * 24
    private static let keyKinds: Set<MatchEventKind> = [.goalForUs, .goalAgainstUs, .goalMine, .assist, .flag, .yellowCard, .redCard]

    init(teamCode: String) {
        self.teamCode = teamCode
    }

    func loadHistory() async {
        do {
            async let history = TeamService.events(code: teamCode, sinceHours: Self.historyHours)
            async let stats = TeamService.stats(code: teamCode, since: TeamModel.seasonStart)
            let (newEvents, newStats) = try await (history, stats)
            events = Dictionary(newEvents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            squad = Set(newStats.players.map(\.name) + newEvents.map(\.playerName)).sorted()
            summarizeEvents()
            historyPhase = .loaded
        } catch {
            if historyPhase != .loaded && !Task.isCancelled { historyPhase = .failed(TeamService.explain(error)) }
        }
    }

    /// Keeps up with the match while the page is open.
    func follow(_ liveMatches: LiveMatchStore) async {
        while !Task.isCancelled {
            await refreshLive()
            mergeOwnMatch(liveMatches)
            if !players.isEmpty, let recent = try? await TeamService.events(code: teamCode, sinceHours: 6) {
                events.merge(recent.map { ($0.id, $0) }) { $1 }
                summarizeEvents()
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    func refreshLive() async {
        do {
            players = try await TeamService.livePlayers(code: teamCode).sorted { $0.playerName < $1.playerName }
            livePhase = .loaded
        } catch {
            if livePhase != .loaded && !Task.isCancelled { livePhase = .failed(TeamService.explain(error)) }
        }
    }

    /// This phone's own watch is fresher than the trip through the server.
    private func mergeOwnMatch(_ liveMatches: LiveMatchStore) {
        // Only the team this match is shared with: the other one isn't watching it.
        guard liveMatches.isLive, let update = liveMatches.latest, SettingsStore.shared.teamCode == teamCode else { return }
        let name = SettingsStore.shared.playerName.isEmpty ? "You" : SettingsStore.shared.playerName
        let known = players.first { $0.playerName == name }
        players.removeAll { $0.playerName == name }
        players.append(LivePlayerStatus(playerName: name, updatedAt: update.timestamp, x: known?.x, y: known?.y,
                                        distanceMeters: update.distanceMeters,
                                        onPitch: update.onPitch, stale: false))
        players.sort { $0.playerName < $1.playerName }
    }

    private func summarizeEvents() {
        matches = TeamMinutes.matches(from: Array(events.values))
        keyEvents = events.values.filter { $0.kind.map(Self.keyKinds.contains) ?? false }
    }

    func annotate(_ event: TeamEvent, note: String) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = events[event.id]?.coachLabel
        events[event.id]?.coachLabel = trimmed.isEmpty ? nil : trimmed
        summarizeEvents()
        do {
            try await TeamService.annotate(event, note: trimmed)
        } catch {
            events[event.id]?.coachLabel = previous
            summarizeEvents()
            noteProblem = TeamService.explainNote(error)
        }
    }

    /// The event as a sentence about the player who logged it.
    func sentence(_ event: TeamEvent) -> String {
        switch event.kind {
        case .goalMine: return "\(event.playerName) scored"
        case .assist: return "Assist by \(event.playerName)"
        case .goalForUs: return "Goal for us"
        case .goalAgainstUs: return "Goal against us"
        case .yellowCard: return "Yellow card, \(event.playerName)"
        case .redCard: return "Red card, \(event.playerName)"
        case .flag: return "\(event.playerName) marked a moment"
        default: return event.playerName
        }
    }
}
