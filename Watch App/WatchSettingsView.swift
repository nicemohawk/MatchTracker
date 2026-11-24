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
            } footer: {
                Text("On the score and controls pages. Not available while the screen is locked.")
            }

            if let teamCode = connectivity.teamCode, !teamCode.isEmpty {
                Section {
                    settingLabel(teamCode, systemImage: "person.3.fill", tint: WatchTheme.bench)
                } footer: {
                    Text("Team")
                }
            }
        }
        .navigationTitle("Settings")
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
