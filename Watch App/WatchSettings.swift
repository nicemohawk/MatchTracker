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
        case .flag: return "Mark Moment"
        case .subToggle: return "Sub In/Out"
        case .goalUs: return "Goal Us"
        }
    }
}

/// Watch-local preferences, stored in the app group so widgets and recovery paths see them too.
///
/// Reads come from an in-memory mirror — view bodies read these on every render. `prime()` fills it
/// before the first view exists; writes update the mirror and persist in the background.
enum WatchSettings {
    private enum Key {
        static let refereeMode = "refereeMode"
        static let doubleTapAction = "doubleTapAction"
        static let sportID = "sportID"
        static let formatHistory = "formatHistory"
        static let units = "units"
        static let motionRunningLevel = "motionRunningLevel"
        static let formatsWithoutScore = "formatsWithoutScore"
        static let indoorMotion = "indoorMotion"
    }

    /// The mirrored values. Guarded by `lock` — read from the main thread, written from whichever
    /// thread primes or changes a setting.
    private struct Snapshot {
        var refereeMode = false
        var doubleTapAction = DoubleTapAction.flag
        var sportID = SportProfile.soccer.id
        var formatHistory = FormatHistory()
        var motionRunningLevel: Double?
        var formatsWithoutScore: Set<String> = []
        var indoorMotion = IndoorMotion()
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

    /// Load the stored values into the mirror. Call once at launch, before the first view.
    static func prime() {
        let defaults = AppGroupStorage.defaults
        var loaded = Snapshot()
        loaded.refereeMode = defaults.bool(forKey: Key.refereeMode)
        loaded.doubleTapAction = defaults.string(forKey: Key.doubleTapAction)
            .flatMap(DoubleTapAction.init(rawValue:)) ?? .flag
        loaded.sportID = defaults.string(forKey: Key.sportID) ?? SportProfile.soccer.id
        loaded.formatHistory = defaults.data(forKey: Key.formatHistory)
            .flatMap { try? JSONDecoder().decode(FormatHistory.self, from: $0) } ?? FormatHistory()
        loaded.indoorMotion = defaults.data(forKey: Key.indoorMotion)
            .flatMap { try? JSONDecoder().decode(IndoorMotion.self, from: $0) } ?? IndoorMotion()
        loaded.formatsWithoutScore = Set(defaults.stringArray(forKey: Key.formatsWithoutScore) ?? [])
        loaded.motionRunningLevel = defaults.object(forKey: Key.motionRunningLevel) as? Double
        UnitSystem.override = defaults.string(forKey: Key.units).flatMap(UnitSystem.init(rawValue:))
        lock.lock()
        snapshot = loaded
        lock.unlock()
        MatchLog.info("settings primed (referee \(loaded.refereeMode), sport \(loaded.sportID), next format \(loaded.formatHistory.predicted(on: Date()).rawValue))",
                      category: "settings")
    }

    /// Mirror first, then persist off the main thread.
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

    /// What running looked like on this wrist last time GPS could say. Nil until it has.
    static var motionRunningLevel: Double? {
        get { read(\.motionRunningLevel) }
        set {
            guard let newValue else { return }
            write(\.motionRunningLevel, newValue)
            store(newValue, forKey: Key.motionRunningLevel)
        }
    }

    /// What playing and resting look like on this wrist, learned indoors.
    static var indoorMotion: IndoorMotion {
        get { read(\.indoorMotion) }
        set {
            write(\.indoorMotion, newValue)
            if let data = try? JSONEncoder().encode(newValue) { store(data, forKey: Key.indoorMotion) }
        }
    }

    /// Whether the wearer counts goals in this kind of match, as they've said on the phone.
    static func keepsScore(_ format: MatchFormat) -> Bool {
        !read(\.formatsWithoutScore).contains(format.rawValue)
    }

    static func setFormatsWithoutScore(_ formats: [String]) {
        write(\.formatsWithoutScore, Set(formats))
        store(formats, forKey: Key.formatsWithoutScore)
    }

    /// The phone's units setting; nil follows the region.
    static var unitOverride: UnitSystem? {
        get { UnitSystem.override }
        set {
            UnitSystem.override = newValue
            store(newValue?.rawValue ?? "automatic", forKey: Key.units)
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

    /// The format most likely to be played now: last time's on this weekday.
    static var predictedFormat: MatchFormat {
        read(\.formatHistory).predicted(on: Date())
    }

    static func recordFormat(_ format: MatchFormat, on date: Date) {
        var history = read(\.formatHistory)
        history.record(format, on: date)
        write(\.formatHistory, history)
        if let data = try? JSONEncoder().encode(history) {
            store(data, forKey: Key.formatHistory)
        }
    }
}
