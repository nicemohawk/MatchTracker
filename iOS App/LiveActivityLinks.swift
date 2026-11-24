// LiveActivityLinks.swift
// MatchTracker

import CoreSpotlight
import SwiftUI
import MatchTrackerKit

extension View {
    /// Everything that can open the app to somewhere — widgets, the Live Activity, controls,
    /// shortcuts, Spotlight — and the live sheet they and the accessory share. Goes on the root view,
    /// which nothing rebuilds mid-match.
    ///
    /// - Parameters:
    ///   - openMatch: navigate to a match. Without it the match opens in a sheet.
    ///   - openSeason: show the season.
    ///   - openTeam: show the team.
    func systemLinks(showingLive: Binding<Bool>, openMatch: ((UUID) -> Void)? = nil,
                     openSeason: @escaping () -> Void = {}, openTeam: @escaping () -> Void = {}) -> some View {
        modifier(SystemLinks(showingLive: showingLive, openMatch: openMatch, openSeason: openSeason, openTeam: openTeam))
    }
}

private struct SystemLinks: ViewModifier {
    @Binding var showingLive: Bool
    let openMatch: ((UUID) -> Void)?
    let openSeason: () -> Void
    let openTeam: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var matches: MatchStore
    @Environment(LiveMatchStore.self) private var liveMatches
    @State private var router = LinkRouter.shared
    @State private var sheetMatch: MatchSummary?
    @State private var reviewing: ReviewedMatch?
    @State private var invite: TeamInvite?
    // An invite opened by somebody new waits until they've been shown around.
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var startOnWatch = StartOnWatch()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingLive) {
                NavigationStack {
                    LiveMatchView(store: liveMatches, showsClose: true)
                }
            }
            .sheet(item: $sheetMatch) { summary in
                NavigationStack {
                    MatchDetailView(summary: summary)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { sheetMatch = nil }
                            }
                        }
                }
            }
            .sheet(item: $reviewing) { ScoreSheet(detail: $0.detail, isAsking: true) }
            .sheet(item: $invite) { TeamJoinSheet(invite: $0) }
            .startOnWatchAlert(startOnWatch)
            .onOpenURL { url in
                router.pending = MatchTrackerLink(url)
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                      let id = UUID(uuidString: identifier) else { return }
                router.pending = .match(id)
            }
            .onChange(of: router.pending, initial: true) { follow() }
            // A match just played may still be on its way from the watch.
            .onChange(of: matches.contentVersion) { follow() }
            .onChange(of: hasOnboarded) { follow() }
            .task(id: ReviewMoment(isActive: scenePhase == .active, match: matches.awaitingReview?.id)) { await askIfJustPlayed() }
            #if DEBUG
            .fullScreenCover(isPresented: .constant(SurfaceGallery.page != nil)) { SurfaceGallery() }
            .fullScreenCover(isPresented: .constant(TeamDebugGallery.screen != nil)) { TeamDebugGallery() }
            .task {
                DemoLiveMatch.runIfRequested()
                // `-OpenLink matchtracker://live`: that scheme isn't registered, so nothing outside can.
                if let link = UserDefaults.standard.string(forKey: "OpenLink").flatMap(URL.init(string:)) {
                    try? await Task.sleep(for: .seconds(2))
                    router.pending = MatchTrackerLink(link)
                }
            }
            #endif
    }

    private func follow() {
        guard let link = router.pending else { return }
        switch link {
        case .live: showingLive = true
        case .season: openSeason()
        case .start: startOnWatch.start()
        case .join(let joining):
            guard hasOnboarded else { return }
            showingLive = false
            openTeam()
            if settings.teamMemberships.contains(where: { $0.code == joining.code }) {
                settings.viewedTeam = joining.code
            } else {
                invite = joining
            }
        case .latestMatch, .match, .matchStarting:
            guard let summary = summary(for: link) else { return forget(link) }
            showingLive = false
            if let openMatch { openMatch(summary.id) } else { sheetMatch = summary }
        case .review:
            guard let summary = summary(for: link) else { return forget(link) }
            showingLive = false
            Task { await review(summary) }
        }
        router.pending = nil
    }

    /// Waits for the list, then for the watch; past a minute, going there would be a surprise.
    private func forget(_ link: MatchTrackerLink) {
        Task {
            try? await Task.sleep(for: .seconds(60))
            if router.pending == link { router.pending = nil }
        }
    }

    /// The match somebody has just walked off from, asked about once, when nothing else is going on.
    private func askIfJustPlayed() async {
        guard scenePhase == .active, let summary = matches.awaitingReview else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled, !liveMatches.isLive, !showingLive, reviewing == nil, router.pending == nil,
              UserDefaults.standard.bool(forKey: "hasOnboarded"),
              MatchReminders.shared.shouldAsk(about: summary.id, summary.record) else { return }
        await review(summary)
    }

    private func review(_ summary: MatchSummary) async {
        let detail = matches.detailModel(for: summary)
        await detail.load()
        reviewing = ReviewedMatch(detail: detail)
    }

    private func summary(for link: MatchTrackerLink) -> MatchSummary? {
        switch link {
        case .latestMatch: return matches.matches.first
        case .match(let id): return matches.matches.first { $0.id == id }
        case .matchStarting(let date), .review(startingAt: let date):
            func distance(_ summary: MatchSummary) -> TimeInterval { abs(summary.startDate.timeIntervalSince(date)) }
            return matches.matches.min { distance($0) < distance($1) }.flatMap { distance($0) < 15 * 60 ? $0 : nil }
        default: return nil
        }
    }
}

private struct ReviewedMatch: Identifiable {
    let detail: MatchDetailModel
    var id: UUID { detail.matchIdentifier }
}

private struct ReviewMoment: Equatable {
    let isActive: Bool
    let match: UUID?
}
