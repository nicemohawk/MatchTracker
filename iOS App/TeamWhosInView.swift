// TeamWhosInView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Who's in for the next match. Anyone can keep a list; sharing it is how the rest of the team sees it.
struct TeamWhosInView: View {
    let teamCode: String
    let sharedName: String?
    var fixtures: FixtureStore = .shared

    @EnvironmentObject private var settings: SettingsStore
    @State private var plan: TeamPlan
    @State private var squad: [String] = []
    @State private var problem: String?
    @State private var newName = ""

    init(teamCode: String, sharedName: String?) {
        self.teamCode = teamCode
        self.sharedName = sharedName
        _plan = State(initialValue: TeamPlan(teamCode: teamCode))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.playing.isEmpty ? "Nobody picked yet" : "\(plan.picked(from: names).count) in")
                        .font(.title2.bold())
                        .contentTransition(.numericText())
                    Text(matchLine ?? "For your next match").foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden, edges: .bottom)
                ForEach(names, id: \.self) { name in
                    row(name)
                }
                TextField("Add a player by name", text: $newName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addPlayer)
            } footer: {
                Text("Kept on this device. Nobody sees it, or the names you add, until you share it.")
            }
            if let problem {
                Section {} footer: { Text("Couldn't refresh the squad. \(problem)") }
            }
        }
        .readableFormWidth()
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Who's In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !plan.playing.isEmpty {
                    Button("Clear", systemImage: "arrow.counterclockwise") { withAnimation { plan.clear() } }
                    ShareLink(item: shareText)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: plan.playing)
        .task {
            await fixtures.refresh()
            plan.start(fixtureID: fixtures.next?.id)
            await loadSquad()
        }
    }

    private var names: [String] { plan.squad(squad) }

    private func row(_ name: String) -> some View {
        let isIn = plan.playing.contains(name)
        return Button { plan.toggle(name) } label: {
            HStack {
                TeamPlayerName(name: name)
                Spacer()
                Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isIn ? AnyShapeStyle(Theme.turf) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityAddTraits(isIn ? .isSelected : [])
        .swipeActions {
            if plan.guests.contains(name) {
                Button("Remove", role: .destructive) { plan.remove(guest: name) }
            }
        }
    }

    private var matchLine: String? {
        fixtures.next.map { "\($0.displayTitle), \($0.start.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))" }
    }

    private var shareText: String {
        let picked = plan.picked(from: names)
        return ([settings.teamName(teamCode, sharedName: sharedName), matchLine].compactMap { $0 }
            + ["In (\(picked.count)): \(picked.formatted())"]).joined(separator: "\n")
    }

    private func addPlayer() {
        if let added = plan.add(guest: newName), !plan.playing.contains(added) { plan.toggle(added) }
        newName = ""
    }

    private func loadSquad() async {
        squad = TeamCache.load(teamCode)?.season.players.map(\.name) ?? []
        do {
            squad = try await TeamService.stats(code: teamCode, since: TeamModel.seasonStart).players.map(\.name)
            problem = nil
        } catch {
            if !Task.isCancelled { problem = TeamService.explain(error) }
        }
    }
}

// MARK: - Plan

/// Names this device's owner has added to a team's squad, and who they've picked. Never uploaded.
@Observable
@MainActor
final class TeamPlan {
    private struct Saved: Codable {
        var guests: [String] = []
        var playing: Set<String> = []
        var fixtureID: String?
    }

    private let teamCode: String
    private var saved: Saved {
        didSet { AppGroup.defaults.set(try? JSONEncoder().encode(saved), forKey: Self.storageKey(teamCode)) }
    }

    init(teamCode: String) {
        self.teamCode = teamCode
        saved = AppGroup.defaults.data(forKey: Self.storageKey(teamCode))
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    private static func storageKey(_ code: String) -> String { "whosIn.\(code)" }

    static func remove(_ code: String) { AppGroup.defaults.removeObject(forKey: storageKey(code)) }

    var guests: [String] { saved.guests }
    var playing: Set<String> { saved.playing }

    /// Everyone there is to pick from: who has shared matches, who was added here, and you.
    func squad(_ sharing: [String]) -> [String] {
        let settings = SettingsStore.shared
        let known = sharing + saved.guests
        let me = settings.playerName.isEmpty || known.contains(where: settings.isMe) ? [] : [settings.playerName]
        return Set(known + me).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Who's in, or everybody when nobody has been picked.
    func picked(from squad: [String]) -> [String] {
        let picked = squad.filter(saved.playing.contains)
        return picked.isEmpty ? squad : picked
    }

    /// A new match starts with nobody picked.
    func start(fixtureID: String?) {
        guard let fixtureID, fixtureID != saved.fixtureID else { return }
        if saved.fixtureID != nil { saved.playing = [] }
        saved.fixtureID = fixtureID
    }

    func toggle(_ name: String) {
        if saved.playing.remove(name) == nil { saved.playing.insert(name) }
    }

    func clear() { saved.playing = [] }

    /// The name as added, or nil if there was nothing to add.
    func add(guest name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !saved.guests.contains(trimmed) { saved.guests.append(trimmed) }
        return trimmed
    }

    func remove(guest name: String) {
        saved.guests.removeAll { $0 == name }
        saved.playing.remove(name)
    }
}
