// SidelineVideoImporter.swift
// MatchTracker
//
// Photos <-> container IO for sideline footage: importing a picked movie (reading its creation
// date + duration and copying it into the store) and exporting a single event-anchored clip back
// out to the user's photo library (add-only) via AVAssetExportSession.

import Foundation
import AVFoundation
import CoreTransferable
import Photos
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

/// Errors surfaced by the clip exporter.
enum SidelineExportError: LocalizedError {
    case notAuthorized
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "MatchTracker needs permission to add the clip to your photo library. Enable it in Settings › Photos."
        case .exportFailed(let reason):
            return "Couldn't export the clip: \(reason)"
        }
    }
}

/// Trims a time range out of a source movie and saves it to the photo library (add-only).
enum SidelineClipExporter {
    /// Export `range` (seconds) from `sourceURL` and save the trimmed clip to Photos. Requests
    /// add-only authorization; throws `SidelineExportError` on denial or failure.
    static func export(from sourceURL: URL,
                       start: TimeInterval,
                       end: TimeInterval) async throws {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            throw SidelineExportError.notAuthorized
        }

        let asset = AVURLAsset(url: sourceURL)
        let preset = AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw SidelineExportError.exportFailed("unsupported format")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sideline-clip-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: outputURL)

        let timescale: CMTimeScale = 600
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: timescale)
        let endTime = CMTime(seconds: end, preferredTimescale: timescale)
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(start: startTime, end: endTime)

        try await runExport(session)

        try await save(outputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// iOS 17-compatible export (the parameterless async `export()` is iOS 18+).
    private static func runExport(_ session: AVAssetExportSession) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            let reason = session.error?.localizedDescription ?? "export incomplete"
            throw SidelineExportError.exportFailed(reason)
        }
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func save(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SidelineExportError.exportFailed(error?.localizedDescription ?? "save failed"))
                }
            }
        }
    }
}
