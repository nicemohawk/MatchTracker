import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct StartOnWatchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StartOnWatch") {
            ControlWidgetButton(action: StartOnWatchIntent()) {
                Label("Start Match", systemImage: "applewatch")
            }
        }
        .displayName("Start Match on Watch")
        .description("Starts recording on your Apple Watch.")
    }
}

@available(iOS 18.0, *)
struct LiveMatchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LiveMatch") {
            ControlWidgetButton(action: OpenLiveMatchIntent()) {
                Label("Live Match", systemImage: "sportscourt")
            }
        }
        .displayName("Live Match")
        .description("Opens the match in progress.")
    }
}

@available(iOS 18.0, *)
struct SeasonControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "Season") {
            ControlWidgetButton(action: OpenSeasonIntent()) {
                Label("Season", systemImage: "soccerball")
            }
        }
        .displayName("Season")
        .description("Opens your season.")
    }
}
