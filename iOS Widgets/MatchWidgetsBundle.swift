import SwiftUI
import WidgetKit
import MatchTrackerKit

@main
struct MatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LastMatchWidget()
        SeasonWidget()
        MatchLiveActivity()
        if #available(iOS 18.0, *) {
            StartOnWatchControl()
            LiveMatchControl()
            SeasonControl()
        }
    }
}
