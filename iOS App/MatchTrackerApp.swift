// MatchTrackerApp.swift
// MatchTracker

import SwiftUI
import BackgroundTasks
import MatchTrackerKit

@main
struct MatchTrackerApp: App {
    @StateObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.registerBackgroundRefresh()
        LiveActivityController.shared.observeMirroredMatches()
        MatchReminders.shared.start()
        BarType.apply()
        // Not left to the first window: the watch wakes the app in the background, without one.
        let environment = AppEnvironment()
        environment.connectivity.start()
        _environment = StateObject(wrappedValue: environment)
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
                .environment(environment.seeder)
                .environment(environment.backlogImporter)
                .task { await environment.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LiveActivityController.shared.appBecameActive()
                        Task { await AppEnvironment.current?.reconcile() }
                    case .background:
                        // Debounced cache writes flush now, before a possible process kill.
                        AppEnvironment.current?.matches.flushPendingPersists()
                    default:
                        break
                    }
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
    let seeder: NearbyFieldSeeder
    let backlogImporter: BacklogImporter

    init() {
        // Persistent lifecycle journal (this device's half; the watch ships its own after each
        // match) — both ride along in diagnostic exports so sessions can be reconstructed.
        MatchLog.enableJournal(
            at: AppGroup.containerURL.appendingPathComponent("journal-phone.jsonl"),
            deviceTag: "phone")
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

        fields.onFieldsChanged = { [weak connectivity, weak uploads, weak matches] in
            connectivity?.pushContext()
            // A field's geometry may have changed (corner edit) — reproject every match that resolves
            // to it. One mechanism for both the Fields tab's own corner
            // editor and a match's Adjust Field flow, since both save through `FieldsModel`.
            matches?.invalidateForFieldChange()
            Task { await uploads?.uploadFields() }
        }
        matches.onNewMatches = { [weak uploads] summaries in
            uploads?.autoUpload(summaries)
        }
        connectivity.onMatchRecordReceived = { [weak matches] record in
            LiveActivityController.shared.matchFinished(record)
            MatchReminders.shared.matchArrived(record)
            Task { await matches?.refresh() }
        }
        connectivity.onFieldReceived = { [weak fields] in
            fields?.reload()
        }
        connectivity.onLiveUpdate = { [weak self] update in
            guard let self else { return }
            liveMatches.ingest(update)
            LiveActivityController.shared.show(liveMatches.state)
            uploads.relayLive(update)
        }
        AppEnvironment.current = self
    }

    func bootstrap() async {
        await uploads.bootstrapAPIKey()
#if DEBUG
        // Headless diagnostic import: `-ImportDiagnostics YES` loads Documents/diagnostics-import.
        // matchtrackerdiag into HealthKit + the app group before the first match refresh.
        await DiagnosticArchiveImport.runHeadlessIfRequested(healthKit: matches.healthKit) { [weak self] in
            await self?.fields.reload()
        }
#endif
        await matches.refresh()
#if DEBUG
        // Headless diagnostic export: `-ExportDiagnostics YES` writes the full history to
        // Documents/diagnostics-export.matchtrackerdiag after the first refresh has the match list.
        await DiagnosticArchive.runHeadlessExportIfRequested(
            summaries: matches.matches, fields: fields.fields,
            settings: .current(contributeDetectedFields: settings.contributeDetectedFields),
            healthKit: matches.healthKit
        )
#endif
        await uploads.flushQueue()
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
    @State private var selectedTab = AppTab.summary
    @State private var showingLive = false
    @State private var openedMatch: UUID?
    // First-run onboarding gate. Written once the cover finishes; existing installs (and the UI
    // tests that walk them) skip the cover entirely.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    private enum AppTab: Hashable { case summary, matches, team, search }

    var body: some View {
        tabs
            .systemLinks(showingLive: $showingLive,
                         openMatch: { id in
                             selectedTab = .summary
                             openedMatch = id
                         },
                         openSeason: { selectedTab = .summary },
                         openTeam: { selectedTab = .team })
            .fullScreenCover(isPresented: .init(get: { !hasOnboarded },
                                                set: { if $0 { hasOnboarded = false } })) {
                OnboardingView()
            }
            .tint(Theme.turf)
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Summary", systemImage: "soccerball", value: AppTab.summary) { HomeView(openedMatch: $openedMatch) }
                Tab("Matches", systemImage: "list.bullet", value: AppTab.matches) { MatchesView() }
                Tab("Team", systemImage: "person.3.fill", value: AppTab.team) { TeamView() }
                Tab(value: AppTab.search, role: .search) { MatchesView(isSearchTab: true) }
            }
            .modifier(LiveAccessoryPresenter(isLive: liveMatches.isLive, showingLive: $showingLive))
        } else {
            TabView(selection: $selectedTab) {
                HomeView(openedMatch: $openedMatch).tabItem { Label("Summary", systemImage: "soccerball") }.tag(AppTab.summary)
                MatchesView().tabItem { Label("Matches", systemImage: "list.bullet") }.tag(AppTab.matches)
                TeamView().tabItem { Label("Team", systemImage: "person.3.fill") }.tag(AppTab.team)
            }
        }
    }
}

/// Mounts the live match above the tab bar, and only while there is one: an empty accessory would
/// reserve an empty bar. One branch per system, whatever is live, or the tabs would start over
/// (sheets, drafts and all) each time a match began or went quiet.
private struct LiveAccessoryPresenter: ViewModifier {
    let isLive: Bool
    @Binding var showingLive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: isLive) { LiveMatchAccessory(isPresented: $showingLive) }
        } else if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
