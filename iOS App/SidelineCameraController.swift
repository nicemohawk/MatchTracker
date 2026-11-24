// SidelineCameraController.swift
// MatchTracker
//
// Phase 2 of sideline video: in-app capture. This controller owns the AVCaptureSession (back
// camera, 1080p, audio) and an AVCaptureMovieFileOutput that writes into a temp file inside the
// SidelineVideos container directory. The whole point of capturing in-app is a ZERO-NUDGE timeline:
// we stamp the EXACT wall-clock `Date` at the moment `didStartRecording` fires (not the button tap,
// which precedes the first frame by a variable spin-up), so alignment is correct by construction.
//
// Threading: capture configuration and session start/stop must run off the main thread, so this is
// a plain NSObject (not @MainActor) driving a serial `sessionQueue`; every @Published mutation is
// marshalled back to the main queue. The view observes the published state and never touches the
// session directly.

import Foundation
import AVFoundation
import UIKit
import Combine
import MatchTrackerKit

/// The finished artifact of one recording: the file on disk plus the exact wall-clock instant its
/// first frame was captured and the measured duration. The view hands this to `SidelineVideoStore`.
struct RecordedSidelineClip: Identifiable {
    let id = UUID()
    let url: URL
    /// Exact wall-clock time recording actually began (from `didStartRecording`). Persisted as the
    /// video's `creationDate` with reliable semantics — this is what makes alignment nudge-free.
    let startedAt: Date
    let duration: TimeInterval
}

@MainActor
final class SidelineCameraController: NSObject, ObservableObject {
    /// Coarse lifecycle the UI renders from.
    enum Availability: Equatable {
        case unknown
        case available
        /// No usable capture device (Simulator, denied permission, hardware failure). Carries a
        /// human-readable reason so the view can show a designed "camera unavailable" state.
        case unavailable(String)
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var isRecording = false
    /// Exact start instant of the in-flight recording; drives the elapsed timer in the UI.
    @Published private(set) var recordingStartedAt: Date?
    /// The just-finished clip, published once `didFinishRecording` completes. The view consumes it
    /// (saves into the store or routes to the match picker) and clears it.
    @Published var finishedClip: RecordedSidelineClip?
    /// Set when a recording ends abnormally (interruption, write failure) so the UI can surface it.
    @Published var recordingError: String?
    /// Free space fell below the comfort threshold — the UI warns but still allows a short capture.
    @Published private(set) var isStorageLow = false
    /// Device thermal pressure is high enough to risk a dropped/derated recording.
    @Published private(set) var isThermalPressureHigh = false

    /// The session the preview layer renders. `nil` on platforms with no capture device.
    let session = AVCaptureSession()

    /// Warn when the volume has less than this much room for an "important" write.
    private static let lowStorageThreshold: Int64 = 2 * 1024 * 1024 * 1024   // 2 GB

    private let sessionQueue = DispatchQueue(label: "com.nicemohawk.MatchTracker.sidelineCamera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var isConfigured = false
    private var activeRecordingURL: URL?
    private var thermalObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// Configure (once) and start the session. Safe to call on every `.onAppear`.
    func start() {
        refreshEnvironmentState()

        #if targetEnvironment(simulator)
        availability = .unavailable("Camera capture isn't available in the Simulator. Run on a device to film the sideline.")
        return
        #else
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            Task { @MainActor in
                if case .unknown = self.availability { self.availability = .available }
            }
        }
        observeInterruptions()
        #endif
    }

    /// Stop the session and finalize any in-flight recording. Safe on `.onDisappear`.
    func stop() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()   // finalizes the file; delegate publishes it
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        removeObservers()
    }

    // MARK: - Recording control

    /// Begin recording into a temp file inside the SidelineVideos container. The real wall-clock
    /// start is captured in `didStartRecording`, not here.
    func startRecording() {
        guard case .available = availability, !movieOutput.isRecording else { return }
        refreshEnvironmentState()

        let url = SidelineVideoStore.videosDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).mov")
        activeRecordingURL = url

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Orient the movie file to the current device orientation so soccer's landscape framing
            // is written upright (the UI nudges the filmer to rotate to landscape).
            if let connection = self.movieOutput.connection(with: .video) {
                self.applyRotation(to: connection)
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stop the in-flight recording; the file is finalized asynchronously in the delegate.
    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    // MARK: - Configuration

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        // Back camera video input.
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else {
            Task { @MainActor in
                self.availability = .unavailable("No back camera is available on this device.")
            }
            return
        }
        session.addInput(videoInput)

        // Audio input — a sideline recording wants crowd/whistle sound. A missing mic (or denial)
        // shouldn't block silent video, so this is best-effort.
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        guard session.canAddOutput(movieOutput) else {
            Task { @MainActor in
                self.availability = .unavailable("This device can't record movies right now.")
            }
            return
        }
        session.addOutput(movieOutput)

        isConfigured = true
    }

    /// Rotate the video connection to match the current interface orientation so landscape footage
    /// is written the right way up. Uses the modern rotation-angle API on iOS 17+.
    private func applyRotation(to connection: AVCaptureConnection) {
        let angle = Self.rotationAngle(for: currentInterfaceOrientation)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private nonisolated static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        case .portraitUpsideDown: return 270
        default: return 90   // portrait
        }
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }

    // MARK: - Environment guards

    /// Refresh storage + thermal warnings the UI reads. Cheap; called on start and each record tap.
    private func refreshEnvironmentState() {
        isStorageLow = (availableCapacityBytes() ?? .max) < Self.lowStorageThreshold
        isThermalPressureHigh = thermalStateIsHigh(ProcessInfo.processInfo.thermalState)
    }

    private func thermalStateIsHigh(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    private func availableCapacityBytes() -> Int64? {
        let values = try? SidelineVideoStore.videosDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Interruption handling

    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                           name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(appWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        thermalObserver = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshEnvironmentState() }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        if let thermalObserver {
            center.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
    }

    /// A call, alarm, or another app seizing the camera: finalize whatever we have so the partial
    /// clip is saved rather than lost.
    @objc private func sessionWasInterrupted(_ note: Notification) {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
    }

    /// Backgrounding stops + finalizes the file safely.
    @objc private func appWillResignActive() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension SidelineCameraController: AVCaptureFileOutputRecordingDelegate {
    /// The authoritative moment recording actually began. Stamping wall-clock here (not at the
    /// button tap) is what makes the in-app timeline nudge-free.
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        let started = Date()
        Task { @MainActor in
            self.recordingStartedAt = started
            self.isRecording = true
            self.recordingError = nil
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            let started = self.recordingStartedAt
            self.recordingStartedAt = nil

            // A recording interrupted mid-flight still yields a playable file; AVFoundation reports
            // that via a specific userInfo flag. Treat "finished successfully" as: no error, or an
            // error whose recording was flagged as still usable.
            let finishedUsable = (error as NSError?)?
                .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
            if let error, finishedUsable != true {
                self.recordingError = "Recording ended early: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }

            let duration = await Self.duration(of: outputFileURL)
            guard duration > 0.5 else {
                // Too short to be meaningful (a double-tap, an instant interruption). Discard.
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            self.finishedClip = RecordedSidelineClip(
                url: outputFileURL,
                startedAt: started ?? Date(),
                duration: duration
            )
        }
    }

    private nonisolated static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.duration).seconds) ?? 0
    }
}
