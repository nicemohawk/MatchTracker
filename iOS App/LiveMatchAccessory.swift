//
//  LiveMatchAccessory.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// The live match as the iOS 26 `tabViewBottomAccessory`: the "now playing" of a match. A plain
/// button — whoever owns the binding presents the sheet, because this view is rebuilt with every
/// update and anything it presented would go with it.
@available(iOS 26.0, *)
struct LiveMatchAccessory: View {
    @Binding var isPresented: Bool
    @Environment(LiveMatchStore.self) private var liveMatches
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let state = liveMatches.state {
            Button {
                isPresented = true
            } label: {
                content(state)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isPresented)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live match. \(state.spokenScore). \(state.status).")
            .accessibilityHint("Opens the live match")
            .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder private func content(_ state: LiveMatchState) -> some View {
        if placement == .inline {
            HStack(spacing: 8) {
                LiveDot(diameter: 8)
                if let score = state.score {
                    scoreText(score, font: .headline)
                }
                LiveClock(store: liveMatches)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        } else {
            HStack(spacing: 10) {
                LiveDot(diameter: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Live")
                        .font(.subheadline.weight(.semibold))
                    Text(state.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                LiveClock(store: liveMatches)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let score = state.score {
                    scoreText(score, font: .title2)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 16)
        }
    }

    private func scoreText(_ score: String, font: Font) -> some View {
        Text(score)
            .font(font.bold())
            .fontDesign(.rounded)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: score)
    }
}

/// The recording light. Breathes unless motion is reduced.
struct LiveDot: View {
    var diameter: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: diameter))
            .foregroundStyle(Theme.loss)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// The match clock in the app: ticks on from the last update while updates are arriving.
struct LiveClock: View {
    let store: LiveMatchStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let state = store.state {
                Text(MatchTrackerFormat.hoursMinutesSeconds(
                    store.isLive && state.isClockRunning
                        ? max(state.elapsed, context.date.timeIntervalSince(state.clockStart))
                        : state.elapsed))
            }
        }
    }
}
