import SwiftUI
import WidgetKit

/// Entry point for the watchOS WidgetKit extension. Bundles both accessory widgets the
/// extension vends: a Start-Match complication and a last-match summary card.
@main
struct MatchTrackerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StartMatchWidget()
        LastMatchWidget()
    }
}
