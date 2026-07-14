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
            Section("Sport") {
                Picker("Sport", selection: $sportID) {
                    ForEach(SportProfile.all) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .onChange(of: sportID) { _, newValue in
                    WatchSettings.sportID = newValue
                }
            }

            Section {
                Toggle("Referee mode", isOn: $refereeMode)
                    .onChange(of: refereeMode) { _, newValue in
                        WatchSettings.refereeMode = newValue
                    }
            } footer: {
                Text("Cards and fouls instead of player stats.")
            }

            Section("Double Tap") {
                Picker("Double tap logs", selection: $doubleTapAction) {
                    ForEach(DoubleTapAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .onChange(of: doubleTapAction) { _, newValue in
                    WatchSettings.doubleTapAction = newValue
                }
            }

            if let teamCode = connectivity.teamCode, !teamCode.isEmpty {
                Section("Team") {
                    Label(teamCode, systemImage: "person.3")
                        .foregroundStyle(WatchTheme.signal)
                }
            }
        }
        .navigationTitle("Settings")
    }
}
