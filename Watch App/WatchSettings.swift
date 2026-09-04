//
//  WatchSettings.swift
//  MatchTracker
//

import Foundation
import MatchTrackerKit

/// Which control the hands-free double-tap gesture (watchOS 11+) triggers during a session.
enum DoubleTapAction: String, CaseIterable, Identifiable {
    case flag
    case subToggle
    case goalUs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flag: return "Flag Moment"
        case .subToggle: return "Sub In/Out"
        case .goalUs: return "Goal Us"
        }
    }
}

/// Watch-local preferences, stored in the app group so widgets and recovery paths see them too.
///
/// Every read comes from an in-memory mirror rather than from `UserDefaults` directly. SwiftUI view
/// bodies read these on every render, and the match start and end paths read them too — while the
/// first touch of an app-group preferences suite is a cfprefsd round trip that has been measured
/// taking seconds on device, freezing the whole UI (the countdown stuck on "1", End buzzing with no
/// redraw). `prime()` fills the mirror off the main thread at launch; until it lands, reads return
/// the same defaults a fresh install would, and writes go straight through.
enum WatchSettings {
    private enum Key {
        static let refereeMode = "refereeMode"
        static let doubleTapAction = "doubleTapAction"
        static let sportID = "sportID"
        static let matchFormat = "matchFormat"
    }

    /// The mirrored values. Guarded by `lock` — read from the main thread, written from whichever
    /// thread primes or changes a setting.
    private struct Snapshot {
        var refereeMode = false
        var doubleTapAction = DoubleTapAction.flag
        var sportID = SportProfile.soccer.id
        var matchFormat = MatchFormat.match
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var snapshot = Snapshot()

    private static func read<Value>(_ keyPath: KeyPath<Snapshot, Value>) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return snapshot[keyPath: keyPath]
    }

    private static func write<Value>(_ keyPath: WritableKeyPath<Snapshot, Value>, _ value: Value) {
        lock.lock()
        snapshot[keyPath: keyPath] = value
        lock.unlock()
    }

    /// Load the stored values into the mirror. Call once at launch, OFF the main thread.
    static func prime() {
        let defaults = AppGroupStorage.defaults
        var loaded = Snapshot()
        loaded.refereeMode = defaults.bool(forKey: Key.refereeMode)
        loaded.doubleTapAction = defaults.string(forKey: Key.doubleTapAction)
            .flatMap(DoubleTapAction.init(rawValue:)) ?? .flag
        loaded.sportID = defaults.string(forKey: Key.sportID) ?? SportProfile.soccer.id
        loaded.matchFormat = defaults.string(forKey: Key.matchFormat)
            .flatMap(MatchFormat.init(rawValue:)) ?? .match
        lock.lock()
        snapshot = loaded
        lock.unlock()
        MatchLog.info("settings primed (referee \(loaded.refereeMode), sport \(loaded.sportID), format \(loaded.matchFormat.rawValue))",
                      category: "settings")
    }

    /// Mirror first, then persist off the main thread — a setting change is a user action, and the
    /// UI shouldn't wait on cfprefsd to reflect it.
    private static func store(_ value: Any, forKey key: String) {
        DispatchQueue.global(qos: .utility).async {
            AppGroupStorage.defaults.set(value, forKey: key)
        }
    }

    static var refereeMode: Bool {
        get { read(\.refereeMode) }
        set {
            MatchLog.info("user: referee mode -> \(newValue)", category: "settings")
            write(\.refereeMode, newValue)
            store(newValue, forKey: Key.refereeMode)
        }
    }

    static var doubleTapAction: DoubleTapAction {
        get { read(\.doubleTapAction) }
        set {
            MatchLog.info("user: double-tap action -> \(newValue.rawValue)", category: "settings")
            write(\.doubleTapAction, newValue)
            store(newValue.rawValue, forKey: Key.doubleTapAction)
        }
    }

    static var sportID: String {
        get { read(\.sportID) }
        set {
            MatchLog.info("user: sport -> \(newValue)", category: "settings")
            write(\.sportID, newValue)
            store(newValue, forKey: Key.sportID)
        }
    }

    /// Cached per sport id so repeated reads skip the linear scan of `SportProfile.all`.
    private nonisolated(unsafe) static var cachedSportProfile: (id: String, profile: SportProfile)?

    static var sportProfile: SportProfile {
        let id = sportID
        if let cached = cachedSportProfile, cached.id == id { return cached.profile }
        let profile = SportProfile.all.first { $0.id == id } ?? .soccer
        cachedSportProfile = (id, profile)
        return profile
    }

    /// Last-chosen match format for the start-screen quick pick (Match / Pickup / Indoor).
    static var matchFormat: MatchFormat {
        get { read(\.matchFormat) }
        set {
            MatchLog.info("user: format -> \(newValue.rawValue)", category: "settings")
            write(\.matchFormat, newValue)
            store(newValue.rawValue, forKey: Key.matchFormat)
        }
    }
}
