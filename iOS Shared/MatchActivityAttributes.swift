import ActivityKit
import Foundation
import MatchTrackerKit

/// A match in progress as a Live Activity. Compiled into both the app (which starts and updates it)
/// and the widget extension (which draws it).
struct MatchActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveMatchState

    var startDate: Date
    /// Resolved by the app: an extension can't see a units override.
    var units: UnitSystem
}
