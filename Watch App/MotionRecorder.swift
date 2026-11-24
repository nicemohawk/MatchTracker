//
//  MotionRecorder.swift
//  MatchTracker
//

import CoreMotion
import Foundation
import MatchTrackerKit

/// Boils the accelerometer down to how hard the wrist is moving, every few seconds of a match.
/// Needs no permission, and ten samples a second is a fraction of what a workout already draws.
///
/// Main queue only; the samples themselves arrive on their own queue.
final class MotionRecorder {
    private(set) var trace: MotionTrace?

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// `start` is kickoff, also for a match resumed after a relaunch: the gap stays unknown.
    func start(at start: Date) {
        trace = MotionTrace(start: start)
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 0.1
        var sumOfSquares = 0.0, count = 0, began = Date()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let acceleration = motion?.userAcceleration else { return }
            sumOfSquares += acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z
            count += 1
            let now = Date()
            guard now.timeIntervalSince(began) >= MotionTrace.interval else { return }
            let level = (sumOfSquares / Double(count)).squareRoot()
            (sumOfSquares, count, began) = (0, 0, now)
            DispatchQueue.main.async { self?.trace?.append(level, at: now) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    func reset() {
        stop()
        trace = nil
    }
}
