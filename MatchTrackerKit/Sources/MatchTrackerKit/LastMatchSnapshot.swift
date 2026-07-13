import Foundation

/// Compact post-match summary the watch app writes to the app group after every finished match.
/// Read by the widget extension for the last-match Smart Stack card; kept deliberately tiny and
/// self-contained so the widget never needs HealthKit or the full analytics pipeline.
public struct LastMatchSnapshot: Codable, Sendable {
    public var matchID: UUID
    public var endDate: Date
    public var fieldName: String?
    public var durationSeconds: TimeInterval
    public var timeOnPitchSeconds: TimeInterval
    public var distanceMeters: Double
    public var goalsUs: Int
    public var goalsThem: Int
    public var sprintCount: Int

    public init(matchID: UUID, endDate: Date, fieldName: String?, durationSeconds: TimeInterval,
                timeOnPitchSeconds: TimeInterval, distanceMeters: Double, goalsUs: Int,
                goalsThem: Int, sprintCount: Int) {
        self.matchID = matchID
        self.endDate = endDate
        self.fieldName = fieldName
        self.durationSeconds = durationSeconds
        self.timeOnPitchSeconds = timeOnPitchSeconds
        self.distanceMeters = distanceMeters
        self.goalsUs = goalsUs
        self.goalsThem = goalsThem
        self.sprintCount = sprintCount
    }

    /// Canonical location inside the app-group container.
    public static func fileURL(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent("last-match-snapshot.json")
    }

    public static func load(from containerURL: URL) -> LastMatchSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(in: containerURL)) else { return nil }
        return try? MatchTrackerJSON.decoder().decode(LastMatchSnapshot.self, from: data)
    }

    public func save(to containerURL: URL) throws {
        let data = try MatchTrackerJSON.encoder().encode(self)
        try data.write(to: Self.fileURL(in: containerURL), options: .atomic)
    }
}
