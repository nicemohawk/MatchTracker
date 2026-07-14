//
//  VideoHighlightsSection.swift
//  MatchTracker
//

import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import MatchTrackerKit

/// Sideline-video MVP. Our wedge over camera-AI products (Veo): the watch already tagged every
/// moment live, so imported sideline footage auto-clips around those precise event timestamps with
/// zero AI. Import one or more recordings, align each to the match clock (creation-date offset,
/// refined by a manual nudge), then tap any event to watch its clip and save it to Photos.
struct VideoHighlightsSection: View {
    @ObservedObject var detail: MatchDetailModel
    let matchStart: Date

    @ObservedObject private var store = SidelineVideoStore.shared

    @State private var pickerItem: PhotosPickerItem?
    @State private var importState: ImportState = .idle
    @State private var selectedClip: ClipSelection?
    @State private var aligningVideo: SidelineVideo?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ImportState: Equatable {
        case idle, importing, failed(String)
    }

    /// The event kinds worth clipping — moments a viewer actually wants to relive.
    private var events: [MatchEvent] {
        (detail.record?.events ?? []).filter { event in
            switch event.kind {
            case .flag, .goalForUs, .goalAgainstUs, .goalMine, .assist,
                 .yellowCard, .redCard, .foul, .subIn, .subOut:
                return true
            default:
                return false
            }
        }
    }

    private var videos: [SidelineVideo] { store.videos(for: detail.matchIdentifier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderBar(
                title: "Sideline Video",
                tint: Theme.signal,
                subtitle: "Your watch tagged the moments — footage clips itself around them."
            )

            if videos.isEmpty {
                inviteCard
            } else {
                ForEach(videos) { video in
                    videoCard(video)
                }
                addMoreButton
            }

            if case .failed(let message) = importState {
                Text(message).font(.caption).foregroundStyle(Theme.loss)
            }
        }
        .onChange(of: pickerItem) { _, item in
            Task { await importVideo(item) }
        }
        .sheet(item: $selectedClip) { selection in
            SidelineClipPlayer(
                video: selection.video,
                clip: selection.clip,
                fileURL: store.fileURL(for: selection.video)
            )
        }
        .sheet(item: $aligningVideo) { video in
            SidelineAlignmentView(
                video: video,
                events: events,
                matchStart: matchStart,
                fileURL: store.fileURL(for: video),
                store: store
            )
            .presentationDetents([.large])
        }
    }

    // MARK: - Empty / invite state

    private var inviteCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(Theme.signal)
            Text("Film from the sideline")
                .font(.headline)
            Text("Prop your phone on the touchline and record the match. Your watch already tagged the goals, cards and flags — import the footage and MatchTracker clips each moment automatically. No AI, no editing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            importPicker(label: "Import Sideline Video", prominent: true)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .themedCard()
    }

    // MARK: - Per-video card

    @ViewBuilder
    private func videoCard(_ video: SidelineVideo) -> some View {
        let clips = SidelineAlignment.clips(for: video, events: events, matchStart: matchStart)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "film")
                    .foregroundStyle(Theme.signal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(video.displayName).font(.subheadline.weight(.semibold))
                    Text(MatchTrackerFormat.hoursMinutesSeconds(video.duration) + " • \(clips.count) clip\(clips.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        aligningVideo = video
                    } label: {
                        Label("Adjust sync", systemImage: "clock.arrow.2.circlepath")
                    }
                    Button(role: .destructive) {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                            store.remove(video)
                        }
                    } label: {
                        Label("Remove video", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }

            if !video.hasReliableCreationDate {
                alignmentPrompt(video, reason: "This clip had no timestamp, so we lined it up to kickoff. Nudge it so a known moment matches the footage.")
            }

            if clips.isEmpty {
                if events.isEmpty {
                    Text("No tagged events in this match yet — tag moments in the Events tab and they'll appear here as clips.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    alignmentPrompt(video, reason: "None of this match's tagged moments fall inside this recording. If the footage does cover them, adjust the sync to line it up.")
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(clips) { clip in
                        clipCard(video: video, clip: clip)
                    }
                }
            }
        }
        .padding(18)
        .themedCard()
    }

    private func alignmentPrompt(_ video: SidelineVideo, reason: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.sprint)
            VStack(alignment: .leading, spacing: 8) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                Button {
                    aligningVideo = video
                } label: {
                    Label("Adjust sync", systemImage: "clock.arrow.2.circlepath")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.signal)
            }
        }
        .padding(12)
        .background(Theme.chipFill(Theme.sprint), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func clipCard(video: SidelineVideo, clip: SidelineClip) -> some View {
        Button {
            Haptics.selection()
            selectedClip = ClipSelection(video: video, clip: clip)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: clip.event.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(clip.event.kind.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.event.kind.title).font(.subheadline.weight(.semibold))
                    if let note = clip.event.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text("\(matchMinute(clip.event))'")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(clip.event.kind.tint)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .metricTile(tint: clipTint(clip))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import controls

    private var addMoreButton: some View {
        importPicker(label: "Import another recording", prominent: false)
    }

    @ViewBuilder
    private func importPicker(label: String, prominent: Bool) -> some View {
        if importState == .importing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Importing…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            let picker = PhotosPicker(selection: $pickerItem, matching: .videos, preferredItemEncoding: .current) {
                Label(label, systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(Theme.signal)
            if prominent {
                picker.buttonStyle(.borderedProminent)
            } else {
                picker.buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Actions

    private func matchMinute(_ event: MatchEvent) -> Int {
        max(0, Int(event.date.timeIntervalSince(matchStart) / 60))
    }

    /// Tile tint for a clip card — the event's semantic hue, falling back to the section's signal
    /// tint for kinds that carry the neutral default (subs, fouls, turnovers).
    private func clipTint(_ clip: SidelineClip) -> Color {
        switch clip.event.kind {
        case .goalForUs, .goalMine, .goalAgainstUs, .assist, .flag, .yellowCard, .redCard:
            return clip.event.kind.tint
        default:
            return Theme.signal
        }
    }

    private func importVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        importState = .importing
        do {
            guard let file = try await item.loadTransferable(type: SidelineVideoFile.self) else {
                importState = .failed("Couldn't load that video.")
                return
            }
            let info = await SidelineVideoImporter.inspect(file.url)
            _ = try store.add(
                copyingFrom: file.url,
                matchID: detail.matchIdentifier,
                creationDate: info.creationDate,
                duration: info.duration,
                hasReliableCreationDate: info.hasReliableCreationDate
            )
            try? FileManager.default.removeItem(at: file.url)
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
                importState = .idle
            }
            pickerItem = nil
        } catch {
            importState = .failed(error.localizedDescription)
        }
    }
}

/// Identifiable pairing so a tapped clip can drive a `.sheet(item:)`.
private struct ClipSelection: Identifiable {
    let video: SidelineVideo
    let clip: SidelineClip
    var id: UUID { clip.id }
}

/// Manual alignment: nudge a video's offset (±5 min slider + ±1 s fine buttons) while previewing
/// the frame the chosen event lands on, so the user can line "my goal" up with the actual goal.
private struct SidelineAlignmentView: View {
    let video: SidelineVideo
    let events: [MatchEvent]
    let matchStart: Date
    let fileURL: URL
    @ObservedObject var store: SidelineVideoStore

    @Environment(\.dismiss) private var dismiss
    @State private var draftOffset: Double
    @State private var previewEvent: MatchEvent?
    @State private var previewImage: UIImage?
    private let generator: AVAssetImageGenerator

    init(video: SidelineVideo, events: [MatchEvent], matchStart: Date, fileURL: URL, store: SidelineVideoStore) {
        self.video = video
        self.events = events
        self.matchStart = matchStart
        self.fileURL = fileURL
        self.store = store
        _draftOffset = State(initialValue: video.manualOffsetSeconds)
        _previewEvent = State(initialValue: events.first)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
        self.generator = generator
    }

    private var baseStart: Date { video.creationDate ?? matchStart }

    private var previewTime: TimeInterval {
        guard let previewEvent else { return 0 }
        let raw = previewEvent.date.timeIntervalSince(baseStart) + draftOffset
        return min(max(0, raw), video.duration)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    previewFrame
                    if events.count > 1 { eventPicker }
                    nudgeControls
                    Text("Slide until the frame matches a moment you remember, then save. Every clip re-derives from this offset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .readableWidth()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Adjust Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setManualOffset(draftOffset, for: video)
                        Haptics.selection()
                        dismiss()
                    }
                }
            }
            .task(id: previewKey) { await regenerate() }
        }
    }

    /// Recompute the preview only when the target time or event actually changes.
    private var previewKey: String { "\(previewEvent?.id.uuidString ?? "none")-\(Int(previewTime * 4))" }

    private var previewFrame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black)
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
            if let previewEvent {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: previewEvent.kind.systemImage)
                            .foregroundStyle(previewEvent.kind.tint)
                        Text(previewEvent.kind.title).font(.caption.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        Text(MatchTrackerFormat.hoursMinutesSeconds(previewTime))
                            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(10)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private var eventPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line up against").captionLabel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(events) { event in
                        let isSelected = previewEvent?.id == event.id
                        Button {
                            previewEvent = event
                        } label: {
                            Label(event.kind.title, systemImage: event.kind.systemImage)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).frame(minHeight: 36)
                                .background(Capsule().fill(isSelected ? Theme.chipFill(Theme.signal) : Theme.surfaceElevated))
                                .overlay(Capsule().strokeBorder(isSelected ? Theme.chipStroke(Theme.signal) : Theme.surfaceStroke, lineWidth: 1))
                                .foregroundStyle(isSelected ? Theme.signal : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var nudgeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Offset").captionLabel()
                Spacer()
                Text(offsetLabel).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.signal)
            }
            Slider(value: $draftOffset, in: -300...300, step: 1)
                .tint(Theme.signal)
            HStack(spacing: 12) {
                fineButton(label: "-1s", systemImage: "minus") { draftOffset = max(-300, draftOffset - 1) }
                fineButton(label: "+1s", systemImage: "plus") { draftOffset = min(300, draftOffset + 1) }
                Spacer()
                Button("Reset") { draftOffset = 0 }
                    .font(.caption).tint(.secondary)
            }
        }
    }

    private func fineButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            action(); Haptics.selection()
        } label: {
            Label(label, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).frame(minHeight: 40)
        }
        .buttonStyle(.bordered)
        .tint(Theme.signal)
    }

    private var offsetLabel: String {
        let sign = draftOffset >= 0 ? "+" : "-"
        return sign + MatchTrackerFormat.hoursMinutesSeconds(abs(draftOffset))
    }

    private func regenerate() async {
        let cmTime = CMTime(seconds: previewTime, preferredTimescale: 600)
        guard let result = try? await generator.image(at: cmTime) else { return }
        let image = UIImage(cgImage: result.image)
        await MainActor.run { previewImage = image }
    }
}

