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
    func systemLinks(showingLive: Binding<Bool>, openMatch: ((UUID) -> Void)? = nil,
                     openSeason: @escaping () -> Void = {}) -> some View {
        modifier(SystemLinks(showingLive: showingLive, openMatch: openMatch, openSeason: openSeason))
    }
}

private struct SystemLinks: ViewModifier {
    @Binding var showingLive: Bool
    let openMatch: ((UUID) -> Void)?
    let openSeason: () -> Void

    @EnvironmentObject private var matches: MatchStore
    @Environment(LiveMatchStore.self) private var liveMatches
    @State private var router = LinkRouter.shared
    @State private var sheetMatch: MatchSummary?
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
            #if DEBUG
            .fullScreenCover(isPresented: .constant(SurfaceGallery.page != nil)) { SurfaceGallery() }
            .task {
                DemoLiveMatch.runIfRequested()
                // `-OpenLink matchtracker://live`: the scheme isn't registered, so nothing outside can.
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
        case .latestMatch, .match, .matchStarting:
            guard let summary = summary(for: link) else {
                // Waits for the list, then for the watch; past a minute, going there would be a surprise.
                Task {
                    try? await Task.sleep(for: .seconds(60))
                    if router.pending == link { router.pending = nil }
                }
                return
            }
            showingLive = false
            if let openMatch { openMatch(summary.id) } else { sheetMatch = summary }
        }
        router.pending = nil
    }

    private func summary(for link: MatchTrackerLink) -> MatchSummary? {
        switch link {
        case .latestMatch: return matches.matches.first
        case .match(let id): return matches.matches.first { $0.id == id }
        case .matchStarting(let date):
            func distance(_ summary: MatchSummary) -> TimeInterval { abs(summary.startDate.timeIntervalSince(date)) }
            return matches.matches.min { distance($0) < distance($1) }.flatMap { distance($0) < 15 * 60 ? $0 : nil }
        default: return nil
        }
    }
}
