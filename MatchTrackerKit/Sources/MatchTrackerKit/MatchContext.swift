import Foundation

// MARK: - Match formats (workrate that transcends match types)

/// The kind of match being recorded. The workrate score is calibrated to stay honestly
/// comparable across all three: a formal full-size match, a small-sided pickup game on a short
/// turf field, and indoor play where GPS is unreliable or absent.
public enum MatchFormat: String, Codable, CaseIterable, Sendable {
    case match       // formal full-size match (default; wire "match")
    case smallSided  // pickup / small-sided outdoor (wire "small_sided")
    case indoor      // indoor court/dome, GPS unreliable (wire "indoor")

    /// Snake-cased value the backend expects in the `sessions` payload. The `rawValue` of
    /// `smallSided` is `"smallSided"`, so the wire form is mapped explicitly.
    public var wireValue: String {
        switch self {
        case .match: return "match"
        case .smallSided: return "small_sided"
        case .indoor: return "indoor"
        }
    }
}

/// The conditions a match was played under. Drives speed-threshold scaling, workrate reference
/// curves, and which effort signals (GPS distance/sprints vs. heart rate) are trusted.
public struct MatchContext: Codable, Sendable {
    public var format: MatchFormat
    /// Long-axis length of the pitch in meters, taken from the matched field when known. `nil`
    /// falls back to a full-size 105 m pitch.
    public var fieldLengthMeters: Double?

    public init(format: MatchFormat = .match, fieldLengthMeters: Double? = nil) {
        self.format = format
        self.fieldLengthMeters = fieldLengthMeters
    }

    /// Speed/reference scaling versus a 105 m reference pitch: `sqrt(length / 105)`, clamped to
    /// `0.6...1.0`. A shorter field means shorter sprints reach top speed, so thresholds and
    /// distance/sprint references multiply by this factor. Indoor play is always treated as the
    /// smallest scale (0.6) regardless of any field length, since court dimensions and GPS both
    /// argue against full-pitch calibration.
    public var pitchScale: Double {
        if format == .indoor { return 0.6 }
        let length = fieldLengthMeters ?? 105
        let scale = (length / 105).squareRoot()
        return min(max(scale, 0.6), 1.0)
    }
}

/// One heart-rate reading. Fed to `WorkrateAnalyzer` so effort can be scored even when GPS is
/// sparse or absent (indoor play). Kept HealthKit-free; the app layer maps `HKQuantitySample`s
/// into these.
public struct HeartRateSample: Codable, Sendable {
    public var date: Date
    public var bpm: Double

    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}
