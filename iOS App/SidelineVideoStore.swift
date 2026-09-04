// SidelineVideoStore.swift
// MatchTracker
//
// Persistence + timeline math for imported sideline footage.
//
// STORAGE CHOICE — security-scoped copy into the app-group container (not a PHAsset
// localIdentifier reference). Rationale: PhotosPicker hands us a transferable file without
// requiring full photo-library read authorization, and resolving a PHAsset later would need
// that authorization AND could break if the user deletes/edits the original in Photos. Copying
// the file into our container makes the association durable and self-contained — the video is
// always there for playback and clip export. The trade-off (extra disk use) is acceptable for
// an MVP; a future phase could offer to reference-in-place for large libraries.

import Foundation
import MatchTrackerKit

/// One imported sideline recording associated with a match. Persisted as JSON; the movie file
/// itself lives alongside the index in `SidelineVideoStore.videosDirectory`, named by `id`.
struct SidelineVideo: Codable, Identifiable, Hashable {
    let id: UUID
    let matchID: UUID
    /// File name (not full path) of the copied movie within `videosDirectory`.
    var fileName: String
    /// Wall-clock time of the first frame, read from the asset's creation metadata. Nil when the
    /// asset carried no creation date (older exports, some screen recordings) — alignment then
    /// falls back to match start and the manual nudge does the real work.
    var creationDate: Date?
    /// Full duration of the recording in seconds.
    var duration: TimeInterval
    /// User's manual alignment nudge, in seconds, ADDED to the metadata-derived playback position
    /// for every event. Positive shifts clips later into the footage.
    var manualOffsetSeconds: Double
    var importedAt: Date

    /// Whether `creationDate` came from real asset metadata (true) or we fell back to match start
    /// (false). Drives the "please line this up" nudge prompt in the UI.
    var hasReliableCreationDate: Bool

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        if let creationDate {
            return formatter.string(from: creationDate)
        }
        return "Imported clip"
    }
}

/// A derived, event-anchored clip window within a video. Playback-only (no export until the user
/// asks): `startTime`/`endTime` are seconds into the recording.
struct SidelineClip: Identifiable, Hashable {
    let event: MatchEvent
    /// Seconds into the video where the event itself lands.
    let anchorTime: TimeInterval
    let startTime: TimeInterval
    let endTime: TimeInterval

    var id: UUID { event.id }
    var duration: TimeInterval { max(0, endTime - startTime) }
}

/// Pure timeline math shared by the section, the nudge UI, and clip derivation. Kept free of any
/// view state so the alignment behavior is easy to reason about (and unit-testable later).
enum SidelineAlignment {
    /// Pre/post roll windows around an anchored event. Goals get a longer run-up so the build-up
    /// is visible; everything else uses the standard lead-in.
    static let goalPreRoll: TimeInterval = 12
    static let standardPreRoll: TimeInterval = 8
    static let postRoll: TimeInterval = 6

    static func isGoal(_ kind: MatchEventKind) -> Bool {
        switch kind {
        case .goalForUs, .goalAgainstUs, .goalMine: return true
        default: return false
        }
    }

    /// The wall-clock instant that corresponds to playback position 0 in the video, before the
    /// manual nudge. Falls back to match start when the asset had no creation date.
    static func baseStart(for video: SidelineVideo, matchStart: Date) -> Date {
        video.creationDate ?? matchStart
    }

    /// Where an event lands in the recording, in seconds, after applying the manual nudge.
    static func playbackTime(for eventDate: Date, video: SidelineVideo, matchStart: Date) -> TimeInterval {
        eventDate.timeIntervalSince(baseStart(for: video, matchStart: matchStart)) + video.manualOffsetSeconds
    }

    /// True when the event actually falls inside the recorded footage (with a small grace so an
    /// event a hair before frame 0 still yields a clip clamped to the start).
    static func isInRange(_ playbackTime: TimeInterval, duration: TimeInterval) -> Bool {
        playbackTime >= -postRoll && playbackTime <= duration
    }

    /// Derive event-anchored clips for a video from the match's events, in chronological order.
    static func clips(for video: SidelineVideo, events: [MatchEvent], matchStart: Date) -> [SidelineClip] {
        events
            .sorted { $0.date < $1.date }
            .compactMap { event in
                let anchor = playbackTime(for: event.date, video: video, matchStart: matchStart)
                guard isInRange(anchor, duration: video.duration) else { return nil }
                let preRoll = isGoal(event.kind) ? goalPreRoll : standardPreRoll
                let start = max(0, anchor - preRoll)
                let end = min(video.duration, anchor + postRoll)
                guard end > start else { return nil }
                return SidelineClip(event: event, anchorTime: max(0, anchor), startTime: start, endTime: end)
            }
    }
}

/// Durable, observable store of sideline videos keyed by match UUID. A single JSON index plus one
/// movie file per video, all inside the app-group container.
@MainActor
final class SidelineVideoStore: ObservableObject {
    @Published private(set) var videosByMatch: [UUID: [SidelineVideo]] = [:]

    static let shared = SidelineVideoStore()

    /// Directory holding the index and every copied movie.
    static var videosDirectory: URL {
        let url = AppGroup.containerURL.appendingPathComponent("SidelineVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var indexURL: URL {
        videosDirectory.appendingPathComponent("index.json")
    }

    init() {
        load()
    }

    func videos(for matchID: UUID) -> [SidelineVideo] {
        (videosByMatch[matchID] ?? []).sorted { $0.importedAt < $1.importedAt }
    }

    /// Absolute location of the copied movie for playback / export.
    func fileURL(for video: SidelineVideo) -> URL {
        Self.videosDirectory.appendingPathComponent(video.fileName)
    }

    /// Copy a transferred movie into the container and record the association. `sourceURL` is a
    /// temporary file (e.g. the PhotosPicker transfer); we own the copy afterward.
    func add(copyingFrom sourceURL: URL,
             matchID: UUID,
             creationDate: Date?,
             duration: TimeInterval,
             hasReliableCreationDate: Bool) throws -> SidelineVideo {
        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let destination = Self.videosDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let video = SidelineVideo(
            id: id,
            matchID: matchID,
            fileName: fileName,
            creationDate: creationDate,
            duration: duration,
            manualOffsetSeconds: 0,
            importedAt: Date(),
            hasReliableCreationDate: hasReliableCreationDate
        )
        videosByMatch[matchID, default: []].append(video)
        persist()
        return video
    }

    /// Update the manual alignment nudge for a video.
    func setManualOffset(_ seconds: Double, for video: SidelineVideo) {
        mutate(video) { $0.manualOffsetSeconds = seconds }
    }

    /// Remove a video and delete its copied file.
    func remove(_ video: SidelineVideo) {
        try? FileManager.default.removeItem(at: fileURL(for: video))
        videosByMatch[video.matchID]?.removeAll { $0.id == video.id }
        if videosByMatch[video.matchID]?.isEmpty == true {
            videosByMatch[video.matchID] = nil
        }
        persist()
    }

    // MARK: - Private

    private func mutate(_ video: SidelineVideo, _ change: (inout SidelineVideo) -> Void) {
        guard var list = videosByMatch[video.matchID],
              let index = list.firstIndex(where: { $0.id == video.id }) else { return }
        change(&list[index])
        videosByMatch[video.matchID] = list
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        guard let decoded = try? JSONDecoder.sidelineDates.decode([SidelineVideo].self, from: data) else {
            MatchLog.error("Failed to decode sideline video index", category: "SidelineVideo")
            return
        }
        videosByMatch = Dictionary(grouping: decoded, by: \.matchID)
    }

    private func persist() {
        let flattened = videosByMatch.values.flatMap { $0 }
        do {
            let data = try JSONEncoder.sidelineDates.encode(flattened)
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            MatchLog.error("Failed to persist sideline video index", category: "SidelineVideo")
        }
    }
}

private extension JSONEncoder {
    static var sidelineDates: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var sidelineDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
