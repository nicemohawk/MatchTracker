import ActivityKit
import SwiftUI
import WidgetKit
import MatchTrackerKit

struct MatchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        configuration.smallFamilyWhereAvailable()
    }

    private var configuration: ActivityConfiguration<MatchActivityAttributes> {
        ActivityConfiguration(for: MatchActivityAttributes.self) { context in
            let _ = KitColors.refresh()
            LiveActivityContent(state: context.state, units: context.attributes.units, isStale: context.isStale)
                .widgetURL(context.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(state: context.state, units: context.attributes.units,
                                         isStale: context.isStale)
                }
            } compactLeading: {
                IslandCompactLeading(state: context.state)
            } compactTrailing: {
                IslandCompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                IslandMinimal(state: context.state)
            }
            .keylineTint(SurfacePalette.us)
            .widgetURL(context.link)
        }
    }
}

private extension ActivityViewContext<MatchActivityAttributes> {
    /// The match being played, then the match that was.
    var link: URL {
        (state.hasEnded ? MatchTrackerLink.matchStarting(attributes.startDate) : .live).url
    }
}

private struct LiveActivityContent: View {
    let state: LiveMatchState
    let units: UnitSystem
    let isStale: Bool

    var body: some View {
        if #available(iOS 18.0, *) {
            FamilyAware(state: state, units: units, isStale: isStale)
        } else {
            LiveActivityLockScreenView(state: state, units: units, isStale: isStale)
        }
    }

    @available(iOS 18.0, *)
    private struct FamilyAware: View {
        @Environment(\.activityFamily) private var family
        let state: LiveMatchState
        let units: UnitSystem
        let isStale: Bool

        var body: some View {
            switch family {
            case .small: LiveActivitySmallView(state: state, units: units, isStale: isStale)
            default: LiveActivityLockScreenView(state: state, units: units, isStale: isStale)
            }
        }
    }
}

private extension WidgetConfiguration {
    /// The Smart Stack on Apple Watch, and CarPlay.
    func smallFamilyWhereAvailable() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}
