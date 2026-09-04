// VenueClustering.swift
// MatchTracker
//
// Turns a flat list of saved fields into "venues" for the Compare cohort. A multi-pitch complex —
// three or four pitches within a couple hundred meters of each other — reads as one place to a
// player, not three unrelated fields, so a match's peer cohort should be "other matches at THIS
// complex", not "other matches on this exact rectangle". Fields whose rectangle centers fall within
// a radius (default 250 m) are single-link clustered into one venue; a match is then assigned to the
// venue its resolved pitch center lands in. Pure geometry — no HealthKit, no persistence.

import Foundation
import CoreLocation
import MatchTrackerKit

/// The time windows the Compare cohort can be scoped to. There is no season concept in the data, so
/// "this season" is a rolling 270-day window (about a fall→spring competitive year) rather than a
/// calendar season boundary.
enum CompareWindow: String, CaseIterable, Identifiable {
    case thisSeason
    case ninetyDays
    case allTime

    var id: String { rawValue }

    /// Rolling window length in days; nil means unbounded (all time).
    var days: Int? {
        switch self {
        case .thisSeason: return 270
        case .ninetyDays: return 90
        case .allTime: return nil
        }
    }

    /// Compact chip label while Compare is on.
    var chipLabel: String {
        switch self {
        case .thisSeason: return "Season"
        case .ninetyDays: return "90 days"
        case .allTime: return "All time"
        }
    }

    /// Lower-case caption fragment folded into the cohort caption ("vs 12 matches here · this season").
    var caption: String {
        switch self {
        case .thisSeason: return "this season"
        case .ninetyDays: return "90 days"
        case .allTime: return "all time"
        }
    }

    /// Whether `date` falls inside this rolling window measured back from `now`.
    func contains(_ date: Date, now: Date = Date()) -> Bool {
        guard let days else { return true }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return true }
        return date >= cutoff
    }
}

/// The peer-cohort average heatmap plus everything the Compare view needs to caption it honestly:
/// how many matches contributed and which fallback rung produced them.
struct CohortComparison {
    /// Which comparison the caption must own up to — the fallback ladder never switches silently.
    enum Scope {
        case venue              // same venue + format, inside the selected window
        case anyFieldWindowed   // same format anywhere, inside the window (venue cohort too thin)
        case anyFieldAllTime    // same format, all time (last-resort baseline)
    }

    let average: HeatmapGrid
    let count: Int
    let scope: Scope
    let window: CompareWindow

    /// Honest caption naming the exact cohort, e.g. "vs 12 matches here · this season" or
    /// "vs 41 matches (any field)". Never claims venue/window specificity it didn't actually use.
    var caption: String {
        let matchesText = "\(count) match\(count == 1 ? "" : "es")"
        switch scope {
        case .venue:
            return "vs \(matchesText) here · \(window.caption)"
        case .anyFieldWindowed:
            return "vs \(matchesText) (any field) · \(window.caption)"
        case .anyFieldAllTime:
            return "vs \(matchesText) (any field)"
        }
    }
}

/// Immutable field→venue assignment plus the geometry to place an arbitrary match center into a
/// venue. Built once per Compare evaluation from the current saved-field list.
struct VenueMap {
    /// Cluster index per saved field id.
    let clusterOfField: [UUID: Int]
    /// The member field centers of each cluster, for point-in-venue tests.
    private let clusterCenters: [Int: [Coordinate2D]]
    private let radiusMeters: Double

    init(clusterOfField: [UUID: Int], clusterCenters: [Int: [Coordinate2D]], radiusMeters: Double) {
        self.clusterOfField = clusterOfField
        self.clusterCenters = clusterCenters
        self.radiusMeters = radiusMeters
    }

    /// The venue a pitch center belongs to: the cluster with a member field within `radiusMeters`,
    /// nearest first. Nil when the center sits away from every saved field (an unmapped one-off).
    func venue(forCenter center: Coordinate2D) -> Int? {
        var best: (cluster: Int, distance: Double)?
        for (cluster, centers) in clusterCenters {
            for memberCenter in centers {
                let distance = VenueClustering.metersBetween(center, memberCenter)
                if distance <= radiusMeters, best == nil || distance < best!.distance {
                    best = (cluster, distance)
                }
            }
        }
        return best?.cluster
    }
}

enum VenueClustering {
    /// Default clustering / assignment radius: a couple hundred meters covers a shared multi-pitch
    /// complex without merging genuinely separate grounds across town.
    static let defaultRadiusMeters: Double = 250

    /// Single-link cluster the saved fields by center proximity, then wrap the result as a `VenueMap`.
    static func venueMap(fields: [FieldModel], radiusMeters: Double = defaultRadiusMeters) -> VenueMap {
        let clusterOfField = clusters(for: fields, radiusMeters: radiusMeters)
        var clusterCenters: [Int: [Coordinate2D]] = [:]
        for field in fields {
            guard let cluster = clusterOfField[field.id] else { continue }
            clusterCenters[cluster, default: []].append(field.rectangle.center)
        }
        return VenueMap(clusterOfField: clusterOfField, clusterCenters: clusterCenters, radiusMeters: radiusMeters)
    }

    /// Group fields whose centers are within `radiusMeters` (single-link / union-find) and return a
    /// field-id → cluster-index map. Pure function; deterministic in field order.
    static func clusters(for fields: [FieldModel], radiusMeters: Double = defaultRadiusMeters) -> [UUID: Int] {
        guard !fields.isEmpty else { return [:] }
        var parent = Array(0..<fields.count)

        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != node { let next = parent[node]; parent[node] = root; node = next }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        for i in 0..<fields.count {
            for j in (i + 1)..<fields.count {
                if metersBetween(fields[i].rectangle.center, fields[j].rectangle.center) <= radiusMeters {
                    union(i, j)
                }
            }
        }

        // Number clusters by first-seen root so indices are stable and compact.
        var clusterIndexForRoot: [Int: Int] = [:]
        var result: [UUID: Int] = [:]
        for index in fields.indices {
            let root = find(index)
            let cluster = clusterIndexForRoot[root] ?? {
                let next = clusterIndexForRoot.count
                clusterIndexForRoot[root] = next
                return next
            }()
            result[fields[index].id] = cluster
        }
        return result
    }

    /// Great-circle distance in meters between two coordinates (CoreLocation; the Kit's haversine is
    /// internal to the Kit target).
    static func metersBetween(_ a: Coordinate2D, _ b: Coordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
