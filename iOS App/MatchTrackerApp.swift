// MatchTrackerApp.swift
// MatchTracker

import SwiftUI
import BackgroundTasks

@main
struct MatchTrackerApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.registerBackgroundRefresh()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.fields)
                .environmentObject(environment.matches)
                .environmentObject(environment.uploads)
                .environment(environment.liveMatches)
                .environment(environment.entitlements)
                .environment(environment.trainingLoad)
                .environment(environment.seeder)
                .environment(environment.backlogImporter)
                .task { await environment.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await AppEnvironment.current?.reconcile() }
                }
        }
    }

    static let backgroundRefreshIdentifier = "com.nicemohawk.MatchTracker.refresh"

    /// Registration must happen before launch finishes; the handler reconciles matches (in case
    /// a watch transfer was dropped) and flushes queued uploads.
    private static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshIdentifier,
                                        using: nil) { task in
            scheduleBackgroundRefresh()
            Task { @MainActor in
                await AppEnvironment.current?.reconcile()
                task.setTaskCompleted(success: true)
            }
        }
        scheduleBackgroundRefresh()
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Owns and wires together the app's stores/services and the watch connectivity bridge.
@MainActor
final class AppEnvironment: ObservableObject {
    /// The single instance, reachable from background-task handlers that have no view context.
    static private(set) var current: AppEnvironment?

    let settings = SettingsStore.shared
    let fields: FieldsModel
    let matches: MatchStore
    let uploads: UploadService
    let connectivity: ConnectivityManager
    let liveMatches = LiveMatchStore()
    let entitlements = EntitlementStore()
    let trainingLoad = TrainingLoadService()
    let seeder: NearbyFieldSeeder
    let backlogImporter: BacklogImporter

    init() {
        let fields = FieldsModel()
        let matches = MatchStore(fields: fields)
        let uploads = UploadService(settings: settings, fields: fields, matches: matches)
        let connectivity = ConnectivityManager(fields: fields, settings: settings)

        self.fields = fields
        self.matches = matches
        self.uploads = uploads
        self.connectivity = connectivity
        self.seeder = NearbyFieldSeeder(fields: fields, uploads: uploads, settings: settings)
        self.backlogImporter = BacklogImporter(matches: matches, fields: fields)

        fields.onFieldsChanged = { [weak connectivity, weak uploads] in
            connectivity?.pushContext()
            Task { await uploads?.uploadFields() }
        }
        matches.onNewMatches = { [weak uploads] summaries in
            uploads?.autoUpload(summaries)
        }
        connectivity.onMatchRecordReceived = { [weak matches] _ in
            Task { await matches?.refresh() }
        }
        connectivity.onFieldReceived = { [weak fields] in
            fields?.reload()
        }
        connectivity.onLiveUpdate = { [weak self] update in
            guard let self else { return }
            liveMatches.ingest(update)
            uploads.relayLive(update)
        }
        AppEnvironment.current = self
    }

    func bootstrap() async {
        connectivity.start()
        await uploads.bootstrapAPIKey()
        await matches.refresh()
        await uploads.flushQueue()
        await trainingLoad.refresh()
        // Workrate average is computed live where it's rendered (WorkrateSection) — the detail
        // cache is still empty at launch, so a snapshot here would always be a stale nil.
    }

    /// Foreground / background-refresh reconciliation: matches vs HealthKit + queued uploads.
    func reconcile() async {
        await matches.refresh()
        await uploads.flushQueue()
    }

    /// Re-push settings-derived context to the watch (team/player changes).
    func settingsChanged() {
        connectivity.pushContext()
    }
}

struct RootTabView: View {
    @Environment(LiveMatchStore.self) private var liveMatches
    @State private var selectedTab = "matches"

    var body: some View {
        // On iOS 26 the tab bar minimizes on scroll, the live match rides in a Liquid Glass
        // bottom accessory (Apple Music's now-playing pattern), and Settings is the system's
        // detached circle beside the bar via `role: .search` — visually part of the tab bar,
        // but its own button. Pre-26 falls back to a plain fourth tab.
        if #available(iOS 26.0, *) {
            modernTabView
                .tabBarMinimizeBehavior(.onScrollDown)
                .modifier(LiveAccessoryPresenter(isLive: liveMatches.isLive))
        } else {
            legacyTabView
        }
    }

    @available(iOS 26.0, *)
    private var modernTabView: some View {
        TabView(selection: $selectedTab) {
            Tab("Matches", systemImage: "figure.soccer", value: "matches") {
                MatchesView()
            }
            Tab("Fields", systemImage: "map", value: "fields") {
                FieldsView()
            }
            Tab("Team", systemImage: "person.3", value: "team") {
                TeamView()
            }
            // The search role renders as the separated glass circle at the bar's trailing edge.
            Tab("Settings", systemImage: "gearshape", value: "settings", role: .search) {
                SettingsView()
            }
        }
        .tint(Theme.turf)
    }

    private var legacyTabView: some View {
        TabView(selection: $selectedTab) {
            MatchesView()
                .tabItem { Label("Matches", systemImage: "figure.soccer") }
                .tag("matches")
            FieldsView()
                .tabItem { Label("Fields", systemImage: "map") }
                .tag("fields")
            TeamView()
                .tabItem { Label("Team", systemImage: "person.3") }
                .tag("team")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .tint(Theme.turf)
    }
}

/// Mounts the `tabViewBottomAccessory` (the live "now playing") ONLY while a match is live.
/// Applying the modifier conditionally — rather than returning empty content inside its builder —
/// guarantees no empty Liquid Glass pill is ever reserved above the tab bar when idle.
@available(iOS 26.0, *)
private struct LiveAccessoryPresenter: ViewModifier {
    let isLive: Bool

    func body(content: Content) -> some View {
        if isLive {
            content.tabViewBottomAccessory {
                LiveMatchAccessory()
            }
        } else {
            content
        }
    }
}
