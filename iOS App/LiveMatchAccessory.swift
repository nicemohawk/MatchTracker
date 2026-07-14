//
//  LiveMatchAccessory.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// The live match is our "now playing": this is the content of the iOS 26 `tabViewBottomAccessory`,
/// mirroring Apple Music's now-playing bar. It floats above the tab bar in a Liquid Glass capsule
/// while expanded and merges inline with the bar when it minimizes on scroll. Tapping anywhere
/// opens the full sideline dashboard, just as Apple Music's mini-player expands to the full player.
///
/// Content adapts to `\.tabViewBottomAccessoryPlacement`:
///   - `.expanded`: pulsing live dot, "LIVE", ticking clock, hero score, on-pitch/bench pill, chevron.
///   - `.inline` (merged into the minimized bar): just dot + score + a compact clock.
@available(iOS 26.0, *)
struct LiveMatchAccessory: View {
    @Environment(LiveMatchStore.self) private var liveMatches
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var showingDashboard = false

    var body: some View {
        Button {
            Haptics.selection()
            showingDashboard = true
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep the whole capsule tappable, including the gaps between elements.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Legible on the Liquid Glass material: lean on the score's own weight rather than a heavy
        // opaque background that would fight the glass.
        .sheet(isPresented: $showingDashboard) {
            NavigationStack {
                LiveMatchView(store: liveMatches, projector: liveProjector)
            }
        }
    }

    // MARK: - Placement-adaptive content

    @ViewBuilder private var content: some View {
        if placement == .inline {
            inlineContent
        } else {
            expandedContent
        }
    }

    /// Full capsule content shown while the accessory floats above the tab bar.
    private var expandedContent: some View {
        HStack(spacing: 12) {
            LivePulseDot(diameter: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text("LIVE")
                    .captionLabel()
                    .foregroundStyle(Theme.heart)
                if let update = liveMatches.latest {
                    clock(update)
                        .font(.system(.caption, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let update = liveMatches.latest {
                Text(score(update))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                pitchPill(update)
            }
            Image(systemName: "chevron.up")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Compact content shown once the bar minimizes and the accessory merges inline.
    private var inlineContent: some View {
        HStack(spacing: 8) {
            LivePulseDot(diameter: 8)
            if let update = liveMatches.latest {
                Text(score(update))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                clock(update)
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Pieces

    /// Current scoreline, en dash between goals (nil goals read as 0), matching the app style.
    private func score(_ update: LiveMatchUpdate) -> String {
        "\(update.usGoals ?? 0)–\(update.themGoals ?? 0)"
    }

    /// Elapsed clock, extrapolated from `lastReceivedAt` so it ticks smoothly between updates —
    /// the same drift trick `LiveMatchView` uses.
    private func clock(_ update: LiveMatchUpdate) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let drift = liveMatches.isLive
                ? timeline.date.timeIntervalSince(liveMatches.lastReceivedAt ?? timeline.date)
                : 0
            Text(MatchTrackerFormat.hoursMinutesSeconds(update.elapsed + max(0, drift)))
        }
    }

    /// Mini on-pitch / bench status pill.
    private func pitchPill(_ update: LiveMatchUpdate) -> some View {
        let tint = update.onPitch ? Theme.turf : Theme.bench
        return Image(systemName: update.onPitch ? "figure.soccer" : "chair")
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
    }

    /// Field projector for the live position dot, resolved from streamed points — the same
    /// resolution `MatchesView` uses (duplicated here rather than restructuring that view).
    private var liveProjector: FieldProjector? {
        let coordinates = liveMatches.recentPoints.suffix(30).map(\.coordinate)
        guard !coordinates.isEmpty,
              let field = fields.store.bestMatch(for: Array(coordinates)) else { return nil }
        return FieldProjector(rectangle: field.rectangle)
    }
}

/// A softly pulsing coral dot — the "recording"/live indicator, echoing Apple Music's animated
/// now-playing glyph.
private struct LivePulseDot: View {
    var diameter: CGFloat = 10
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.heart)
            .frame(width: diameter, height: diameter)
            .glow(Theme.heart, radius: 6)
            .scaleEffect(pulsing ? 1.0 : 0.7)
            .opacity(pulsing ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
