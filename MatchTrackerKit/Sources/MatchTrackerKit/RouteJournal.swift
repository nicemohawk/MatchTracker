import Foundation

// MARK: - Crash-safe route recording

/// One GPS fix with everything a HealthKit route needs to be rebuilt from disk.
public struct RouteFix: Codable, Hashable, Sendable {
    public var point: TrackPoint
    public var altitude: Double
    public var verticalAccuracy: Double    // negative if invalid

    public init(point: TrackPoint, altitude: Double, verticalAccuracy: Double) {
        self.point = point
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
    }
}

/// Append-only, per-match log of GPS fixes.
///
/// `HKWorkoutRouteBuilder` holds its data in the client process: if the app goes away before
/// `finishRoute`, everything inserted so far is lost, and a recovered workout starts over with an
/// empty route. This file is what survives. One JSON object per line, written as each fix lands,
/// so a killed process costs at most the line it was writing. Callers serialize access.
public final class RouteJournal {
    private let url: URL
    private var handle: FileHandle?

    public init(directory: URL, matchID: UUID) {
        url = directory.appendingPathComponent("route-\(matchID.uuidString).jsonl")
    }

    public func append(_ fixes: [RouteFix]) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for fix in fixes {
            data.append(try encoder.encode(fix))
            data.append(0x0A)
        }
        try openHandle().write(contentsOf: data)
    }

    /// Every intact fix on disk, in recorded order. A torn line is skipped, not fatal.
    public func load() -> [RouteFix] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(RouteFix.self, from: $0) }
    }

    public func remove() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let opened = try FileHandle(forUpdating: url)
        let end = try opened.seekToEnd()
        // A process killed mid-write leaves a torn last line; terminate it so the first fix after
        // a relaunch isn't glued onto it and lost too.
        if end > 0 {
            try opened.seek(toOffset: end - 1)
            let lastByte = try opened.read(upToCount: 1)
            try opened.seekToEnd()
            if lastByte != Data([0x0A]) { try opened.write(contentsOf: Data([0x0A])) }
        }
        handle = opened
        return opened
    }
}

// MARK: - Fix acceptance

/// Decides which fixes belong to a match's route.
public enum RouteFixFilter {
    /// Keeps usable fixes at or after `start` and strictly newer than `lastAccepted`.
    ///
    /// Core Location replays its cached fix whenever updates (re)start, which put pre-kickoff
    /// points on real routes; and every retry would otherwise duplicate points. Late delivery is
    /// fine — a queued fix carries the time it was taken.
    public static func accept(_ fixes: [RouteFix], start: Date, lastAccepted: Date?) -> [RouteFix] {
        var newest = lastAccepted ?? .distantPast
        return fixes.filter { fix in
            let accuracy = fix.point.horizontalAccuracy
            guard accuracy >= 0, accuracy <= TrackPoint.maximumUsableHorizontalAccuracy,
                  fix.point.timestamp >= start, fix.point.timestamp > newest else { return false }
            newest = fix.point.timestamp
            return true
        }
    }
}

// MARK: - Signal health

/// Tracks whether GPS is delivering, and when to ask for it again.
public struct GPSSignalMonitor: Sendable {
    public enum Signal: Sendable { case acquiring, good, lost }

    /// No usable fix for this long after having one means the signal is lost.
    public static let lostInterval: TimeInterval = 15
    /// First retry after this long with no callback at all; doubles up to `maximumRetryInterval`.
    public static let retryInterval: TimeInterval = 20
    public static let maximumRetryInterval: TimeInterval = 120

    private var startedAt: Date
    private var lastCallbackAt: Date?
    private var lastUsableAt: Date?
    private var lastRetryAt: Date?
    public private(set) var consecutiveRetries = 0

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    public mutating func recordCallback(at now: Date, usable: Bool) {
        lastCallbackAt = now
        consecutiveRetries = 0
        if usable { lastUsableAt = now }
    }

    public mutating func recordRetry(at now: Date) {
        lastRetryAt = now
        consecutiveRetries += 1
    }

    public func signal(at now: Date) -> Signal {
        guard let lastUsableAt else { return .acquiring }
        return now.timeIntervalSince(lastUsableAt) > Self.lostInterval ? .lost : .good
    }

    /// Seconds without a usable fix.
    public func silence(at now: Date) -> TimeInterval {
        now.timeIntervalSince(lastUsableAt ?? startedAt)
    }

    /// Whether to restart updates now. Only when Core Location has gone completely quiet: while it
    /// is still delivering fixes, however inaccurate, it is converging and a restart would set it
    /// back. `force` skips the backoff (the app just became active — the best moment to retry).
    public func shouldRetry(at now: Date, force: Bool = false) -> Bool {
        let quiet = now.timeIntervalSince(lastCallbackAt ?? startedAt)
        if force { return quiet > Self.lostInterval }
        let backoff = min(Self.retryInterval * pow(2, Double(consecutiveRetries)), Self.maximumRetryInterval)
        let sinceRetry = lastRetryAt.map { now.timeIntervalSince($0) } ?? .infinity
        return quiet >= Self.retryInterval && sinceRetry >= backoff
    }
}
