//
//  WatchSettingsView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Watch-side preferences: sport, referee mode, and the double-tap gesture mapping.
struct WatchSettingsView: View {
    @Environment(ConnectivityManager.self) private var connectivity

    @State private var refereeMode = WatchSettings.refereeMode
    @State private var doubleTapAction = WatchSettings.doubleTapAction
    @State private var sportID = WatchSettings.sportID

    var body: some View {
        Form {
            Section {
                Picker(selection: $sportID) {
                    ForEach(SportProfile.all) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                } label: {
                    settingLabel("Sport", systemImage: "sportscourt.fill", tint: WatchTheme.turf)
                }
                .onChange(of: sportID) { _, newValue in
                    WatchSettings.sportID = newValue
                }
            } header: {
                sectionHeader("Sport", tint: WatchTheme.turf)
            }

            Section {
                Toggle(isOn: $refereeMode) {
                    settingLabel("Referee mode", systemImage: "flag.checkered", tint: WatchTheme.signal)
                }
                .onChange(of: refereeMode) { _, newValue in
                    WatchSettings.refereeMode = newValue
                }
            } footer: {
                Text("Cards and fouls instead of player stats.")
            }

            Section {
                Picker(selection: $doubleTapAction) {
                    ForEach(DoubleTapAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                } label: {
                    settingLabel("Double tap logs", systemImage: "hand.tap.fill", tint: WatchTheme.pace)
                }
                .onChange(of: doubleTapAction) { _, newValue in
                    WatchSettings.doubleTapAction = newValue
                }
            } header: {
                sectionHeader("Double Tap", tint: WatchTheme.pace)
            }

            if let teamCode = connectivity.teamCode, !teamCode.isEmpty {
                Section {
                    settingLabel(teamCode, systemImage: "person.3.fill", tint: WatchTheme.bench)
                } header: {
                    sectionHeader("Team", tint: WatchTheme.bench)
                }
            }
        }
        .navigationTitle("Settings")
    }

    /// Themed uppercase section header tinted to the section's semantic accent.
    private func sectionHeader(_ title: String, tint: Color) -> some View {
        Text(title)
            .watchCaptionLabel()
            .foregroundStyle(tint)
    }

    /// A row label whose glyph carries the section's tint while the text stays neutral.
    private func settingLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}
