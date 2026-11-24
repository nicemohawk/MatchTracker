// SettingsView.swift
// MatchTracker

import CoreLocation
import StoreKit
import SwiftUI
import MatchTrackerKit

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var uploads: UploadService
    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var fields: FieldsModel
    @Environment(BacklogImporter.self) private var backlogImporter
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isPresented) private var isPresented

    @State private var playerName = ""
    @FocusState private var isNameFocused: Bool

    @State private var showingFields = false
    @State private var showingImport = false
    @State private var showingPaywall = false
    @State private var showingConsentSheet = false
    @State private var showingDeletionConfirmation = false
    @State private var managingSubscription = false
    @State private var privacyMessage: String?
    /// Build the watch last reported over WatchConnectivity; empty until it does.
    @AppStorage(AppGroup.DefaultsKey.watchVersion, store: AppGroup.defaults) private var watchVersion = ""
#if DEBUG
    @State private var serverOverride = ""
    @State private var isGeneratingDemo = false
    @State private var demoMessage: String?
#endif

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                unitsSection
                afterMatchSection
                fieldsSection
                permissionsSection
                dataSection
                privacySection
                aboutSection
#if DEBUG
                developerSection
#endif
            }
            .readableFormWidth()
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear {
                playerName = settings.playerName
#if DEBUG
                serverOverride = settings.serverURLOverride
#endif
            }
            // Committed when you finish, not per keystroke: the watch and the server would otherwise
            // see half-typed names.
            .onChange(of: isNameFocused) { commitProfile() }
            .onDisappear { commitProfile() }
            .task { await backlogImporter.scanIfNeeded() }
            .sheet(isPresented: $showingImport) { BacklogImportView() }
            .sheet(isPresented: $showingPaywall) { PaywallView(entitlements: entitlements) }
            .sheet(isPresented: $showingConsentSheet) {
                GuardianConsentSheet { guardianName in
                    Task { await recordConsent(guardianName: guardianName) }
                }
            }
            .tint(Theme.turf)
            .fullScreenCover(isPresented: $showingFields) {
                NavigationStack {
                    FieldsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close", systemImage: "xmark") { showingFields = false }
                                    .tint(.primary)
                            }
                        }
                }
            }
        }
        // The rest of the app changes once it can be seen, rather than from under this sheet.
        .onDisappear { settings.dressEverything() }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Player name", text: $playerName)
                    .textInputAutocapitalization(.words)
                    .textContentType(.name)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .submitLabel(.done)
                    .focused($isNameFocused)
            }
            NavigationLink { KitPickerView() } label: {
                LabeledContent("Team Color", value: KitColors.title(of: settings.kitID))
            }
            if entitlements.entitledToTeam {
                Button("Manage Subscription") { managingSubscription = true }
                    .manageSubscriptionsSheet(isPresented: $managingSubscription)
            } else {
                DisclosureRow(title: "MatchTracker Team", value: "Not subscribed") { showingPaywall = true }
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Teammates see exactly this name. Your teams are in the Team tab.")
        }
    }

    private func commitProfile() {
        let name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != settings.playerName else { return }
        settings.rename(player: name)
        environment.settingsChanged()
    }

    // MARK: After a match

    private var afterMatchSection: some View {
        Section {
            Toggle("Ask how matches end", isOn: .init(get: { settings.asksAfterMatches }, set: { asks in
                settings.asksAfterMatches = asks
                if asks { Task { _ = await MatchReminders.shared.askToRemind() } }
            }))
        } footer: {
            Text("A reminder to check the goals you logged, or add the score, once a match reaches this iPhone.")
        }
    }

    // MARK: Units

    private var unitsSection: some View {
        Section {
            Picker("Units", selection: .init(get: { settings.units }, set: { units in
                settings.units = units
                environment.settingsChanged()
                SystemSurfaces.publish(digests: matches.playedDigests)
            })) {
                Text("Automatic").tag(UnitsPreference.automatic)
                Text("Miles and yards").tag(UnitsPreference.imperial)
                Text("Kilometers and meters").tag(UnitsPreference.metric)
            }
        } footer: {
            if settings.units == .automatic {
                Text(UnitSystem.preferred() == .metric
                     ? "Your region uses kilometers and meters." : "Your region uses miles and yards.")
            }
        }
    }

    // MARK: Fields

    private var fieldsSection: some View {
        Section {
            DisclosureRow(title: "Fields", value: fields.fields.isEmpty ? "None" : fields.fields.count.formatted()) {
                showingFields = true
            }
            NavigationLink("Fixtures") { FixturesListView() }
        } footer: {
            Text("Where you play. MatchTracker lines your heat map up with the field’s outline.")
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section("Health and permissions") {
            NavigationLink("Health") { HealthAccessView() }
            LocationAccessRow()
            LabeledContent("Apple Watch", value: watchStatus)
        }
    }

    private var watchStatus: String {
        switch environment.connectivity.isWatchAppInstalled {
        case true?: return "Ready"
        case false?: return "App not installed"
        case nil: return "Not connected"
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section("Data") {
            DisclosureRow(title: "Import history",
                          value: backlogImporter.pendingCount > 0 ? backlogImporter.pendingCount.formatted() : nil) {
                showingImport = true
            }
            if !matches.matches.isEmpty {
                ShareLink("Export Matches",
                          item: MatchHistoryExport(matches: matches.matches, digests: matches.digests,
                                                   fieldNames: fieldNames),
                          preview: SharePreview("MatchTracker matches"))
                    .labelStyle(.titleOnly)
            }
            if uploads.pendingUploadCount > 0 {
                LabeledContent {
                    Button("Try Again") { Task { await uploads.flushQueue() } }
                        .buttonStyle(.borderless)
                } label: {
                    Text(uploads.pendingUploadCount == 1 ? "1 upload is waiting"
                         : "\(uploads.pendingUploadCount) uploads are waiting")
                }
            }
        }
    }

    private var fieldNames: [UUID: String] {
        Dictionary(fields.fields.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle("Share fields", isOn: .init(get: { settings.contributeDetectedFields },
                                                        set: { settings.contributeDetectedFields = $0 }))
            if let acknowledgedAt = settings.consentAcknowledgedAt {
                LabeledContent("Guardian consent",
                               value: acknowledgedAt.formatted(date: .abbreviated, time: .omitted))
            } else {
                Button("Record Guardian Consent") { showingConsentSheet = true }
            }
            if let privacyPolicy = LegalLinks.privacyPolicy {
                Link("Privacy Policy", destination: privacyPolicy)
            }
            Button("Delete My Server Data", role: .destructive) { showingDeletionConfirmation = true }
                .confirmationDialog("Delete everything this iPhone has uploaded?",
                                    isPresented: $showingDeletionConfirmation, titleVisibility: .visible) {
                    Button("Delete Server Data", role: .destructive) { Task { await requestDeletion() } }
                } message: {
                    Text("Your matches, fields and live updates are removed from the MatchTracker server. You leave your teams. What’s on this iPhone stays.")
                }
            if let privacyMessage {
                Text(privacyMessage).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Matches stay on your devices unless you share them with a team. The Team tab says who sees what. Sharing fields sends only their outlines and names, so other players don’t have to draw them.")
        }
    }

    private func recordConsent(guardianName: String) async {
        do {
            try await uploads.postConsent(guardianName: guardianName)
            settings.consentGuardianName = guardianName
            settings.consentAcknowledgedAt = Date()
            privacyMessage = nil
        } catch {
            privacyMessage = "Couldn’t record consent. Check your connection and try again."
        }
    }

    private func requestDeletion() async {
        do {
            try await uploads.requestServerDeletion()
            SystemSurfaces.erase()
            uploads.discardAllUploads()
            settings.leftTeams = []
            for membership in settings.teamMemberships { environment.leaveTeam(membership.code) }
            privacyMessage = "Deletion requested. You’re no longer on any team."
        } catch {
            privacyMessage = "Couldn’t reach the server, so nothing was deleted. Check your connection and try again."
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("iPhone build", value: AppVersion.current)
            LabeledContent("Watch build", value: watchVersion.isEmpty ? "Not reported yet" : watchVersion)
            if let termsOfUse = LegalLinks.termsOfUse {
                Link("Terms of Use", destination: termsOfUse)
            }
        } header: {
            Text("About")
        } footer: {
            // A watch build behind the phone's means the install didn't land, which has repeatedly
            // made a fix look like it didn't work.
            if !watchVersion.isEmpty, watchVersion != AppVersion.current {
                Text("Your watch has a different build. Reinstall MatchTracker from the Watch app to match.")
            }
        }
    }

#if DEBUG
    // MARK: Developer

    /// Synthetic-data tools for testers. Generates full HealthKit workouts + routes + match records
    /// so every screen has realistic data without an Apple Watch. Compiled out of Release builds.
    private var developerSection: some View {
        Section {
            TextField("Server URL override", text: $serverOverride)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit { settings.serverURLOverride = serverOverride }
            Button("Upload All Matches and Fields") { Task { await uploads.uploadAll() } }
                .disabled(uploads.isUploading)
            if let status = uploads.status {
                Text(status).font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }

            Button {
                runDemo { try await makeDemoFactory().generateMatch(daysAgo: 1) }
            } label: {
                Label("Add Sample Match", systemImage: "plus.circle")
            }
            .disabled(isGeneratingDemo)

            Button {
                runDemo {
                    try await makeDemoFactory().generateSeason()
                    return nil
                }
            } label: {
                Label("Generate Sample Season (5)", systemImage: "calendar.badge.plus")
            }
            .disabled(isGeneratingDemo)

            Button {
                runDemo { try await makeDemoFactory().generateIndoorSession(daysAgo: 3) }
            } label: {
                Label("Add Indoor Session", systemImage: "house")
            }
            .disabled(isGeneratingDemo)

            if isGeneratingDemo {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Generating…").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if let demoMessage {
                Text(demoMessage).font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }

            // Diagnostic archive: export this device's full match history to one shareable file, or
            // load a shared archive into a simulator so analysis bugs reproduce against real data.
            DiagnosticArchiveControls(
                healthKit: environment.matches.healthKit,
                summariesProvider: { environment.matches.matches },
                fieldsProvider: { environment.fields.fields },
                settingsSnapshot: {
                    AnalysisSettingsSnapshot(
                        measurementSystem: Self.measurementSystemName,
                        localeIdentifier: Locale.current.identifier,
                        contributeDetectedFields: settings.contributeDetectedFields
                    )
                },
                onImported: { await environment.matches.refresh(); environment.fields.reload() }
            )
        } header: {
            Text("Developer")
        } footer: {
            Text("Creates synthetic soccer matches (HealthKit workout, GPS route, and match record) that flow through the real analysis pipeline. DEBUG builds only.")
        }
    }

    /// Locale measurement system as a stable token for the diagnostic settings snapshot.
    private static var measurementSystemName: String {
        switch Locale.current.measurementSystem {
        case .metric: return "metric"
        case .us: return "us"
        case .uk: return "uk"
        default: return Locale.current.measurementSystem.identifier
        }
    }

    private func makeDemoFactory() -> DemoMatchFactory {
        DemoMatchFactory(
            healthKit: environment.matches.healthKit,
            fields: environment.fields,
            teamCode: settings.teamCode.isEmpty ? "TEST01" : settings.teamCode
        )
    }

    /// Runs a generator closure with progress/disabled state, then refreshes the match list so new
    /// matches appear immediately. An optional returned UUID is surfaced in the result caption.
    private func runDemo(_ work: @escaping () async throws -> UUID?) {
        isGeneratingDemo = true
        demoMessage = nil
        Task {
            do {
                let id = try await work()
                if let id {
                    demoMessage = "Added sample match \(id.uuidString.prefix(8))."
                } else {
                    demoMessage = "Generated sample season (5 matches)."
                }
                await environment.matches.refresh()
            } catch {
                demoMessage = "Failed: \(error.localizedDescription)"
            }
            isGeneratingDemo = false
        }
    }
#endif
}

/// A row that looks like a navigation link but presents something instead.
private struct DisclosureRow: View {
    let title: String
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LabeledContent {
                    if let value { Text(value).foregroundStyle(Theme.secondaryLabel) }
                } label: {
                    Text(title).foregroundStyle(Color(.label))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Health

/// What MatchTracker can honestly say about Health access, and how to change it.
private struct HealthAccessView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var matches: MatchStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnanswered = false
    @State private var canSave = false
    @State private var requestFailed = false

    private var healthKit: HealthKitService { environment.matches.healthKit }

    var body: some View {
        Form {
            if !healthKit.isHealthDataAvailable {
                Text("Health isn’t available on this device.")
            } else if isUnanswered {
                Section {
                    Button("Connect Health", action: connect)
                } footer: {
                    Text("MatchTracker hasn’t been set up with Health yet. It reads your soccer workouts, routes, distance, energy and heart rate, and saves the matches you record.")
                }
            } else {
                Section {
                    LabeledContent("Save matches", value: canSave ? "On" : "Off")
                    LabeledContent("Matches found", value: matches.matches.count.formatted())
                } footer: {
                    Text("iOS keeps reading permission private, so MatchTracker can’t tell whether it’s on. If matches are missing, it’s probably off.")
                }
                Section("If matches are missing") {
                    Text("1. Open the Health app and tap your picture.")
                    Text("2. Tap Apps, then MatchTracker.")
                    Text("3. Tap Turn On All.")
                    Button("Open Health") {
                        if let url = URL(string: "x-apple-health://") { openURL(url) }
                    }
                }
                Section {
                    Button("Check Again") { Task { await matches.refresh() } }
                        .disabled(matches.isLoading)
                } footer: {
                    if matches.loadError != nil { Text("Couldn’t read Health. Try again in a moment.") }
                }
            }
        }
        .readableFormWidth()
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) { await update() }
        .alert("Couldn’t Connect Health", isPresented: $requestFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Health didn’t respond. Try again in a moment.")
        }
    }

    private func update() async {
        isUnanswered = await healthKit.hasUnansweredPermissions()
        canSave = healthKit.canSaveWorkouts
    }

    private func connect() {
        Task {
            do {
                try await healthKit.requestAuthorization(userInitiated: true)
                await matches.refresh()
            } catch {
                requestFailed = true
            }
            await update()
        }
    }
}

// MARK: - Location

/// Location is optional and only for the Fields map, so this says so and links to the switch.
private struct LocationAccessRow: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = CLLocationManager().authorizationStatus

    var body: some View {
        Group {
            if status == .notDetermined {
                LabeledContent("Location", value: "Asks when you use it")
            } else {
                DisclosureRow(title: "Location", value: isOn ? "While using the app" : "Off") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityHint("Opens Settings")
            }
        }
        .onChange(of: scenePhase) { status = CLLocationManager().authorizationStatus }
    }

    private var isOn: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
}

// MARK: - Guardian consent

/// A parent or guardian's acknowledgment for youth-team players.
private struct GuardianConsentSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var guardianName = ""

    private var trimmedName: String { guardianName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Parent or guardian’s name", text: $guardianName)
                        .textInputAutocapitalization(.words)
                        .textContentType(.name)
                } footer: {
                    Text("By submitting, you agree as this player’s parent or guardian that their match data may be shared with their team.")
                }
            }
            .navigationTitle("Guardian Consent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(trimmedName)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
