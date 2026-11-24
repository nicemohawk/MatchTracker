//
//  MatchHeat.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// The match on its field: the same heat the phone draws, built up over a couple of seconds the
/// first time it's seen. An empty pitch until the record is saved and analyzed.
struct MatchHeat: View {
    let field: FieldModel
    let record: MatchRecord?
    /// There turned out to be nothing to draw on this field.
    let onFailure: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var picture: HeatPicture?
    @State private var step = 0
    @State private var isOnScreen = false

    private var size: PitchSize { PitchSize(field.rectangle) }

    var body: some View {
        ZStack {
            Canvas { context, canvas in
                context.withCGContext { artist(canvas).drawTurf(in: $0) }
            }
            if let picture, isOnScreen {
                Canvas { context, canvas in
                    context.withCGContext { artist(canvas).drawHeat(picture.steps[min(step, picture.steps.count - 1)], in: $0) }
                }
            }
            Canvas { context, canvas in
                context.withCGContext { artist(canvas).drawMarkings(in: $0) }
            }
        }
        .aspectRatio(PitchArtist.naturalAspectRatio(for: size), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(picture?.sentence ?? "Pitch")
        .modifier(OnScreen { isOnScreen = true })
        .task(id: record?.id) {
            guard let record, picture == nil else { return }
            let field = field
            let made = await Task.detached(priority: .utility) { HeatPicture.make(of: record, on: field) }.value
            if let made { picture = made } else { onFailure() }
        }
        .task(id: isOnScreen && picture != nil) {
            guard isOnScreen, let picture else { return }
            await buildUp(picture)
        }
    }

    private func buildUp(_ picture: HeatPicture) async {
        let last = picture.steps.count - 1
        if !reduceMotion {
            while step < last {
                try? await Task.sleep(for: .seconds(2) / Double(last))
                guard !Task.isCancelled else { return }
                step += 1
            }
            WatchHaptics.click()
        }
        step = last
    }

    private func artist(_ canvas: CGSize) -> PitchArtist {
        PitchArtist(size: size, bounds: CGRect(origin: .zero, size: canvas))
    }
}

/// Whether it has been scrolled to; before watchOS 11 there's no asking.
private struct OnScreen: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.onScrollVisibilityChange(threshold: 0.2) { if $0 { action() } }
        } else {
            content.onAppear(perform: action)
        }
    }
}

/// A match's heat, as a few small pictures of it building up and the whole of it last.
private struct HeatPicture: Sendable {
    let steps: [CGImage]
    let sentence: String

    /// Sweeps the whole track: never on the main actor.
    static func make(of record: MatchRecord, on field: FieldModel) -> HeatPicture? {
        let started = Date()
        guard let end = record.endDate, let track = record.track,
              let analytics = MatchAnalyzer.analyze(MatchAnalysisInput(
                record: record, interval: DateInterval(start: record.startDate, end: end), format: record.format ?? .match,
                track: track, heartRate: [], healthDistanceMeters: nil, savedField: field)) else { return nil }
        let heat = PitchHeat(analytics)
        let size = PitchSize(field.rectangle)
        let reference = HeatImage.reference(for: heat, size: size)
        let images = PitchHeat.buildUp(analytics, steps: 20).compactMap {
            HeatImage.render($0, size: size, pixelWidth: $0 == heat ? 280 : 120, reference: reference)
        }
        guard !images.isEmpty else { return nil }
        MatchLog.info("summary: heat from \(track.count) fixes in \(Int(Date().timeIntervalSince(started) * 1000)) ms",
                      category: "ui")
        return HeatPicture(steps: images, sentence: PitchSentence.describe(heat, directionIsKnown: analytics.isDirectionConfident))
    }
}
