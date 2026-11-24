// ShareReplay.swift
// MatchTracker
//
// The match as a fifteen-second vertical video. Frames are a pure function of the match and the
// frame number — no clock, no randomness — so the same match always makes the same film.

import AVFoundation
import UIKit
import MatchTrackerKit

/// Renders a match's replay to an MP4, off the main actor. Cancel the task to stop.
struct MatchReplayRenderer: Sendable {
    enum Failure: LocalizedError {
        case nothingToReplay
        case writing(String)

        var errorDescription: String? {
            switch self {
            case .nothingToReplay: return "This match has no route to replay."
            case .writing(let reason): return "The video couldn't be made. \(reason)"
            }
        }
    }

    static let size = CGSize(width: 1080, height: 1920)
    static let framesPerSecond = 30
    static let duration = 15.0
    /// The closing picture, settled: what to show for the film before it plays.
    static let posterTime = 14.0
    static var frameCount: Int { Int(duration) * framesPerSecond }
    /// Fifteen seconds of this is about 15 MB, under every network's limits.
    private static let bitsPerSecond = 8_000_000

    let match: ShareMatch
    var showsFieldName = true

    /// - Parameter progress: 0...1, called from a background thread.
    /// - Returns: The movie's URL in a temporary directory the caller may keep or delete.
    func render(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Match \(match.date.formatted(.iso8601.year().month().day())).mp4")
        do {
            try await render(to: url, progress: progress)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func render(to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let work = Task.detached(priority: .userInitiated) { [self] in
            try await write(to: url, progress: progress)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// One frame as an image, for posters and tests.
    func image(at screenTime: Double) throws -> CGImage {
        guard let scene = ReplayScene(match: match, showsFieldName: showsFieldName) else { throw Failure.nothingToReplay }
        guard let context = CGContext(data: nil, width: Int(Self.size.width), height: Int(Self.size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: Self.bitmapInfo) else { throw Failure.writing("Not enough memory.") }
        scene.draw(at: screenTime, in: context)
        guard let image = context.makeImage() else { throw Failure.writing("Not enough memory.") }
        return image
    }

    private static var bitmapInfo: UInt32 {
        CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    }

    private func write(to url: URL, progress: @Sendable (Double) -> Void) async throws {
        guard let scene = ReplayScene(match: match, showsFieldName: showsFieldName) else { throw Failure.nothingToReplay }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(Self.size.width),
            AVVideoHeightKey: Int(Self.size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: Self.framesPerSecond,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(Self.size.width),
            kCVPixelBufferHeightKey as String: Int(Self.size.height),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writing(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        do {
            for frame in 0..<Self.frameCount {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else {
                        throw Failure.writing(writer.error?.localizedDescription ?? "")
                    }
                    try await Task.sleep(for: .milliseconds(3))
                }
                try Task.checkCancellation()
                try autoreleasepool {
                    try append(frame: frame, of: scene, to: adaptor, writer: writer)
                }
                progress(Double(frame + 1) / Double(Self.frameCount))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writing(writer.error?.localizedDescription ?? "") }
    }

    private func append(frame: Int, of scene: ReplayScene, to adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        writer: AVAssetWriter) throws {
        guard let pool = adaptor.pixelBufferPool else { throw Failure.writing("Not enough memory.") }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw Failure.writing("Not enough memory.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(Self.size.width),
                                      height: Int(Self.size.height), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Self.bitmapInfo) else {
            throw Failure.writing("Not enough memory.")
        }
        scene.draw(at: Double(frame) / Double(Self.framesPerSecond), in: context)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(Self.framesPerSecond))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw Failure.writing(writer.error?.localizedDescription ?? "")
        }
    }
}

// MARK: - The film

/// Draws any instant of the replay. Keeps running totals between frames, so use one per thread;
/// going backward simply starts the totals again.
private final class ReplayScene {
    private let match: ShareMatch
    private let pitch: SharePitch
    private let replay: ShareReplay
    private let showsFieldName: Bool
    private let timeline: ReplayTimeline
    private let artist: PitchArtist
    private let heatReference: Float
    private let turf: CGImage?
    /// Where the player is drawn at each tick of screen time; nil off the pitch or between halves.
    private let path: [PitchPoint?]
    private let units = UnitSystem.current

    private var accumulator = PitchHeat.Accumulator()
    private var accumulatedCount = 0
    private var heatImage: (count: Int, cooling: Double, image: CGImage)?

    private static let ticksPerSecond = 120.0
    private let canvas = MatchReplayRenderer.size

    /// How long a goal or assist stays on screen.
    private static let calloutSeconds = 1.15

    init?(match: ShareMatch, showsFieldName: Bool) {
        guard let pitch = match.pitch, let replay = match.replay, !replay.samples.isEmpty else { return nil }
        self.match = match
        self.pitch = pitch
        self.replay = replay
        self.showsFieldName = showsFieldName
        artist = PitchArtist(size: pitch.size, bounds: CGRect(origin: .zero, size: MatchReplayRenderer.size),
                             insets: UIEdgeInsets(top: 428, left: 90, bottom: 342, right: 90))
        var moments = replay.moments.map {
            ReplayTimeline.Moment(interval: DateInterval(start: $0.date.addingTimeInterval(-6), duration: 16),
                                  extraScreenSeconds: $0.kind == .assist ? 0.3 : 0.5)
        }
        if let best = replay.bestRun {
            moments.append(.init(interval: best.interval, extraScreenSeconds: 2.0))
        }
        timeline = ReplayTimeline(periods: replay.periods, playing: replay.playing, moments: moments,
                                  duration: MatchReplayRenderer.duration)
        guard !timeline.chapters.isEmpty else { return nil }
        heatReference = HeatImage.reference(for: pitch.heat, size: pitch.size)
        path = Self.path(replay: replay, timeline: timeline)
        turf = Self.image(size: MatchReplayRenderer.size) { [artist] cg in artist.drawTurf(in: cg) }
    }

    // MARK: Path

    /// Racing through a match, the raw fixes would be a blur of jumps. Smoothing in screen time gives
    /// a dot that glides at full speed and follows every step when the clock slows.
    private static func path(replay: ShareReplay, timeline: ReplayTimeline) -> [PitchPoint?] {
        let count = Int(timeline.duration * ticksPerSecond) + 1
        var path = [PitchPoint?](repeating: nil, count: count)
        let samples = replay.samples
        for chapter in timeline.chapters {
            let first = Int((chapter.screen.lowerBound * ticksPerSecond).rounded(.up))
            let last = min(count - 1, Int(chapter.screen.upperBound * ticksPerSecond))
            guard first <= last else { continue }
            var raw: [PitchPoint?] = []
            var index = 0
            for tick in first...last {
                let date = timeline.matchDate(at: Double(tick) / ticksPerSecond, in: chapter)
                while index + 1 < samples.count, samples[index + 1].date <= date { index += 1 }
                raw.append(place(at: date, after: index, in: samples))
            }
            let sigma = 0.11 * ticksPerSecond
            let radius = Int(sigma * 2.5)
            for position in raw.indices where raw[position] != nil {
                var across = 0.0, up = 0.0, total = 0.0
                for neighbor in max(0, position - radius)...min(raw.count - 1, position + radius) {
                    guard let point = raw[neighbor] else { continue }
                    let offset = Double(neighbor - position) / sigma
                    let weight = exp(-offset * offset / 2)
                    across += point.across * weight
                    up += point.up * weight
                    total += weight
                }
                path[first + position] = PitchPoint(across: across / total, up: up / total)
            }
        }
        return path
    }

    private static func place(at date: Date, after index: Int, in samples: [ShareReplay.Sample]) -> PitchPoint? {
        let from = samples[index]
        guard index + 1 < samples.count else {
            return abs(date.timeIntervalSince(from.date)) < 15 ? from.point : nil
        }
        let to = samples[index + 1]
        let gap = to.date.timeIntervalSince(from.date)
        // A longer hole is the bench, a break or lost GPS: say nothing about where they were.
        guard date >= from.date, gap > 0, gap < 15 else {
            return abs(date.timeIntervalSince(from.date)) < 15 ? from.point : nil
        }
        let share = date.timeIntervalSince(from.date) / gap
        return PitchPoint(across: from.point.across + (to.point.across - from.point.across) * share,
                          up: from.point.up + (to.point.up - from.point.up) * share)
    }

    private func player(at screenTime: Double) -> PitchPoint? {
        let position = screenTime * Self.ticksPerSecond
        let index = Int(position)
        guard path.indices.contains(index), let from = path[index] else { return nil }
        guard path.indices.contains(index + 1), let to = path[index + 1] else { return from }
        let share = position - Double(index)
        return PitchPoint(across: from.across + (to.across - from.across) * share, up: from.up + (to.up - from.up) * share)
    }

    // MARK: Frame

    /// Everything that depends on the instant, worked out once per frame.
    private struct Instant {
        var screenTime: Double
        var phase: ReplayTimeline.Phase
        var date: Date
        /// 0 while the match runs, 1 once the closing has settled.
        var closing: Double
        /// 0 before kick-off's lines are drawn, 1 after.
        var opening: Double
        /// How much the best run owns the screen right now.
        var spotlight: Double
    }

    private func instant(at screenTime: Double) -> Instant {
        let phase = timeline.phase(at: screenTime)
        var opening = 1.0, closing = 0.0
        let date: Date
        switch phase {
        case .opening(let progress):
            opening = progress
            date = timeline.chapters[0].period.start
        case .playing(let index):
            date = timeline.matchDate(at: screenTime, in: timeline.chapters[index])
        case .pause(let index, _):
            date = timeline.chapters[index].period.end
        case .closing(let progress):
            closing = ease(min(1, progress / 0.4))
            date = timeline.chapters[timeline.chapters.count - 1].period.end
        }
        var spotlight = 0.0
        if let best = replay.bestRun, let from = timeline.screenTime(of: best.interval.start),
           let to = timeline.screenTime(of: best.interval.end) {
            spotlight = min(ease((screenTime - (from - 0.25)) / 0.35), ease(((to + 0.7) - screenTime) / 0.4))
        }
        return Instant(screenTime: screenTime, phase: phase, date: date, closing: closing, opening: opening, spotlight: spotlight)
    }

    func draw(at screenTime: Double, in cg: CGContext) {
        let now = instant(at: screenTime)
        cg.saveGState()
        // Top-down, like UIKit, so the pitch and the type share one set of coordinates.
        cg.translateBy(x: 0, y: canvas.height)
        cg.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(cg)
        drawPitch(now, in: cg)
        drawScoreboard(now, in: cg)
        drawFooter(now, in: cg)
        drawCentered(now, in: cg)
        UIGraphicsPopContext()
        cg.restoreGState()
    }

    private func drawPitch(_ now: Instant, in cg: CGContext) {
        cg.saveGState()
        // The camera leans in for the best run and otherwise drifts in almost imperceptibly.
        let drift = 1 + 0.02 * min(1, now.screenTime / MatchReplayRenderer.duration) * (1 - now.closing)
        if let best = replay.bestRun, now.spotlight > 0 {
            let points = best.run.points.map(artist.place)
            let center = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                 y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            let zoom = 1 + 0.5 * now.spotlight
            // Never so far that the frame runs out of grass.
            let home = CGPoint(x: artist.pitch.midX, y: artist.pitch.midY)
            let focus = CGPoint(x: min(max(center.x, home.x / zoom), canvas.width - (canvas.width - home.x) / zoom),
                                y: min(max(center.y, home.y / zoom), canvas.height - (canvas.height - home.y) / zoom))
            cg.translateBy(x: home.x, y: home.y)
            cg.scaleBy(x: zoom * drift, y: zoom * drift)
            cg.translateBy(x: -focus.x, y: -focus.y)
        } else {
            cg.translateBy(x: artist.pitch.midX, y: artist.pitch.midY)
            cg.scaleBy(x: drift, y: drift)
            cg.translateBy(x: -artist.pitch.midX, y: -artist.pitch.midY)
        }

        if let turf {
            cg.saveGState()
            cg.translateBy(x: 0, y: canvas.height)
            cg.scaleBy(x: 1, y: -1)
            // Outsized, so leaning in never shows an edge.
            cg.draw(turf, in: CGRect(origin: .zero, size: canvas))
            cg.restoreGState()
        }
        if let image = heat(upTo: now.date, cooledBy: now.spotlight) {
            artist.drawHeat(image, in: cg, opacity: 1 - 0.15 * now.spotlight)
        }
        artist.drawMarkings(in: cg, opacity: 0.5 + 0.5 * goalFlash(now), progress: CGFloat(ease(now.opening / 0.85)))
        drawBestRun(now, in: cg)
        drawTrail(now, in: cg)
        drawMarks(now, in: cg)
        cg.restoreGState()
    }

    /// The lines light up when your side scores.
    private func goalFlash(_ now: Instant) -> Double {
        guard let goal = replay.moments.last(where: { $0.date <= now.date && ($0.kind == .myGoal || $0.kind == .goalForUs) }),
              let shownAt = timeline.screenTime(of: goal.date) else { return 0 }
        let age = now.screenTime - shownAt
        return age >= 0 ? pow(max(0, 1 - age / 0.8), 2) : 0
    }

    private func heat(upTo date: Date, cooledBy cooling: Double) -> CGImage? {
        let samples = replay.samples
        if accumulatedCount > 0, samples[accumulatedCount - 1].date > date {
            accumulator = PitchHeat.Accumulator()
            accumulatedCount = 0
        }
        while accumulatedCount < samples.count, samples[accumulatedCount].date <= date {
            accumulator.add(samples[accumulatedCount].point, seconds: samples[accumulatedCount].seconds)
            accumulatedCount += 1
        }
        guard accumulatedCount > 0 else { return nil }
        if let heatImage, heatImage.count == accumulatedCount, heatImage.cooling == cooling { return heatImage.image }
        // Early on, judge heat against less than the full match so something shows; by the end it's
        // exactly the picture on the card.
        let share = Float(accumulatedCount) / Float(samples.count)
        let reference = heatReference * (0.22 + 0.78 * share) * Float(1 + 2.2 * cooling)
        guard let image = HeatImage.render(accumulator.heat, size: pitch.size, pixelWidth: 300, reference: reference) else {
            return nil
        }
        heatImage = (accumulatedCount, cooling, image)
        return image
    }

    private func drawTrail(_ now: Instant, in cg: CGContext) {
        guard case .playing(let index) = now.phase, let current = player(at: now.screenTime) else { return }
        let chapter = timeline.chapters[index]
        let fade = min(ease((now.screenTime - chapter.screen.lowerBound) / 0.25),
                       ease((chapter.screen.upperBound - now.screenTime) / 0.25))
        var points: [CGPoint] = [artist.place(current)]
        var tick = Int(now.screenTime * Self.ticksPerSecond)
        let oldest = max(Int(chapter.screen.lowerBound * Self.ticksPerSecond) + 1, tick - Int(1.1 * Self.ticksPerSecond))
        while tick >= oldest, path.indices.contains(tick), let point = path[tick] {
            points.append(artist.place(point))
            tick -= 2
        }
        let trail = Array(points.reversed())
        let quiet = 1 - 0.8 * now.spotlight
        artist.drawTapered(trail, in: cg, width: 26, color: (0.30, 0.93, 0.48), opacity: 0.2 * fade * quiet)
        artist.drawTapered(trail, in: cg, width: 10, color: (0.93, 1, 0.94), opacity: 0.95 * fade * quiet)
        artist.drawPlayer(current, in: cg, opacity: fade)
    }

    private func drawBestRun(_ now: Instant, in cg: CGContext) {
        guard let best = replay.bestRun, now.date >= best.interval.start else { return }
        let progress = now.date.timeIntervalSince(best.interval.start) / max(1, best.interval.duration)
        // Full strength under the spotlight, then out of the way until the closing picture.
        let strength = max(now.spotlight, 0.28 + 0.72 * now.closing)
        artist.drawRun(best.run, in: cg, opacity: strength, progress: CGFloat(min(1, progress)))
    }

    private func drawMarks(_ now: Instant, in cg: CGContext) {
        for moment in replay.moments where moment.date <= now.date {
            guard let point = moment.point, moment.kind == .myGoal || moment.kind == .assist,
                  let shownAt = timeline.screenTime(of: moment.date) else { continue }
            let age = now.screenTime - shownAt
            if age < 0.8 {
                let center = artist.place(point)
                for delay in [0.0, 0.16] {
                    let spread = ease((age - delay) / 0.6)
                    guard spread > 0, spread < 1 else { continue }
                    let radius = 26 + 120 * spread
                    cg.setStrokeColor(UIColor(white: 1, alpha: 0.8 * (1 - spread)).cgColor)
                    cg.setLineWidth(6 * (1 - spread) + 1)
                    cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                }
            }
            artist.drawMark(PitchMark(kind: moment.kind == .myGoal ? .goal : .assist, point: point), in: cg,
                            scale: CGFloat(pop(age / 0.45)) * 1.1, opacity: 1)
        }
    }

    // MARK: Type

    private func drawScoreboard(_ now: Instant, in cg: CGContext) {
        // Grass behind the type goes dark, so the camera can lean in without pitch lines crossing it.
        drawScrim(from: 0, to: 470, opacity: 0.5 + 0.42 * now.spotlight, darkestAtTop: true, in: cg)
        drawScrim(from: canvas.height - 360 - 320 * now.spotlight, to: canvas.height, opacity: 0.35 + 0.55 * now.spotlight, darkestAtTop: false, in: cg)

        let arrival = ease((now.opening - 0.45) / 0.45)
        let goals = replay.moments.filter { $0.kind != .assist && $0.date <= now.date }
        let us = goals.filter { $0.kind != .goalAgainst }.count
        let them = goals.count - us

        // Score, or the clock when nobody kept score.
        if match.hasScore {
            var bump = 0.0
            if let last = goals.last, let shownAt = timeline.screenTime(of: last.date) {
                let age = now.screenTime - shownAt
                if age < 0.5 { bump = sin(.pi * min(1, max(0, age / 0.5))) }
            }
            let usScored = goals.last.map { $0.kind != .goalAgainst } ?? true
            let size: CGFloat = 178
            let dashWidth: CGFloat = 38
            let dash = CGRect(x: canvas.width / 2 - dashWidth / 2, y: 227, width: dashWidth, height: 14)
            cg.addPath(CGPath(roundedRect: dash, cornerWidth: 7, cornerHeight: 7, transform: nil))
            cg.setFillColor(UIColor(white: 1, alpha: 0.45 * arrival).cgColor)
            cg.fillPath()
            drawText("\(us)", size: size * (1 + 0.22 * CGFloat(usScored ? bump : 0)), weight: .heavy, alpha: arrival,
                     at: CGPoint(x: canvas.width / 2 - dashWidth / 2 - 22, y: 232), alignment: .right, rounded: true)
            drawText("\(them)", size: size * (1 + 0.22 * CGFloat(usScored ? 0 : bump)), weight: .heavy, alpha: arrival * 0.75,
                     at: CGPoint(x: canvas.width / 2 + dashWidth / 2 + 22, y: 232), alignment: .left, rounded: true)
            let nameEdge: CGFloat = 230
            if let opponent = match.opponent {
                let team = match.teamName ?? "Us"
                let room = canvas.width / 2 - nameEdge - 54
                // Both names at the size the longer one needs.
                let widest = [team, opponent].map {
                    NSAttributedString(string: $0, attributes: attributes(size: 46, weight: .semibold, alpha: 1)).size().width
                }.max() ?? 0
                let nameSize = max(26, 46 * min(1, room / max(widest, 1)))
                drawText(opponent, size: nameSize, weight: .semibold, alpha: arrival * 0.75,
                         at: CGPoint(x: canvas.width / 2 + nameEdge, y: 238), alignment: .left, maximumWidth: room)
                drawText(team, size: nameSize, weight: .semibold, alpha: arrival,
                         at: CGPoint(x: canvas.width / 2 - nameEdge, y: 238), alignment: .right, maximumWidth: room)
            }
        }
        let clock = clockText(now)
        if match.hasScore {
            drawText(clock, size: 46, weight: .semibold, alpha: arrival * 0.8, at: CGPoint(x: canvas.width / 2, y: 356),
                     alignment: .center, rounded: true)
        } else {
            drawText(clock, size: 96, weight: .heavy, alpha: arrival, at: CGPoint(x: canvas.width / 2, y: 260),
                     alignment: .center, rounded: true)
        }
    }

    private func clockText(_ now: Instant) -> String {
        if now.closing > 0 { return "Full time" }
        if case .pause(let index, _) = now.phase {
            return timeline.chapters.count == 2 && index == 0 ? "Half-time" : "Break"
        }
        let seconds = Int(timeline.playSeconds(at: now.date))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Three numbers that climb with the match and finish on exactly the figures the app shows.
    private func drawFooter(_ now: Instant, in cg: CGContext) {
        let arrival = ease((now.opening - 0.6) / 0.4)
        let finals = Array(match.numbers.prefix(3))
        guard !finals.isEmpty else { return }
        let grow = 1 + 0.12 * now.closing
        for (index, final) in finals.enumerated() {
            let value = now.closing > 0 ? final : running(final, at: now.opening < 1 ? .distantPast : now.date)
            let x = canvas.width * (CGFloat(index) + 0.5) / CGFloat(finals.count) * 0.88 + canvas.width * 0.06
            let valueText = NSMutableAttributedString(string: value.value,
                                                      attributes: attributes(size: 84 * grow, weight: .bold, alpha: arrival, rounded: true))
            if !value.unit.isEmpty {
                valueText.append(NSAttributedString(string: " " + value.unit,
                                                    attributes: attributes(size: 40 * grow, weight: .semibold, alpha: arrival * 0.85)))
            }
            let size = valueText.size()
            valueText.draw(at: CGPoint(x: x - size.width / 2, y: 1672 - size.height / 2))
            drawText(value.label, size: 38, weight: .medium, alpha: arrival * 0.7, at: CGPoint(x: x, y: 1746), alignment: .center)
        }
        drawText("MatchTracker", size: 36, weight: .semibold, alpha: 0.35 * arrival + 0.5 * now.closing,
                 at: CGPoint(x: canvas.width / 2, y: 1836), alignment: .center)
    }

    private func running(_ final: ShareNumber, at date: Date) -> ShareNumber {
        let sample = accumulatedCount > 0 && date > .distantPast ? replay.samples[accumulatedCount - 1] : nil
        switch final.label {
        case "Distance":
            let total = replay.samples.last?.distance ?? 0
            guard total > 0, replay.totalDistance > 0 else { return final }
            return ShareNumber(units.distance((sample?.distance ?? 0) / total * replay.totalDistance), label: final.label)
        case "Top speed":
            guard let top = replay.topSpeed else { return final }
            return ShareNumber(units.speed(min(sample?.topSpeed ?? 0, top)), label: final.label)
        case "Sprint", "Sprints":
            guard let total = Int(final.value) else { return final }
            let count = min(total, replay.sprintEnds.filter { $0 <= date }.count)
            return ShareNumber(value: "\(count)", label: count == 1 ? "Sprint" : "Sprints")
        default:
            return final
        }
    }

    /// Titles and callouts over the pitch.
    private func drawCentered(_ now: Instant, in cg: CGContext) {
        let center = CGPoint(x: canvas.width / 2, y: artist.pitch.midY)
        if now.opening < 1 || now.screenTime < timeline.chapters[0].screen.lowerBound + 0.3 {
            let leave = 1 - ease((now.screenTime - timeline.chapters[0].screen.lowerBound + 0.15) / 0.4)
            let alpha = ease(now.opening / 0.35) * leave
            let lift = 24 * (1 - ease(now.opening / 0.5))
            drawScrimBand(around: center.y, height: 560, opacity: 0.8 * alpha, in: cg)
            drawText(match.opponent.map { "v \($0)" } ?? "Match replay", size: 104, weight: .heavy, alpha: alpha,
                     at: CGPoint(x: center.x, y: center.y - 46 + lift), alignment: .center, maximumWidth: canvas.width - 160)
            drawText(match.subtitle(showsFieldName: showsFieldName), size: 46, weight: .medium, alpha: alpha * 0.8,
                     at: CGPoint(x: center.x, y: center.y + 48 + lift), alignment: .center, maximumWidth: canvas.width - 160)
        }
        if case .pause(_, let progress) = now.phase {
            let alpha = min(ease(progress / 0.3), ease((1 - progress) / 0.25))
            drawScrimBand(around: center.y, height: 560, opacity: 0.85 * alpha, in: cg)
            drawText(clockText(now), size: 120, weight: .heavy, alpha: alpha, at: center, alignment: .center)
        }
        if let best = replay.bestRun, now.spotlight > 0.01 {
            drawText(best.caption, size: 76, weight: .heavy, alpha: now.spotlight,
                     at: CGPoint(x: center.x, y: 1478), alignment: .center)
            drawText(best.detail, size: 52, weight: .semibold, alpha: now.spotlight * 0.85,
                     at: CGPoint(x: center.x, y: 1552), alignment: .center, rounded: true)
        } else if let callout = callout(now) {
            drawScrimBand(around: artist.pitch.minY + 74, height: 340, opacity: 0.8 * callout.alpha, in: cg)
            drawText(callout.text, size: 88, weight: .heavy, alpha: callout.alpha,
                     at: CGPoint(x: center.x, y: artist.pitch.minY + 74 - 16 * (1 - callout.alpha)), alignment: .center)
        }
    }

    private func callout(_ now: Instant) -> (text: String, alpha: Double)? {
        guard case .playing = now.phase,
              let moment = replay.moments.last(where: { $0.date <= now.date }),
              let shownAt = timeline.screenTime(of: moment.date) else { return nil }
        let age = now.screenTime - shownAt
        guard age < Self.calloutSeconds else { return nil }
        let alpha = min(ease(age / 0.15), ease((Self.calloutSeconds - age) / 0.25))
        switch moment.kind {
        case .myGoal: return ("You scored", alpha)
        case .goalForUs: return ("Goal", alpha)
        case .goalAgainst: return ("They scored", alpha)
        case .assist: return ("Assist", alpha)
        }
    }

    // MARK: Helpers

    private enum Alignment { case left, center, right }

    private func attributes(size: CGFloat, weight: UIFont.Weight, alpha: Double, rounded: Bool = false) -> [NSAttributedString.Key: Any] {
        var font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) { font = UIFont(descriptor: descriptor, size: size) }
        return [.font: font, .foregroundColor: UIColor(white: 1, alpha: min(max(alpha, 0), 1))]
    }

    /// `at` is the vertical middle of the text and its left, center or right edge.
    private func drawText(_ text: String, size: CGFloat, weight: UIFont.Weight, alpha: Double, at point: CGPoint,
                          alignment: Alignment, rounded: Bool = false, maximumWidth: CGFloat = .infinity) {
        guard alpha > 0.004, !text.isEmpty else { return }
        var size = size
        var string = NSAttributedString(string: text, attributes: attributes(size: size, weight: weight, alpha: alpha, rounded: rounded))
        if string.size().width > maximumWidth {
            size = max(size * 0.5, size * maximumWidth / string.size().width)
            string = NSAttributedString(string: text, attributes: attributes(size: size, weight: weight, alpha: alpha, rounded: rounded))
        }
        let measured = string.size()
        let x: CGFloat
        switch alignment {
        case .left: x = point.x
        case .center: x = point.x - measured.width / 2
        case .right: x = point.x - measured.width
        }
        string.draw(at: CGPoint(x: x, y: point.y - measured.height / 2))
    }

    private func drawScrim(from top: CGFloat, to bottom: CGFloat, opacity: Double, darkestAtTop: Bool, in cg: CGContext) {
        let dark = UIColor(red: 0.012, green: 0.035, blue: 0.028, alpha: opacity).cgColor
        let clear = UIColor(red: 0.012, green: 0.035, blue: 0.028, alpha: 0).cgColor
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: (darkestAtTop ? [dark, dark, clear] : [clear, dark, dark]) as CFArray,
                                        locations: darkestAtTop ? [0, 0.7, 1] : [0, 0.3, 1]) else { return }
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    }

    private func drawScrimBand(around y: CGFloat, height: CGFloat, opacity: Double, in cg: CGContext) {
        let dark = UIColor(red: 0.012, green: 0.035, blue: 0.028, alpha: opacity).cgColor
        let clear = UIColor(red: 0.012, green: 0.035, blue: 0.028, alpha: 0).cgColor
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [clear, dark, clear] as CFArray, locations: [0, 0.5, 1]) else { return }
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y - height / 2), end: CGPoint(x: 0, y: y + height / 2), options: [])
    }

    private static func image(size: CGSize, draw: (CGContext) -> Void) -> CGImage? {
        guard let cg = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        draw(cg)
        return cg.makeImage()
    }
}

/// Smoothstep, clamped.
private func ease(_ value: Double) -> Double {
    let t = min(max(value, 0), 1)
    return t * t * (3 - 2 * t)
}

/// Grows past full size and settles.
private func pop(_ value: Double) -> Double {
    let t = min(max(value, 0), 1) - 1
    return t * t * (2.70158 * t + 1.70158) + 1
}
