// SettingsView.swift
// MatchTracker

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var uploads: UploadService
    @Environment(\.dismiss) private var dismiss

    @State private var playerName = ""
    @State private var teamCode = ""
    @State private var serverOverride = ""
    @State private var contributeDetectedFields = true
    @State private var healthKitMessage: String?
    @State private var showingConsentSheet = false
    @State private var showingDeletionConfirmation = false
    @State private var privacyMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Player") {
                    TextField("Player name", text: $playerName)
                        .textInputAutocapitalization(.words)
                    TextField("Team code", text: $teamCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Backend") {
                    TextField("Server URL override", text: $serverOverride)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await uploads.uploadAll() }
                    } label: {
                        Label("Upload all matches & fields", systemImage: "square.and.arrow.up.on.square")
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
                        Label("Re-authorize HealthKit", systemImage: "heart.text.square")
                    }
                    if let healthKitMessage {
                        Text(healthKitMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "MatchTracker")
                    LabeledContent("Records", value: "Soccer matches from Apple Watch")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commit(); dismiss() }
                }
            }
            .onAppear {
                playerName = settings.playerName
                teamCode = settings.teamCode
                serverOverride = settings.serverURLOverride
                contributeDetectedFields = settings.contributeDetectedFields
            }
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
                    Label("Record guardian consent", systemImage: "person.badge.shield.checkmark")
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
