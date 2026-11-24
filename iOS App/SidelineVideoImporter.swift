// SidelineVideoImporter.swift
// MatchTracker
//
// Photos <-> container IO for sideline footage: importing a picked movie (reading its creation
// date + duration and copying it into the store) and cutting a single event-anchored clip out of it.

import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import MatchTrackerKit

/// Transferable wrapper that copies a picked movie into a temp file we then own for inspection.
struct SidelineVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("sideline-import-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return SidelineVideoFile(url: destination)
        }
    }
}

enum SidelineVideoImporter {
    /// Read creation date + duration from a movie at `url`. Returns whether the creation date was
    /// real metadata (vs. absent) so callers know whether to prompt for manual alignment.
    static func inspect(_ url: URL) async -> (creationDate: Date?, duration: TimeInterval, hasReliableCreationDate: Bool) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        if let creationItem = try? await asset.load(.creationDate),
           let date = try? await creationItem.load(.dateValue) {
            return (date, duration, true)
        }
        return (nil, duration, false)
    }
}

/// Cuts a range out of a movie, into a file of its own.
enum SidelineClipExporter {
    struct ExportFailed: LocalizedError {
        let reason: String?
        var errorDescription: String? { reason ?? "The clip couldn’t be cut from its video." }
    }

    /// `start` and `end` are seconds into `source`.
    static func trim(_ source: URL, from start: TimeInterval, to end: TimeInterval) async throws -> URL {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportFailed(reason: nil) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        session.outputURL = output
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        // The async `export()` needs iOS 18.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else { throw ExportFailed(reason: session.error?.localizedDescription) }
        return output
    }
}
