// SettingsView.swift
// MatchTracker

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var uploads: UploadService
    @Environment(BacklogImporter.self) private var backlogImporter
    @Environment(\.dismiss) private var dismiss
    @State private var showingImport = false

    @State private var playerName = ""
    @State private var teamCode = ""
    @State private var serverOverride = ""
    @State private var contributeDetectedFields = true
    @State private var healthKitMessage: String?
    @State private var showingConsentSheet = false
    @State private var showingDeletionConfirmation = false
    @State private var privacyMessage: String?
#if DEBUG
    @State private var isGeneratingDemo = false
    @State private var demoMessage: String?
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Player") {
                    LabeledContent("Name") {
                        TextField("Player name", text: $playerName)
                            .textInputAutocapitalization(.words)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Team code") {
                        TextField("Team code", text: $teamCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Backend") {
                    TextField("Server URL override", text: $serverOverride)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await uploads.uploadAll() }
                    } label: {
                        Label {
                            Text("Upload all matches & fields")
                        } icon: {
                            Image(systemName: "square.and.arrow.up.on.square").foregroundStyle(Theme.pace)
                        }
                    }
                    .disabled(uploads.isUploading)
                    if uploads.pendingUploadCount > 0 {
                        HStack {
                            Label("Pending uploads: \(uploads.pendingUploadCount)",
                                  systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Button("Retry now") {
                                Task { await uploads.flushQueue() }
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.subheadline)
                    }
                    if let status = uploads.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Contribute detected fields", isOn: $contributeDetectedFields)
                } header: {
                    Text("Community")
                } footer: {
                    Text("Nearby pitches detected from satellite imagery are shared to the community field database to help everyone auto-detect fields. Your personal fields and match data are never shared this way.")
                }

                privacySection

                Section("Health") {
                    Button {
                        Task {
                            do {
                                try await environment.matches.healthKit.requestAuthorization()
                                healthKitMessage = "HealthKit authorization requested."
                            } catch {
                                healthKitMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label {
                            Text("Re-authorize HealthKit")
                        } icon: {
                            Image(systemName: "heart.text.square").foregroundStyle(Theme.heart)
                        }
                    }
                    if let healthKitMessage {
                        Text(healthKitMessage).font(.caption).foregroundStyle(.secondary)
                    }

                    Button {
                        showingImport = true
                    } label: {
                        HStack {
                            Label {
                                Text("Import match history")
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.turf)
                            }
                            Spacer()
                            if backlogImporter.pendingCount > 0 {
                                Text("\(backlogImporter.pendingCount)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "MatchTracker")
                    LabeledContent("Records", value: "Soccer matches from Apple Watch")
                }

#if DEBUG
                developerSection
#endif
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .onDisappear { commit() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // As a tab (the bar's detached settings circle), edits commit when the
                    // user leaves; the button remains for explicit saves.
                    Button("Save") { commit() }
                }
            }
            .onAppear {
                playerName = settings.playerName
                teamCode = settings.teamCode
                serverOverride = settings.serverURLOverride
                contributeDetectedFields = settings.contributeDetectedFields
            }
            .task { await backlogImporter.scanIfNeeded() }
            .sheet(isPresented: $showingImport) { BacklogImportView() }
        }
    }

    /// Minors privacy: initials-only display, guardian consent, and full data deletion.
    private var privacySection: some View {
        Section {
            if let acknowledgedAt = settings.consentAcknowledgedAt {
                LabeledContent("Guardian consent",
                               value: acknowledgedAt.formatted(date: .abbreviated, time: .omitted))
            } else {
                Button {
                    showingConsentSheet = true
                } label: {
                    Label {
                        Text("Record guardian consent")
                    } icon: {
                        Image(systemName: "person.badge.shield.checkmark").foregroundStyle(Theme.turf)
                    }
                }
            }

            Button(role: .destructive) {
                showingDeletionConfirmation = true
            } label: {
                Label("Request data deletion", systemImage: "trash")
            }

            if let privacyMessage {
                Text(privacyMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Initials-only display is set per team in the Team tab. Deletion removes this device's data from the team server.")
        }
        .sheet(isPresented: $showingConsentSheet) {
            GuardianConsentSheet { guardianName in
                Task { await recordConsent(guardianName: guardianName) }
            }
        }
        .confirmationDialog("Delete all server data for this device?",
                            isPresented: $showingDeletionConfirmation,
                            titleVisibility: .visible) {
            Button("Request Deletion", role: .destructive) {
                Task { await requestDeletion() }
            }
        } message: {
            Text("Matches, fields, comments and live data uploaded from this device will be removed from the backend. Local data stays on the device.")
        }
    }

    private func recordConsent(guardianName: String) async {
        do {
            try await uploads.postConsent(guardianName: guardianName)
            settings.consentGuardianName = guardianName
            settings.consentAcknowledgedAt = Date()
            privacyMessage = "Consent recorded."
        } catch {
            privacyMessage = "Couldn't reach the server: \(error.localizedDescription)"
        }
    }

    private func requestDeletion() async {
        do {
            try await uploads.requestServerDeletion()
            privacyMessage = "Deletion requested. Server data will be purged."
        } catch {
            privacyMessage = "Couldn't reach the server: \(error.localizedDescription)"
        }
    }

    private func commit() {
        settings.playerName = playerName
        settings.teamCode = teamCode.uppercased()
        settings.serverURLOverride = serverOverride
        settings.contributeDetectedFields = contributeDetectedFields
        environment.settingsChanged()
    }

#if DEBUG
    /// Synthetic-data tools for testers. Generates full HealthKit workouts + routes + match records
    /// so every screen has realistic data without an Apple Watch. Compiled out of Release builds.
    private var developerSection: some View {
        Section {
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
                Text(demoMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Creates synthetic soccer matches (HealthKit workout, GPS route, and match record) that flow through the real analysis pipeline. DEBUG builds only.")
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

/// Small sheet capturing a parent/guardian acknowledgment for youth-team players.
private struct GuardianConsentSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var guardianName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Parent/guardian name", text: $guardianName)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("By submitting, the guardian acknowledges this player's match data may be shared with their team.")
                }
                Button("Acknowledge & Submit") {
                    onSubmit(guardianName)
                    dismiss()
                }
                .disabled(guardianName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("Guardian Consent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
