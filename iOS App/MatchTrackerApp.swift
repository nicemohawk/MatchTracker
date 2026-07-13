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

    init() {
        let fields = FieldsModel()
        let matches = MatchStore(fields: fields)
        let uploads = UploadService(settings: settings, fields: fields, matches: matches)
        let connectivity = ConnectivityManager(fields: fields, settings: settings)

        self.fields = fields
        self.matches = matches
        self.uploads = uploads
        self.connectivity = connectivity

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
        trainingLoad.setAverageWorkrate(matches.recentAverageWorkrate(days: 28))
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
    var body: some View {
        TabView {
            MatchesView()
                .tabItem { Label("Matches", systemImage: "figure.soccer") }
            FieldsView()
                .tabItem { Label("Fields", systemImage: "map") }
            TeamView()
                .tabItem { Label("Team", systemImage: "person.3") }
        }
    }
}
