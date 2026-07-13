// MatchTrackerApp.swift
// MatchTracker

import SwiftUI

@main
struct MatchTrackerApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.fields)
                .environmentObject(environment.matches)
                .environmentObject(environment.uploads)
                .task { await environment.bootstrap() }
        }
    }
}

/// Owns and wires together the app's stores/services and the watch connectivity bridge.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings = SettingsStore.shared
    let fields: FieldsModel
    let matches: MatchStore
    let uploads: UploadService
    let connectivity: ConnectivityManager

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
    }

    func bootstrap() async {
        connectivity.start()
        await uploads.bootstrapAPIKey()
        await matches.refresh()
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
