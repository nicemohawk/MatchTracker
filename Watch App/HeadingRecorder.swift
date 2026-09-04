//
//  HeadingRecorder.swift
//  MatchTracker
//

import Foundation
import CoreMotion
import MatchTrackerKit

/// Samples device heading (~1 Hz) during a match for GPS+heading sensor fusion
/// (`TrackSmoother.fuse`). Entirely best-effort: on watches without heading data this simply
/// collects nothing and the match record carries nil headings.
final class HeadingRecorder {
    private let motionManager = CMMotionManager()
    private var samples: [HeadingSample] = []
    private let maximumSamples = 7200   // ~2 h at 1 Hz

    var collected: [HeadingSample]? {
        samples.isEmpty ? nil : samples
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        samples = []
        motionManager.deviceMotionUpdateInterval = 1.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical,
                                               to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let heading = motion.heading
            guard heading >= 0 else { return }   // -1 when heading is unavailable
            samples.append(HeadingSample(timestamp: Date(), headingDegrees: heading))
            if samples.count > maximumSamples {
                samples.removeFirst(samples.count - maximumSamples)
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    func reset() {
        stop()
        samples = []
    }
}
