//
//  VideoHighlightsSection.swift
//  MatchTracker
//

import SwiftUI
import AVKit
import PhotosUI
import MatchTrackerKit

/// Aligns match video with logged events: import a video shot during the match, correct clock
/// drift with a slider, then tap any flagged moment to seek straight to it.
struct VideoHighlightsSection: View {
    @ObservedObject var detail: MatchDetailModel
    let matchStart: Date

    @State private var pickerItem: PhotosPickerItem?
    @State private var player: AVPlayer?
    @State private var videoStart: Date?
    @State private var driftSeconds: Double = 0
    @State private var importError: String?

    private var events: [MatchEvent] {
        (detail.record?.events ?? []).filter { event in
            switch event.kind {
            case .flag, .goalForUs, .goalAgainstUs, .goalMine, .assist,
                 .yellowCard, .redCard, .foul:
                return true
            default:
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                driftControl
                highlightList
            } else {
                importPrompt
            }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: pickerItem) { _, item in
            Task { await importVideo(item) }
        }
    }

    private var importPrompt: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                Label("Import match video", systemImage: "video.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Text("Pick a video recorded during this match. Flagged moments become tappable highlights, aligned by the video's timestamp.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    /// Fine alignment: camera clocks drift, and recording rarely starts exactly at kickoff.
    private var driftControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Sync adjust: \(Int(driftSeconds)) s", systemImage: "clock.arrow.2.circlepath")
                .font(.caption)
            Slider(value: $driftSeconds, in: -120...120, step: 1)
        }
    }

    @ViewBuilder
    private var highlightList: some View {
        if events.isEmpty {
            Text("No flagged moments in this match.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Highlights").font(.headline).padding(.bottom, 4)
                ForEach(events) { event in
                    Button {
                        seek(to: event)
                    } label: {
                        HStack {
                            Image(systemName: event.kind.systemImage)
                                .foregroundStyle(event.kind.tint)
                            Text(event.kind.title)
                            if let note = event.note, !note.isEmpty {
                                Text(note).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(offsetString(for: event))
                                .monospacedDigit()
                                .foregroundStyle(seekable(event) ? Color.accentColor : .secondary)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 8)
                    }
                    .disabled(!seekable(event))
                    Divider()
                }
            }
        }
    }

    // MARK: - Video import & seeking

    private func importVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        importError = nil
        do {
            guard let video = try await item.loadTransferable(type: VideoFile.self) else {
                importError = "Couldn't load that video."
                return
            }
            player = AVPlayer(url: video.url)
            // Initial alignment: the asset's creation date vs kickoff; drift slider refines.
            let asset = AVURLAsset(url: video.url)
            if let creationDate = try? await asset.load(.creationDate),
               let date = try? await creationDate.load(.dateValue) {
                videoStart = date
            } else {
                videoStart = matchStart
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func videoOffset(for event: MatchEvent) -> TimeInterval? {
        guard let videoStart else { return nil }
        return event.date.timeIntervalSince(videoStart) + driftSeconds
    }

    private func seekable(_ event: MatchEvent) -> Bool {
        guard let offset = videoOffset(for: event) else { return false }
        return offset >= 0
    }

    private func seek(to event: MatchEvent) {
        guard let player, let offset = videoOffset(for: event), offset >= 0 else { return }
        // Land a few seconds early so the build-up to the moment is visible.
        let target = max(0, offset - 5)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        player.play()
    }

    private func offsetString(for event: MatchEvent) -> String {
        MatchTrackerFormat.hoursMinutesSeconds(max(0, event.date.timeIntervalSince(matchStart)))
    }
}

/// Transferable wrapper copying the picked video into our temp space for playback.
private struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("match-video-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return VideoFile(url: destination)
        }
    }
}
