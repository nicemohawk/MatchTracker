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
            // iPad / wide split: inset the form to a readable measure, centered. The background is
            // attached AFTER so the canvas still fills edge-to-edge behind the narrower form.
            .readableFormWidth()
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Settings is a tab, not a modal — there's no "Save" moment. Edits commit as they're
            // made (plus a belt-and-braces commit when navigating away).
            .onChange(of: playerName) { commit() }
            .onChange(of: teamCode) { commit() }
            .onChange(of: serverOverride) { commit() }
            .onChange(of: contributeDetectedFields) { commit() }
            .onDisappear { commit() }
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

/// Small sheet capturing a parent/guardian acknowledgment for youth-team players. Reskinned to the
/// app's dark design language: a turf shield mark, the acknowledgment copy as a single paragraph, a
/// themed name field, and a turf "Acknowledge & Submit" capsule (disabled until a name is entered).
private struct GuardianConsentSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var guardianName = ""

    private var isNameEmpty: Bool { guardianName.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Theme.turf)
                        .frame(width: 66, height: 66)
                        .background(Theme.chipFill(Theme.turf), in: Circle())
                        .overlay(Circle().strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1))

                    VStack(spacing: 8) {
                        Text("Guardian Consent")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("By submitting, the guardian acknowledges this player's match data may be shared with their team.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parent / Guardian Name").captionLabel().foregroundStyle(Theme.turf)
                        TextField("Parent/guardian name", text: $guardianName)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .textInputAutocapitalization(.words)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .themedCard()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button {
                    Haptics.impact(.medium)
                    onSubmit(guardianName)
                    dismiss()
                } label: {
                    Text("Acknowledge & Submit")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.turf)
                .clipShape(Capsule())
                .disabled(isNameEmpty)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}
