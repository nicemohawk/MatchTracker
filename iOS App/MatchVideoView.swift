// MatchVideoView.swift
// MatchTracker

import AVKit
import CoreTransferable
import MatchTrackerKit
import PhotosUI
import SwiftUI

/// A match's footage, cut into its moments: the watch already knows when they happened.
struct MatchVideoView: View {
    @ObservedObject var detail: MatchDetailModel
    @ObservedObject private var store = SidelineVideoStore.shared
    @Environment(LiveMatchStore.self) private var liveMatches

    @State private var pickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importFailure: String?
    @State private var clip: ClipSelection?
    @State private var liningUp: SidelineVideo?
    @State private var removing: SidelineVideo?
    @State private var isFilming = false

    private var videos: [SidelineVideo] { store.videos(for: detail.matchIdentifier) }
    private var moments: [MatchEvent] { detail.events.filter { MomentsChapter.isMoment($0.kind) } }

    var body: some View {
        List {
            if !videos.isEmpty {
                ForEach(videos) { video in section(for: video) }
                Section { sources }
            }
        }
        .overlay {
            if videos.isEmpty {
                ContentUnavailableView {
                    Label("Film the Match", systemImage: "video")
                } description: {
                    Text("Prop a phone by the touchline. Everything you flag on your watch becomes a clip.")
                } actions: {
                    Button("Film with This iPhone") { isFilming = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    sourcePicker
                }
            }
        }
        .navigationTitle("Video")
        .navigationBarTitleDisplayMode(.inline)
        .closeToolbar()
        .onChange(of: pickerItem) { _, item in
            if let item { Task { await add(item) } }
        }
        .alert("Couldn’t Add That Video", isPresented: Binding(get: { importFailure != nil }, set: { if !$0 { importFailure = nil } }),
               presenting: importFailure) { _ in } message: { Text($0) }
        .confirmationDialog("Remove this video?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { video in
            Button("Remove Video", role: .destructive) { withAnimation { store.remove(video) } }
        } message: { _ in
            Text("Its clips go with it. A video you chose from Photos stays in Photos.")
        }
        .sheet(item: $clip) { MomentClipView(selection: $0) }
        .sheet(item: $liningUp) { LineUpView(video: $0, moments: moments, matchStart: detail.matchStart) }
        .fullScreenCover(isPresented: $isFilming) {
            SidelineCameraView(preassociatedMatchID: detail.matchIdentifier,
                               liveStore: liveMatches.isLive ? liveMatches : nil)
        }
    }

    @ViewBuilder
    private func section(for video: SidelineVideo) -> some View {
        let clips = SidelineAlignment.clips(for: video, events: moments, matchStart: detail.matchStart)
        Section {
            ForEach(clips) { item in
                Button {
                    clip = ClipSelection(video: video, clip: item)
                } label: {
                    ClipRow(video: video, clip: item, minute: detail.minute(of: item.event))
                }
                .buttonStyle(.plain)
            }
            if !moments.isEmpty {
                Button("Line Up with the Match", systemImage: "timeline.selection") { liningUp = video }
            }
            Button("Remove Video", systemImage: "trash", role: .destructive) { removing = video }
                .tint(.red)
        } header: {
            Text(video.displayName + " · " + MatchTrackerFormat.hoursMinutesSeconds(video.duration))
        } footer: {
            if moments.isEmpty {
                Text("This match has no goals or flags yet. Add them and they become clips here.")
            } else if clips.isEmpty {
                Text("None of the match’s moments fall inside this video. If it was filmed at the match, line it up.")
            } else if !video.hasReliableCreationDate, video.manualOffsetSeconds == 0 {
                Text("This video doesn’t say when it was filmed, so it’s assumed to start at kickoff.")
            }
        }
    }

    @ViewBuilder
    private var sources: some View {
        Button("Film with This iPhone", systemImage: "video") { isFilming = true }
        sourcePicker
    }

    @ViewBuilder
    private var sourcePicker: some View {
        if isImporting {
            HStack(spacing: 12) {
                ProgressView()
                Text("Copying the video…").foregroundStyle(.secondary)
            }
        } else {
            PhotosPicker(selection: $pickerItem, matching: .videos, preferredItemEncoding: .current) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
        }
    }

    private func add(_ item: PhotosPickerItem) async {
        isImporting = true
        defer {
            isImporting = false
            pickerItem = nil
        }
        do {
            guard let file = try await item.loadTransferable(type: SidelineVideoFile.self) else {
                importFailure = "Photos couldn’t hand it over. If it’s in iCloud, download it first."
                return
            }
            let info = await SidelineVideoImporter.inspect(file.url)
            _ = try store.add(copyingFrom: file.url, matchID: detail.matchIdentifier,
                              creationDate: info.creationDate, duration: info.duration,
                              hasReliableCreationDate: info.hasReliableCreationDate)
            try? FileManager.default.removeItem(at: file.url)
        } catch {
            importFailure = error.localizedDescription
        }
    }
}

/// A clip with the video it comes from, so either can present the other.
struct ClipSelection: Identifiable {
    let video: SidelineVideo
    let clip: SidelineClip
    var id: UUID { clip.id }

    @MainActor
    static func of(_ event: MatchEvent, in detail: MatchDetailModel) -> ClipSelection? {
        for video in SidelineVideoStore.shared.videos(for: detail.matchIdentifier) {
            if let clip = SidelineAlignment.clips(for: video, events: [event], matchStart: detail.matchStart).first {
                return ClipSelection(video: video, clip: clip)
            }
        }
        return nil
    }
}

private struct ClipRow: View {
    let video: SidelineVideo
    let clip: SidelineClip
    let minute: Int

    @State private var thumbnail: UIImage?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 96, height: 54)
                    .overlay {
                        if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                    }
                    .overlay {
                        Image(systemName: "play.fill").foregroundStyle(.white).shadow(radius: 4)
                    }
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.event.kind.momentTitle).font(.headline)
                Text(clip.event.note.flatMap { $0.isEmpty ? nil : "\(minute)′ · \($0)" } ?? "\(minute)′")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.event.kind.momentTitle), minute \(minute)")
        .accessibilityHint("Plays the clip")
        .task(id: clip.anchorTime) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: SidelineVideoStore.shared.fileURL(for: video)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 300)
            thumbnail = (try? await generator.image(at: CMTime(seconds: clip.anchorTime, preferredTimescale: 600)))
                .map { UIImage(cgImage: $0.image) }
        }
    }
}

// MARK: - One clip

/// Plays one moment, over and over, and shares it as a file of its own.
struct MomentClipView: View {
    let selection: ClipSelection

    @State private var player = AVPlayer()
    @State private var boundary: Any?
    @Environment(\.dismiss) private var dismiss

    private var clip: SidelineClip { selection.clip }
    private var url: URL { SidelineVideoStore.shared.fileURL(for: selection.video) }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .background(.black)
                .navigationTitle(clip.event.kind.momentTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: ClipFile(source: url, start: clip.startTime, end: clip.endTime),
                                  preview: SharePreview(clip.event.kind.momentTitle))
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onAppear(perform: play)
        .onDisappear {
            player.pause()
            if let boundary { player.removeTimeObserver(boundary) }
            boundary = nil
        }
    }

    private func play() {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let start = CMTime(seconds: clip.startTime, preferredTimescale: 600)
        let end = NSValue(time: CMTime(seconds: clip.endTime, preferredTimescale: 600))
        boundary = player.addBoundaryTimeObserver(forTimes: [end], queue: .main) { [weak player] in
            player?.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

/// Cut from the recording only when it's actually shared.
struct ClipFile: Transferable {
    let source: URL
    let start: TimeInterval
    let end: TimeInterval

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .quickTimeMovie) { file in
            SentTransferredFile(try await SidelineClipExporter.trim(file.source, from: file.start, to: file.end))
        }
    }
}

// MARK: - Lining up

/// Says where one moment is in the footage, and so where all of them are.
private struct LineUpView: View {
    let video: SidelineVideo
    let moments: [MatchEvent]
    let matchStart: Date

    @State private var momentID: UUID?
    @State private var player = AVPlayer()
    @Environment(\.dismiss) private var dismiss

    private var moment: MatchEvent? { moments.first { $0.id == momentID } ?? moments.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                Picker("Moment", selection: $momentID) {
                    ForEach(moments) { event in
                        Text("\(event.kind.momentTitle), \(max(1, Int(event.date.timeIntervalSince(matchStart) / 60) + 1))′")
                            .tag(UUID?.some(event.id))
                    }
                }
                .pickerStyle(.menu)
                Text("Find this moment in the video and stop on it. The other clips follow.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Spacer(minLength: 0)
                Button {
                    lineUp()
                    dismiss()
                } label: {
                    Text("It Happens Here").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
            .navigationTitle("Line Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            momentID = moments.first { isInside($0) }?.id ?? moments.first?.id
            player.replaceCurrentItem(with: AVPlayerItem(url: SidelineVideoStore.shared.fileURL(for: video)))
        }
        .onChange(of: momentID) { seek() }
        .onDisappear { player.pause() }
    }

    private func time(of event: MatchEvent) -> TimeInterval {
        SidelineAlignment.playbackTime(for: event.date, video: video, matchStart: matchStart)
    }

    private func isInside(_ event: MatchEvent) -> Bool {
        SidelineAlignment.isInRange(time(of: event), duration: video.duration)
    }

    private func seek() {
        guard let moment else { return }
        let seconds = min(max(time(of: moment), 0), video.duration)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func lineUp() {
        guard let moment else { return }
        let shift = player.currentTime().seconds - time(of: moment)
        guard shift.isFinite else { return }
        SidelineVideoStore.shared.setManualOffset(video.manualOffsetSeconds + shift, for: video)
    }
}
