import Foundation

/// How measurements are shown. Storage and analytics are always metric.
public enum UnitSystem: String, CaseIterable, Codable, Sendable {
    case metric, imperial

    /// The region's convention: miles and mph in the US and UK, kilometers elsewhere.
    public static func preferred(for locale: Locale = .current) -> UnitSystem {
        locale.measurementSystem == .metric ? .metric : .imperial
    }

    /// Set by the app when the user overrides the region's convention.
    public nonisolated(unsafe) static var override: UnitSystem?

    public static var current: UnitSystem { override ?? preferred() }

    /// A number and its unit, kept apart so they can be styled differently.
    public struct Measure: Equatable, Sendable {
        public let value: String
        public let unit: String
        public var text: String { "\(value) \(unit)" }
        /// For VoiceOver: "2.7 miles", not "2.7 mi".
        public let spokenUnit: String
        public var spoken: String { "\(value) \(spokenUnit)" }
    }

    public func distance(_ meters: Double, locale: Locale = .current) -> Measure {
        switch self {
        case .metric:
            return Measure(value: Self.number(meters / 1000, fractionDigits: 2, locale: locale),
                           unit: "km", spokenUnit: "kilometers")
        case .imperial:
            return Measure(value: Self.number(meters / 1609.344, fractionDigits: 2, locale: locale),
                           unit: "mi", spokenUnit: "miles")
        }
    }

    public func speed(_ metersPerSecond: Double, locale: Locale = .current) -> Measure {
        switch self {
        case .metric:
            return Measure(value: Self.number(metersPerSecond * 3.6, fractionDigits: 1, locale: locale),
                           unit: "km/h", spokenUnit: "kilometers per hour")
        case .imperial:
            return Measure(value: Self.number(metersPerSecond * 2.236936, fractionDigits: 1, locale: locale),
                           unit: "mph", spokenUnit: "miles per hour")
        }
    }

    /// Short distances — runs, pitch dimensions. Yards in imperial, as pitches are marked.
    public func shortDistance(_ meters: Double, locale: Locale = .current) -> Measure {
        switch self {
        case .metric:
            return Measure(value: Self.number(meters, fractionDigits: 0, locale: locale),
                           unit: "m", spokenUnit: "meters")
        case .imperial:
            return Measure(value: Self.number(meters * 1.0936133, fractionDigits: 0, locale: locale),
                           unit: "yd", spokenUnit: "yards")
        }
    }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }
}

/// Guesses which format the next match will be: whatever was last played on this weekday, else
/// whatever was last played. League nights repeat, so this is right far more often than "last used".
public struct FormatHistory: Codable, Equatable, Sendable {
    private var byWeekday: [Int: MatchFormat] = [:]
    private var last: MatchFormat?

    public init() {}

    public mutating func record(_ format: MatchFormat, on date: Date, calendar: Calendar = .current) {
        byWeekday[calendar.component(.weekday, from: date)] = format
        last = format
    }

    public func predicted(on date: Date, calendar: Calendar = .current) -> MatchFormat {
        byWeekday[calendar.component(.weekday, from: date)] ?? last ?? .match
    }
}
