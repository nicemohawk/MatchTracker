import SwiftUI
import WidgetKit
import MatchTrackerKit

/// The Lock Screen, StandBy and banner presentation. During play: the score, the clock, and whether
/// you're on. At full time: the result.
struct LiveActivityLockScreenView: View {
    let state: LiveMatchState
    let units: UnitSystem
    var isStale = false

    var body: some View {
        Group {
            if state.hasEnded {
                LiveActivitySummary(state: state, units: units)
            } else {
                inPlay
            }
        }
        .padding(16)
    }

    private var inPlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let score = state.score {
                    Text(score)
                        .font(.largeTitle.weight(.bold)).fontDesign(.rounded)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityLabel(state.spokenScore)
                    Spacer(minLength: 12)
                }
                MatchClock(state: state, isStale: isStale)
                    .font(.largeTitle.weight(state.score == nil ? .bold : .medium)).fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(state.score == nil ? .primary : .secondary)
                    // Timer text takes all the width it's offered.
                    .multilineTextAlignment(state.score == nil ? .leading : .trailing)
                    .frame(maxWidth: state.score == nil ? .infinity : 150,
                           alignment: state.score == nil ? .leading : .trailing)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            // At the largest text sizes whether you're on matters more than how far you've run.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    LiveActivityStatus(state: state, isStale: isStale)
                    Spacer(minLength: 0)
                    LiveActivityMeasures(state: state, units: units, isStale: isStale)
                }
                LiveActivityStatus(state: state, isStale: isStale)
                    .minimumScaleFactor(0.7)
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
        }
    }
}

/// "Won 3–1" over "4.6 mi · 72 min".
struct LiveActivitySummary: View {
    let state: LiveMatchState
    let units: UnitSystem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.finalTitle)
                    .font(.title.weight(.bold)).fontDesign(.rounded)
                Text(state.finalDetail(units: units))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 12)
            Image(systemName: "chevron.forward")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where you are, or how old the news is.
struct LiveActivityStatus: View {
    let state: LiveMatchState
    var isStale = false

    var body: some View {
        if isStale {
            Label {
                Text("Last update \(state.updatedAt, style: .time)")
            } icon: {
                Image(systemName: "wifi.slash")
            }
            .foregroundStyle(.secondary)
        } else {
            Label(state.status, systemImage: state.statusSymbol)
                .foregroundStyle(state.isPlaying ? AnyShapeStyle(SurfacePalette.us) : AnyShapeStyle(.secondary))
        }
    }
}

/// Heart rate and distance. Heart rate goes when it's old; distance covered stays covered.
struct LiveActivityMeasures: View {
    let state: LiveMatchState
    let units: UnitSystem
    var isStale = false

    var body: some View {
        HStack(spacing: 14) {
            if let heartRate = state.heartRate, !isStale {
                Label {
                    Text("\(heartRate)").monospacedDigit()
                } icon: {
                    Image(systemName: "heart.fill").foregroundStyle(SurfacePalette.heart)
                }
                .labelStyle(TightLabelStyle())
                .privacySensitive()
                .accessibilityElement()
                .accessibilityLabel("Heart rate \(heartRate)")
            }
            if state.distanceMeters > 0 {
                let distance = units.roughDistance(state.distanceMeters)
                Text(distance.text)
                    .monospacedDigit()
                    .accessibilityLabel(distance.spoken)
            }
        }
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// The Smart Stack on Apple Watch and CarPlay (`ActivityFamily.small`).
struct LiveActivitySmallView: View {
    let state: LiveMatchState
    let units: UnitSystem
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.hasEnded {
                Text(state.finalTitle)
                    .font(.title3.weight(.bold)).fontDesign(.rounded)
                Text(state.finalDetail(units: units))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    if let score = state.score {
                        Text(score)
                            .accessibilityLabel(state.spokenScore)
                        Spacer(minLength: 6)
                    }
                    MatchClock(state: state, isStale: isStale)
                        .foregroundStyle(state.score == nil ? .primary : .secondary)
                        .multilineTextAlignment(state.score == nil ? .leading : .trailing)
                }
                .font(.title3.weight(.bold)).fontDesign(.rounded)
                .monospacedDigit()
                LiveActivityStatus(state: state, isStale: isStale)
                    .font(.footnote)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

// MARK: - Dynamic Island

struct IslandCompactLeading: View {
    let state: LiveMatchState

    var body: some View {
        if let score = state.score {
            Text(score)
                .font(.body.weight(.bold)).fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(SurfacePalette.us)
                .accessibilityLabel(state.spokenScore)
        } else {
            Image(systemName: state.hasEnded ? "flag.checkered" : "soccerball")
                .foregroundStyle(SurfacePalette.us)
        }
    }
}

struct IslandCompactTrailing: View {
    let state: LiveMatchState
    var isStale = false

    var body: some View {
        if state.hasEnded {
            Text("Full time")
                .font(.footnote.weight(.semibold))
        } else {
            MatchClock(state: state, isStale: isStale)
                .font(.body.weight(.medium)).fontDesign(.rounded)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: state.elapsed >= 3540 ? 60 : 48, alignment: .trailing)
                .foregroundStyle(isStale ? .secondary : .primary)
        }
    }
}

struct IslandMinimal: View {
    let state: LiveMatchState

    var body: some View {
        if let score = state.score {
            Text(score)
                .font(.footnote.weight(.bold)).fontDesign(.rounded)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .foregroundStyle(SurfacePalette.us)
                .accessibilityLabel(state.spokenScore)
        } else {
            Image(systemName: "soccerball")
                .foregroundStyle(SurfacePalette.us)
        }
    }
}

struct IslandExpandedLeading: View {
    let state: LiveMatchState

    var body: some View {
        Group {
            if state.hasEnded {
                Text(state.finalTitle)
            } else if let score = state.score {
                Text(score)
                    .contentTransition(.numericText())
                    .accessibilityLabel(state.spokenScore)
            } else {
                Image(systemName: "soccerball")
                    .foregroundStyle(SurfacePalette.us)
                    .accessibilityLabel("Match in progress")
            }
        }
        .font(.title.weight(.bold)).fontDesign(.rounded)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.leading, 6)
    }
}

struct IslandExpandedTrailing: View {
    let state: LiveMatchState
    var isStale = false

    var body: some View {
        if !state.hasEnded {
            MatchClock(state: state, isStale: isStale)
                .font(.title.weight(.medium)).fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.trailing, 6)
        }
    }
}

struct IslandExpandedBottom: View {
    let state: LiveMatchState
    let units: UnitSystem
    var isStale = false

    var body: some View {
        HStack(spacing: 14) {
            if state.hasEnded {
                Text(state.finalDetail(units: units))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                LiveActivityStatus(state: state, isStale: isStale)
                Spacer(minLength: 0)
                LiveActivityMeasures(state: state, units: units, isStale: isStale)
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 6)
    }
}
