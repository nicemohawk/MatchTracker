import Foundation

/// Notices somebody coming off and going back on where there's no GPS.
///
/// The heart knows, a minute late: what it was being asked for falls by twenty beats or more and
/// stays there. The wrist knows at once, but nobody can say beforehand what resting looks like on
/// it. So the heart decides, and labels what the wrist was doing at the time, until the wrist has
/// been seen enough both ways to speak first. Measured on a player's indoor nights, the heart alone
/// is wrong less than once a night and takes about a minute and a half to call a rest.
public final class IndoorSubDetector {
    public static let step: TimeInterval = 5
    /// A fall smaller than this (bpm) isn't rest; a goalkeeper's night may hold nothing larger.
    private static let smallestDifference = 22.0
    private static let expectedDifference = 35.0
    private static let smallestFall = 20.0
    /// Two minutes of playing, before there's anything to fall from.
    private static let enough = 24

    private struct Reading {
        var date: Date
        var demand: Double
    }

    /// What the wrist does on and off, kept from one match to the next.
    public private(set) var motion: IndoorMotion

    private var isOnPitch: Bool
    private var logOdds: Double
    private var pending = 0
    private var rates: [Double] = []
    private var recent: [Reading] = []
    private var playingDemand: [Double] = []
    private var playingRates: [Double] = []
    private var restingDemand: [Double] = []
    private var levels: [Double] = []
    private var settledFor = 0
    private var mutedUntil: Date?
    private var lastManualDate: Date?

    public init(initiallyOnPitch: Bool = true, motion: IndoorMotion = IndoorMotion()) {
        isOnPitch = initiallyOnPitch
        logOdds = initiallyOnPitch ? 2 : -2
        self.motion = motion
    }

    /// Call every `step` seconds with what's known now; nil for a reading that isn't coming.
    /// - Parameter motion: The wrist's level over the last `step` seconds (`MotionTrace`).
    public func process(at date: Date, heartRate: Double?, motion level: Double?) -> MatchEvent? {
        guard let heartRate, heartRate > 0 else {
            rates = []
            return nil
        }
        rates = Array((rates + [heartRate]).suffix(8))
        levels = Array((levels + [level].compactMap { $0 }).suffix(6))
        let demand = currentDemand
        recent = Array((recent + [Reading(date: date, demand: demand)]).suffix(48))

        let (low, high) = expectedLevels(demand)
        let spread = (high - low) / 2.4
        var evidence = (pow(demand - low, 2) - pow(demand - high, 2)) / (2 * spread * spread)
        evidence = min(max(evidence, -2.5), 2.5) * 0.35
        let heart = evidence
        let wrist = level == nil ? nil : motion.evidence(levels)
        if let wrist { evidence += wrist * 0.35 }

        let chance = 1 / (1 + exp(-logOdds)), carried = chance * (1 - 1 / 30.0) + (1 - chance) / 30.0
        logOdds = min(max(log(carried / (1 - carried)) + evidence, -5), 5)
        learn(demand, heart: heart)
        return change(at: date, middle: (low + high) / 2, agrees: wrist)
    }

    /// The wearer has the last word, and a while to be right in.
    public func recordManualEvent(_ event: MatchEvent) {
        switch event.kind {
        case .subIn: (isOnPitch, logOdds) = (true, 4)
        case .subOut: (isOnPitch, logOdds) = (false, -4)
        default: return
        }
        pending = 0
        settledFor = 0
        lastManualDate = event.date
        mutedUntil = event.date.addingTimeInterval(120)
    }

    /// They never came off, so the same signs mean nothing for a while.
    public func reject(at date: Date) {
        recordManualEvent(MatchEvent(kind: .subIn, date: date))
        mutedUntil = date.addingTimeInterval(300)
    }

    // MARK: Steps

    /// Where the heart is heading: where it is, plus how fast it's moving times its lag.
    private var currentDemand: Double {
        func smooth(_ back: Int) -> Double {
            let end = rates.count - back
            return mean(Array(rates[max(0, end - 3)..<max(end, 1)]))
        }
        let back = min(5, rates.count - 1)
        guard back > 0 else { return rates.last ?? 0 }
        let slope = (smooth(0) - smooth(back)) / (Double(back) * Self.step)
        return smooth(0) + slope * (slope > 0 ? 40 : 60)
    }

    private func expectedLevels(_ demand: Double) -> (low: Double, high: Double) {
        let high = playingDemand.count >= Self.enough ? quantile(playingDemand, 0.6)
            : max(playingDemand.suffix(12).max() ?? demand, 0)
        let low = restingDemand.count >= Self.enough ? quantile(restingDemand, 0.4) : high - Self.expectedDifference
        return (min(low, high - Self.smallestDifference), high)
    }

    /// Only from stretches there's no doubt about.
    private func learn(_ demand: Double, heart: Double) {
        let isSettled = abs(logOdds) > 3
        if isOnPitch, isSettled || playingDemand.count < Self.enough {
            playingDemand = Array((playingDemand + [demand]).suffix(720))
            playingRates = Array((playingRates + [rates.last ?? 0]).suffix(720))
        } else if !isOnPitch, isSettled {
            restingDemand = Array((restingDemand + [demand]).suffix(720))
        }
        settledFor = isSettled && (logOdds > 0) == isOnPitch ? settledFor + 1 : 0
        // The heart itself is sure, and has been long enough for the wrist to have been doing the same:
        // a wrist that taught itself would only ever agree.
        if settledFor >= 15, (heart > 0.3) == isOnPitch, abs(heart) > 0.3, levels.count == 6 { motion.learn(levels, isOn: isOnPitch) }
    }

    private func change(at date: Date, middle: Double, agrees wrist: Double?) -> MatchEvent? {
        if let mutedUntil, date < mutedUntil {
            logOdds = isOnPitch ? max(logOdds, 0) : min(logOdds, 0)
            return nil
        }
        let wantsOn = isOnPitch ? logOdds > -1.5 : logOdds > 1.5
        guard wantsOn != isOnPitch, playingDemand.count >= Self.enough else {
            pending = 0
            return nil
        }
        pending += 1
        // Alone, the heart is given a minute to change its mind.
        let wristAgrees = wrist.map { ($0 > 0.5) == wantsOn && abs($0) > 0.5 } ?? false
        guard pending > (wristAgrees ? 2 : wantsOn ? 6 : 12) else { return nil }
        // By now a rest shows in the heart rate itself. A goalkeeper's quiet spell barely does.
        if !wantsOn, !wristAgrees, quantile(playingRates, 0.5) - mean(Array(rates.suffix(3))) < Self.smallestFall { return nil }
        isOnPitch = wantsOn
        pending = 0
        settledFor = 0
        // Dated when it turned, not when it was believed.
        let turned = recent.lastIndex { ($0.demand > middle) != wantsOn }.map { recent[min($0 + 1, recent.count - 1)].date } ?? date
        let moved = max(turned.addingTimeInterval(-15), lastManualDate ?? .distantPast)
        return MatchEvent(kind: wantsOn ? .subIn : .subOut, date: moved, source: .automatic)
    }
}

/// What one wrist does on court and off it. Learned, because it differs too much to assume: some
/// players clap and pace all bench long.
public struct IndoorMotion: Codable, Equatable, Sendable {
    private struct Side: Codable, Equatable, Sendable {
        var count = 0.0
        var mean = 0.0
        var squares = 0.0

        var deviation: Double { count > 1 ? max((squares / count).squareRoot(), 0.15) : 1 }

        mutating func add(_ value: Double) {
            // Old matches fade: a new strap is a new wrist.
            let weight = min(count + 1, 600)
            let difference = value - mean
            count = weight
            mean += difference / weight
            squares += difference * (value - mean) - (weight >= 600 ? squares / weight : 0)
        }
    }

    private var on = Side()
    private var off = Side()

    public init() {}

    /// The livelier part of half a minute, on a scale where twice as lively is always the same step.
    private static func liveliness(_ levels: [Double]) -> Double {
        let sorted = levels.sorted()
        return log(sorted[sorted.count * 3 / 4] + 0.02)
    }

    mutating func learn(_ levels: [Double], isOn: Bool) {
        if isOn { on.add(Self.liveliness(levels)) } else { off.add(Self.liveliness(levels)) }
    }

    /// Whether on and off have been seen enough, and differ enough, to tell apart.
    public var canTell: Bool {
        on.count >= 48 && off.count >= 36 && on.mean - off.mean >= on.deviation / 2 + off.deviation / 2
    }

    /// Positive for playing. Nil while it can't tell.
    func evidence(_ levels: [Double]) -> Double? {
        guard canTell, levels.count >= 4 else { return nil }
        let value = Self.liveliness(levels)
        func likelihood(_ side: Side) -> Double {
            -pow(value - side.mean, 2) / (2 * side.deviation * side.deviation) - log(side.deviation)
        }
        return min(max(likelihood(on) - likelihood(off), -2.5), 2.5)
    }
}

private func quantile(_ values: [Double], _ share: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
}
