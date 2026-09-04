import Foundation
#if canImport(os)
import os
#endif

// MARK: - Diagnostics

/// Thin logging facade over `os.Logger` (with a `print` fallback where `os` is unavailable, e.g.
/// Linux CI).
///
/// - Important: NEVER pass raw GPS coordinates or health values (heart rate, calories, positions)
///   into these messages. Logs may be persisted to disk and read by others; match tracks and
///   biometrics stay out of them by contract.
public enum MatchLog {
    /// Shared subsystem for all MatchTracker logs.
    public static let subsystem = "com.nicemohawk.MatchTracker"

    public static func info(_ message: String, category: String) {
        #if canImport(os)
        logger(for: category).info("\(message, privacy: .public)")
        #else
        print("[\(subsystem)] [\(category)] INFO: \(message)")
        #endif
        journal(level: "info", category: category, message: message)
    }

    public static func error(_ message: String, category: String) {
        #if canImport(os)
        logger(for: category).error("\(message, privacy: .public)")
        #else
        print("[\(subsystem)] [\(category)] ERROR: \(message)")
        #endif
        journal(level: "error", category: category, message: message)
    }

    // MARK: - Persistent journal
    //
    // Every log line can additionally append to a rotating JSONL journal on disk, so a
    // diagnostic export carries the actual sequence of lifecycle events ("what happened this
    // morning") alongside the data. One line per event:
    //   {"t":"2026-07-17T12:09:58.123Z","d":"watch","l":"info","c":"workout","m":"..."}
    // Same privacy contract as the loggers: no coordinates, no biometrics.

    private struct JournalEntry: Encodable {
        let t: String
        let d: String
        let l: String
        let c: String
        let m: String
    }

    private nonisolated(unsafe) static var journalURL: URL?
    private nonisolated(unsafe) static var journalDeviceTag = ""
    private static let journalQueue = DispatchQueue(label: "com.nicemohawk.MatchTracker.journal",
                                                    qos: .utility)
    private static let journalTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    /// Rotation: when the journal grows past this, keep the newest half of `journalKeepLines`.
    private static let journalMaxBytes = 1_500_000
    private static let journalKeepLines = 4000

    /// Start journaling to `url`, tagging entries with `deviceTag` ("watch"/"phone"). Call once
    /// at app launch; rotates an oversized journal at that point.
    public static func enableJournal(at url: URL, deviceTag: String) {
        journalQueue.sync {
            journalURL = url
            journalDeviceTag = deviceTag
            rotateIfNeeded(url: url)
        }
        info("journal enabled", category: "journal")
    }

    /// Synchronous barrier so tests (and export) observe every entry logged before this call.
    public static func flushJournal() {
        journalQueue.sync { }
    }

    private static func journal(level: String, category: String, message: String) {
        journalQueue.async {
            guard let url = journalURL else { return }
            let entry = JournalEntry(t: journalTimestamp.string(from: Date()),
                                     d: journalDeviceTag, l: level, c: category, m: message)
            guard var data = try? JSONEncoder().encode(entry) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func rotateIfNeeded(url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > journalMaxBytes,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = contents.split(separator: "\n").suffix(journalKeepLines / 2)
        try? (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    #if canImport(os)
    // `os.Logger` is cheap but not free to construct; cache one per category behind a lock so the
    // facade is safe to call from any thread (recorder, upload queue, UI).
    private static let lock = NSLock()
    private nonisolated(unsafe) static var loggers: [String: Logger] = [:]

    private static func logger(for category: String) -> Logger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loggers[category] { return existing }
        let logger = Logger(subsystem: subsystem, category: category)
        loggers[category] = logger
        return logger
    }
    #endif
}
