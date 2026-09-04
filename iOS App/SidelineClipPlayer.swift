// SidelineClipPlayer.swift
// MatchTracker
//
// Full-screen playback of a single event-anchored clip. No export is needed to WATCH a clip — we
// seek an AVPlayer to the clip's start and stop it at the end via a boundary time observer. The
// "Save Clip" button is the only path that actually renders a file (via SidelineClipExporter).

import SwiftUI
import AVKit
import MatchTrackerKit

struct SidelineClipPlayer: View {
    let video: SidelineVideo
    let clip: SidelineClip
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var player = AVPlayer()
    @State private var boundaryObserver: Any?
    @State private var isFinished = false

    @State private var exportState: ExportState = .idle

    private enum ExportState: Equatable {
        case idle, exporting, saved, failed(String)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if isFinished { replayButton }
                Spacer()
                bottomBar
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: start)
        .onDisappear(perform: teardown)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            HStack(spacing: 10) {
                Image(systemName: clip.event.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(clip.event.kind.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.event.kind.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let note = clip.event.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
        }
    }

    private var replayButton: some View {
        Button(action: replay) {
            Label("Replay", systemImage: "gobackward")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .transition(.scale.combined(with: .opacity))
    }

    private var bottomBar: some View {
        HStack {
            Text(MatchTrackerFormat.hoursMinutesSeconds(clip.duration) + " clip")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            saveButton
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        switch exportState {
        case .idle, .failed:
            Button(action: saveClip) {
                Label("Save Clip", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Theme.turf, in: Capsule())
            }
            if case .failed(let message) = exportState {
                // Surface the reason inline, but keep the button tappable to retry.
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Theme.loss)
                    .lineLimit(2)
            }
        case .exporting:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Saving…").font(.subheadline).foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
        case .saved:
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.turf)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Playback control

    private func start() {
        let item = AVPlayerItem(url: fileURL)
        player.replaceCurrentItem(with: item)
        seekToStart(thenPlay: true)
        installBoundaryObserver()
    }

    private func seekToStart(thenPlay: Bool) {
        let target = CMTime(seconds: clip.startTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            if thenPlay { player.play() }
        }
    }

    private func installBoundaryObserver() {
        // Stop exactly at the clip's end rather than letting the whole recording run on.
        let end = NSValue(time: CMTime(seconds: clip.endTime, preferredTimescale: 600))
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [end], queue: .main) {
            player.pause()
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                isFinished = true
            }
        }
    }

    private func replay() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isFinished = false }
        seekToStart(thenPlay: true)
    }

    private func teardown() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
        player.pause()
    }

    // MARK: - Export

    private func saveClip() {
        exportState = .exporting
        Task {
            do {
                try await SidelineClipExporter.export(from: fileURL, start: clip.startTime, end: clip.endTime)
                await MainActor.run {
                    exportState = .saved
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    exportState = .failed(error.localizedDescription)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
        }
    }
}
