// SidelineCameraView.swift
// MatchTracker
//
// Phase 2 sideline capture UI: a full-screen dark camera for filming the match from the touchline.
// Because the recording stamps its exact wall-clock start (see SidelineCameraController), the clip
// aligns to the watch's tagged events with ZERO nudge — the timeline is correct by construction.
//
// When a match is live, the filmer sees the watch's tags land in real time as chips sliding in, so
// they know the moment they just filmed is already anchored. On stop the clip saves to the
// pre-associated match if there is one, otherwise a recent-matches picker resolves the target.

import SwiftUI
import AVFoundation
import MatchTrackerKit

struct SidelineCameraView: View {
    /// When set, the recording saves straight to this match (the live dashboard and a match's own
    /// video section both pass an id). When nil, the recent-matches picker resolves the target.
    var preassociatedMatchID: UUID?
    /// The live feed when a match is in progress, so watch-tagged events can stream into the ticker.
    var liveStore: LiveMatchStore?

    @EnvironmentObject private var matchStore: MatchStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var controller = SidelineCameraController()
    @ObservedObject private var videoStore = SidelineVideoStore.shared

    @State private var isPortrait = true
    @State private var pendingClip: RecordedSidelineClip?
    @State private var savedConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch controller.availability {
            case .unavailable(let reason):
                unavailableState(reason)
            default:
                cameraSurface
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .background(orientationReader)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .onChange(of: controller.finishedClip?.id) { _, _ in
            guard let clip = controller.finishedClip else { return }
            controller.finishedClip = nil
            route(clip)
        }
        .sheet(item: $pendingClip) { clip in
            MatchPickerSheet(
                matches: Array(matchStore.matches.prefix(5)),
                onPick: { matchID in
                    save(clip, to: matchID)
                    pendingClip = nil
                },
                onDiscard: {
                    discard(clip)
                    pendingClip = nil
                    dismiss()
                }
            )
            .presentationDetents([.medium])
        }
    }

    // MARK: - Camera surface

    private var cameraSurface: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            // Dim scrim so white chrome stays legible over bright turf.
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topChrome
                Spacer()
                if isPortrait { landscapeHint }
                Spacer()
                bottomChrome
            }
            .padding()

            if liveStore?.isLive == true {
                eventTicker
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 96)
                    .padding(.horizontal)
                    .allowsHitTesting(false)
            }

            if savedConfirmation { savedToast }
        }
    }

    // MARK: - Top chrome (timer + close)

    private var topChrome: some View {
        ZStack {
            elapsedTimer
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                closeButton
                Spacer()
                statusBadges
            }
        }
    }

    private var elapsedTimer: some View {
        Group {
            if let startedAt = controller.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                    HStack(spacing: 8) {
                        Circle().fill(Theme.loss).frame(width: 9, height: 9)
                            .opacity(reduceMotion ? 1 : (Int(elapsed * 2) % 2 == 0 ? 1 : 0.25))
                        Text(MatchTrackerFormat.hoursMinutesSeconds(elapsed))
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            } else {
                Text("Ready")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(controller.isRecording)
        .opacity(controller.isRecording ? 0.35 : 1)
        .accessibilityLabel("Close camera")
    }

    private var statusBadges: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if controller.isStorageLow {
                warningBadge("Storage low", systemImage: "externaldrive.badge.exclamationmark")
            }
            if controller.isThermalPressureHigh {
                warningBadge("Device hot", systemImage: "thermometer.high")
            }
        }
    }

    private func warningBadge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.sprint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Bottom chrome (record button)

    private var bottomChrome: some View {
        VStack(spacing: 14) {
            if let error = controller.recordingError {
                Text(error)
                    .font(.caption).foregroundStyle(Theme.loss)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            recordButton
            Text(controller.isRecording ? "Tap to stop" : "Tap to record the match")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 4)
                    .frame(width: 72, height: 72)

                if controller.isRecording {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.loss)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Theme.loss)
                        .frame(width: 58, height: 58)
                }

                if controller.isRecording && !reduceMotion {
                    RecordingRing()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Live event ticker

    private var eventTicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tickerEvents) { event in
                HStack(spacing: 8) {
                    Image(systemName: event.kind.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(event.kind.tint)
                    Text(event.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(tickerTimestamp(event))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.chipStroke(event.kind.tint), lineWidth: 1))
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8),
                   value: tickerEvents.map(\.id))
    }

    /// Newest few watch-tagged events, freshest first, so the just-tagged chip springs in on top.
    private var tickerEvents: [MatchEvent] {
        guard let liveStore else { return [] }
        return Array(liveStore.events.suffix(3).reversed())
    }

    /// Elapsed match time of an event ("12:03"), derived from the live feed's own clock so the
    /// filmer reads it the same way the watch shows it. Falls back to wall-clock time.
    private func tickerTimestamp(_ event: MatchEvent) -> String {
        if let update = liveStore?.latest {
            let matchStart = update.timestamp.addingTimeInterval(-update.elapsed)
            let elapsed = event.date.timeIntervalSince(matchStart)
            if elapsed >= 0 { return MatchTrackerFormat.hoursMinutesSeconds(elapsed) }
        }
        return event.date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Landscape hint

    private var landscapeHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "rotate.right.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.signal)
                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
            Text("Rotate to landscape")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("Soccer films best wide — turn your phone sideways for the full pitch.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 40)
        .transition(.opacity)
    }

    // MARK: - Unavailable / toast

    private func unavailableState(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.signal)
            Text("Camera unavailable")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.signal, in: Capsule())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var savedToast: some View {
        Label("Saved to match", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.turf, in: Capsule())
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Actions

    private func toggleRecording() {
        Haptics.impact(.medium)
        if controller.isRecording {
            controller.stopRecording()
        } else {
            controller.startRecording()
        }
    }

    /// Resolve a stopped clip's destination: the pre-associated match if set, otherwise let the
    /// filmer pick (or auto-save to the single obvious recent match).
    private func route(_ clip: RecordedSidelineClip) {
        if let preassociatedMatchID {
            save(clip, to: preassociatedMatchID)
        } else {
            pendingClip = clip   // presents the picker sheet
        }
    }

    private func save(_ clip: RecordedSidelineClip, to matchID: UUID) {
        do {
            _ = try videoStore.add(
                copyingFrom: clip.url,
                matchID: matchID,
                creationDate: clip.startedAt,
                duration: clip.duration,
                hasReliableCreationDate: true
            )
            try? FileManager.default.removeItem(at: clip.url)
            Haptics.impact(.rigid)
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                savedConfirmation = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
        } catch {
            controller.recordingError = error.localizedDescription
            discard(clip)
        }
    }

    private func discard(_ clip: RecordedSidelineClip) {
        try? FileManager.default.removeItem(at: clip.url)
    }

    private var orientationReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { isPortrait = proxy.size.height >= proxy.size.width }
                .onChange(of: proxy.size.height >= proxy.size.width) { _, newValue in
                    isPortrait = newValue
                }
        }
    }
}

// MARK: - Recording ring animation

/// A slim rotating arc around the record button while filming — the "we're rolling" cue.
private struct RecordingRing: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(Theme.loss, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: 84, height: 84)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

// MARK: - Camera preview

/// UIKit bridge for the live camera preview layer.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Match picker (post-hoc association)

/// Recent-matches picker shown when a stopped clip has no pre-associated match. Lists the five most
/// recent matches; picking one saves the footage against it (alignment stays nudge-free via the
/// clip's exact creation date).
private struct MatchPickerSheet: View {
    let matches: [MatchSummary]
    let onPick: (UUID) -> Void
    let onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if matches.isEmpty {
                    ContentUnavailableView(
                        "No matches yet",
                        systemImage: "sportscourt",
                        description: Text("This footage needs a match to attach to. Once your watch logs a match, record again and pick it here.")
                    )
                } else {
                    List(matches) { match in
                        Button {
                            onPick(match.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "film")
                                    .foregroundStyle(Theme.signal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.startDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline.weight(.semibold))
                                    Text(MatchTrackerFormat.hoursMinutesSeconds(match.duration) + " match")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Save to match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { onDiscard() }
                }
            }
        }
    }
}
