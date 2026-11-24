// TeamDebugGallery.swift
// MatchTracker

#if DEBUG
import EventKit
import SwiftUI
import MatchTrackerKit

/// Team screens on their own for screenshots: `-TeamScreen home|squad|player|formation|matches|whosin|compare|fixtures|next|join|invited|create|ready|manage|privacy`,
/// with `-TeamStub` for the data, `-SeedFixtures YES` to put matches in a calendar, `-NoTeam YES`,
/// `-Captain somebody`, `-Coach YES`, `-TwoTeams YES`, `-NoTeamName YES` for a code typed by hand,
/// `-TeamPane Live|Minutes|Events`.
struct TeamDebugGallery: View {
    static let screen = UserDefaults.standard.string(forKey: "TeamScreen")

    @EnvironmentObject private var settings: SettingsStore
    @State private var team = TeamModel()
    @State private var isShowingSheet = true

    var body: some View {
        TabView {
            content.tabItem { Label("Team", systemImage: "person.3") }
        }
        .tint(Theme.turf)
        .task { await prepare() }
    }

    @ViewBuilder private var content: some View {
        switch Self.screen {
        case "squad": stack { TeamSquadView(team: team, code: "K7QM2P") }
        case "player": stack { TeamPlayerView(name: "Maya Ortiz", team: team, code: "K7QM2P") }
        case "formation": stack { FormationView(teamCode: "K7QM2P") }
        case "matches": stack { TeamMatchesView(teamCode: "K7QM2P") }
        case "whosin": stack { TeamWhosInView(teamCode: "K7QM2P", sharedName: "Red Dragons") }
        case "privacy": stack { TeamPrivacyView() }
        case "ready": stack { TeamReadyView(invite: TeamInvite(code: "K7QM2P", name: "Red Dragons", captain: "Ben Lachman")) {} }
        case "invited": TeamView().sheet(isPresented: $isShowingSheet) {
            TeamJoinSheet(invite: TeamInvite(code: "K7QM2P", name: "Red Dragons", captain: "Maya Ortiz"))
        }
        case "compare": stack { CohortBenchmarkView() }
        case "fixtures": stack { FixturesListView() }
        case "next": stack { List { NextMatchCard() }.navigationTitle("Summary") }
        case "join": TeamView().sheet(isPresented: $isShowingSheet) { TeamJoinSheet() }
        case "create": TeamView().sheet(isPresented: $isShowingSheet) { TeamCreateSheet() }
        case "manage": TeamView().sheet(isPresented: $isShowingSheet) { TeamManageSheet(sharedName: "Red Dragons") }
        default: TeamView()
        }
    }

    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack { content() }
    }

    private func prepare() async {
        let arguments = UserDefaults.standard
        settings.playerName = "Ben Lachman"
        settings.teamMemberships = []
        TeamPlan.remove("K7QM2P")
        FormationBoard.remove("K7QM2P")
        TeamStub.current?.prepareCache(code: "K7QM2P")
        if !arguments.bool(forKey: "NoTeam") {
            let name = arguments.bool(forKey: "NoTeamName") ? nil : "Red Dragons"
            settings.enterTeam(TeamInvite(code: "K7QM2P", name: name, captain: arguments.string(forKey: "Captain")))
            if arguments.bool(forKey: "Coach") { settings.updateTeam("K7QM2P") { $0.isCoach = true } }
            if arguments.bool(forKey: "TwoTeams") {
                settings.enterTeam(TeamInvite(code: "R0VERS", name: "Tuesday Rovers"))
                settings.viewedTeam = "K7QM2P"
            }
        }
        await team.load(code: "K7QM2P")
        if UserDefaults.standard.bool(forKey: "SeedFixtures") { await seedFixtures() }
    }

    private func seedFixtures() async {
        let fixtures = FixtureStore.shared
        await fixtures.requestAccess()
        let store = fixtures.eventStore
        guard fixtures.access == .granted, let source = store.defaultCalendarForNewEvents?.source else { return }
        let calendar = store.calendars(for: .event).first { $0.title == "TeamSnap" } ?? {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = "TeamSnap"
            calendar.source = source
            try? store.saveCalendar(calendar, commit: true)
            for (day, title, place) in [(3.0, "Red Dragons vs. Rovers FC", "Demo Park, Field 2"), (6, "Practice", "Demo Park"),
                                        (10, "Albion at Red Dragons", "Riverside Sports Complex"), (17, "League game", "")] {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = title
                event.startDate = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date().addingTimeInterval(day * 86_400))
                event.endDate = event.startDate.addingTimeInterval(5_400)
                if day == 3 {
                    let location = EKStructuredLocation(title: place)
                    location.geoLocation = CLLocation(latitude: 39.325, longitude: -82.101)
                    event.structuredLocation = location
                } else if !place.isEmpty {
                    event.location = place
                }
                try? store.save(event, span: .thisEvent)
            }
            return calendar
        }()
        await fixtures.choose([calendar])
    }
}
#endif
