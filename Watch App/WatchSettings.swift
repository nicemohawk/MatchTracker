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
enum WatchSettings {
    private enum Key {
        static let refereeMode = "refereeMode"
        static let doubleTapAction = "doubleTapAction"
        static let sportID = "sportID"
    }

    static var refereeMode: Bool {
        get { AppGroupStorage.defaults.bool(forKey: Key.refereeMode) }
        set { AppGroupStorage.defaults.set(newValue, forKey: Key.refereeMode) }
    }

    static var doubleTapAction: DoubleTapAction {
        get {
            AppGroupStorage.defaults.string(forKey: Key.doubleTapAction)
                .flatMap(DoubleTapAction.init(rawValue:)) ?? .flag
        }
        set { AppGroupStorage.defaults.set(newValue.rawValue, forKey: Key.doubleTapAction) }
    }

    static var sportID: String {
        get { AppGroupStorage.defaults.string(forKey: Key.sportID) ?? SportProfile.soccer.id }
        set { AppGroupStorage.defaults.set(newValue, forKey: Key.sportID) }
    }

    static var sportProfile: SportProfile {
        SportProfile.all.first { $0.id == sportID } ?? .soccer
    }
}
