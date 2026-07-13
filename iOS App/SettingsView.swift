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
    @State private var healthKitMessage: String?

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
                    if let status = uploads.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }

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
            }
        }
    }

    private func commit() {
        settings.playerName = playerName
        settings.teamCode = teamCode.uppercased()
        settings.serverURLOverride = serverOverride
        environment.settingsChanged()
    }
}
