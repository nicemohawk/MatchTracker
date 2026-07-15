// MatchListSupport.swift
// MatchTracker
//
// Scale plumbing for the Matches list: a once-per-array precompute that groups a long soccer
// history (300+ matches spanning years) into month sections with per-section aggregates, plus the
// year-aware date labels, search haystacks, filter model, and the small chrome views (filter chip
// row, sticky month header, reported-position badge) the list restructures around. Everything here
// is O(n) precomputed off the row builder so the LazyVStack stays lazy and rows carry no
// per-appearance date formatters — they render a precomputed string and a synchronously known badge.

import SwiftUI
import MatchTrackerKit

// The app also declares a `MatchFormat` utility enum (GeometryBridge.swift) for distance/duration
// formatting, so a bare `MatchFormat` here would resolve to that. This alias names the Kit match
// format (`.match` / `.smallSided` / `.indoor`) the list groups and filters by.
typealias FormatKind = MatchTrackerKit.MatchFormat

// MARK: - Shared formatters

/// Static, shared date formatters/styles so no row builds its own on appearance (a real cost at
/// 300 rows). Two styles: a compact same-year form matching the app's prior row format, and a
/// year-bearing form for matches from earlier years.
enum MatchListFormatters {
    /// "Tue, Jun 3, 2:45 PM" — the compact form used for current-year matches.
    static let compactDate = Date.FormatStyle.dateTime.weekday().month().day().hour().minute()
    /// "Tue, Jun 3, 2024, 2:45 PM" — includes the year for matches from previous years.
    static let fullDate = Date.FormatStyle.dateTime.weekday().month().day().year().hour().minute()

    /// "June 2026" section header title.
    static let monthHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    /// Year-aware row date label: compact within the current year, year-bearing for older matches.
    static func dateLabel(for date: Date, currentYear: Int, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        return date.formatted(year == currentYear ? compactDate : fullDate)
    }
}

// MARK: - Precomputed list model

/// One precomputed row: the summary plus everything the list needs to render, search, filter, and
/// aggregate it without touching HealthKit or a formatter per appearance.
struct MatchListItem: Identifiable {
    let id: UUID
    let summary: MatchSummary
    let dateLabel: String
    /// Grouping key `year * 12 + month`, descending-sortable.
    let sectionKey: Int
    let year: Int
    let month: Int
    let format: FormatKind
    let hasGPS: Bool
    let distanceMeters: Double
    /// Lowercased search haystack (date, month/year, field, score, format keyword, "gps").
    let haystack: String
}

/// A month's worth of matches with a display title and a compact aggregate ("6 matches · 41 km").
struct MatchListSection: Identifiable {
    let id: Int
    let title: String
    let detail: String
    let items: [MatchListItem]
}

/// The whole precompute: flat items (sorted, as `matches` already is), grouped sections, and the
/// dimensions the filter chip row derives from the data (formats present, years present, any GPS).
struct MatchListData {
    let items: [MatchListItem]
    let sections: [MatchListSection]
    let formats: [FormatKind]
    let years: [Int]
    let hasAnyGPS: Bool

    static let empty = MatchListData(items: [], sections: [], formats: [], years: [], hasAnyGPS: false)

    /// Build the precompute once for a matches array. O(n): a single pass to derive per-item
    /// metadata, then a grouping pass. Field name / GPS come from the synchronously available badge
    /// cache (or the record's field), so a warm cache makes field-search and the "Has GPS" filter
    /// immediate; cold matches simply read as no-field / no-GPS until their badge computes.
    @MainActor
    static func build(matches: [MatchSummary], store: MatchStore) -> MatchListData {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        var items: [MatchListItem] = []
        items.reserveCapacity(matches.count)
        var formatsSeen: Set<FormatKind> = []
        var yearsSeen: Set<Int> = []
        var anyGPS = false

        for summary in matches {
            let date = summary.startDate
            let components = calendar.dateComponents([.year, .month], from: date)
            let year = components.year ?? currentYear
            let month = components.month ?? 1
            let format = summary.record?.format ?? .match

            let badge = store.cachedBadge(for: summary.id)
            let fieldName = badge?.fieldName
                ?? summary.record?.fieldID.flatMap { store.fields.field(id: $0)?.name }
            let hasGPS = badge?.hasRoute ?? false
            if hasGPS { anyGPS = true }

            let dateLabel = MatchListFormatters.dateLabel(for: date, currentYear: currentYear, calendar: calendar)

            var haystackParts: [String] = [dateLabel, MatchListFormatters.monthHeader.string(from: date)]
            if let fieldName { haystackParts.append(fieldName) }
            if let score = score(for: summary.record) { haystackParts.append(score) }
            haystackParts.append(format.searchKeyword)
            if hasGPS { haystackParts.append("gps") }

            items.append(MatchListItem(
                id: summary.id,
                summary: summary,
                dateLabel: dateLabel,
                sectionKey: year * 12 + month,
                year: year,
                month: month,
                format: format,
                hasGPS: hasGPS,
                distanceMeters: summary.distanceMeters,
                haystack: haystackParts.joined(separator: " ").lowercased()
            ))

            formatsSeen.insert(format)
            yearsSeen.insert(year)
        }

        return MatchListData(
            items: items,
            sections: group(items, calendar: calendar),
            formats: FormatKind.allCases.filter { formatsSeen.contains($0) },
            years: yearsSeen.sorted(by: >),
            hasAnyGPS: anyGPS
        )
    }

    /// Apply the active filter and search query to the precomputed items, then regroup into month
    /// sections. O(n) over the flat item list — the LazyVStack still lazily realizes only the rows
    /// actually on screen.
    func sections(filter: MatchFilter, query: String) -> [MatchListSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if filter == .all, trimmed.isEmpty { return sections }
        let matched = items.filter { filter.matches($0) && (trimmed.isEmpty || $0.haystack.contains(trimmed)) }
        return Self.group(matched, calendar: Calendar.current)
    }

    /// Group already-sorted items into descending month sections with count + distance aggregates.
    private static func group(_ items: [MatchListItem], calendar: Calendar) -> [MatchListSection] {
        guard !items.isEmpty else { return [] }
        var sections: [MatchListSection] = []
        var bucket: [MatchListItem] = []
        var currentKey = items[0].sectionKey

        func flush() {
            guard let first = bucket.first else { return }
            let totalMeters = bucket.reduce(0) { $0 + $1.distanceMeters }
            sections.append(MatchListSection(
                id: currentKey,
                title: MatchListFormatters.monthHeader.string(from: first.summary.startDate),
                detail: aggregate(count: bucket.count, totalMeters: totalMeters),
                items: bucket
            ))
        }

        for item in items {
            if item.sectionKey != currentKey {
                flush()
                bucket.removeAll(keepingCapacity: true)
                currentKey = item.sectionKey
            }
            bucket.append(item)
        }
        flush()
        return sections
    }

    /// "6 matches · 41 km" — the distance clause is dropped when the month has no GPS distance.
    private static func aggregate(count: Int, totalMeters: Double) -> String {
        let matchesText = "\(count) match\(count == 1 ? "" : "es")"
        guard totalMeters > 0 else { return matchesText }
        let km = totalMeters / 1000
        let kmText = km >= 10 ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
        return "\(matchesText) · \(kmText)"
    }

    /// "us–them" from logged goal events, or nil when no goals were recorded.
    static func score(for record: MatchRecord?) -> String? {
        guard let events = record?.events, !events.isEmpty else { return nil }
        let us = events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = events.filter { $0.kind == .goalAgainstUs }.count
        guard us > 0 || them > 0 else { return nil }
        return "\(us)–\(them)"
    }
}

// MARK: - Filter model

/// The single active list filter. `All` resets; formats/years are derived from the data so chips
/// only ever offer values that exist. Filters compose with the search query.
enum MatchFilter: Hashable {
    case all
    case format(FormatKind)
    case hasGPS
    case year(Int)

    func matches(_ item: MatchListItem) -> Bool {
        switch self {
        case .all: return true
        case .format(let format): return item.format == format
        case .hasGPS: return item.hasGPS
        case .year(let year): return item.year == year
        }
    }
}

// The Kit enum has a String raw value but doesn't declare Hashable; the list's filter model needs
// it (it's a `MatchFilter` associated value), so conform it here.
extension MatchTrackerKit.MatchFormat: @retroactive Hashable {}

extension MatchTrackerKit.MatchFormat {
    /// Chip label in the app idiom: pickup, not "small-sided".
    var chipLabel: String {
        switch self {
        case .match: return "Match"
        case .smallSided: return "Pickup"
        case .indoor: return "Indoor"
        }
    }

    /// Extra keyword folded into the search haystack so "pickup"/"indoor"/"match" all match.
    var searchKeyword: String {
        switch self {
        case .match: return "match"
        case .smallSided: return "pickup small-sided"
        case .indoor: return "indoor"
        }
    }
}

// MARK: - Chrome views

/// Horizontal capsule filter chips under the title: All / per-format / Has GPS / per-year, derived
/// from the data. Single-select in the app idiom — tapping a chip replaces the active filter.
struct MatchFilterBar: View {
    let data: MatchListData
    @Binding var selection: MatchFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", filter: .all)
                ForEach(data.formats, id: \.self) { format in
                    chip(label: format.chipLabel, filter: .format(format))
                }
                if data.hasAnyGPS {
                    chip(label: "Has GPS", filter: .hasGPS, icon: "point.topleft.down.to.point.bottomright.curvepath")
                }
                ForEach(data.years, id: \.self) { year in
                    chip(label: String(year), filter: .year(year))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(label: String, filter: MatchFilter, icon: String? = nil) -> some View {
        let isSelected = selection == filter
        return Button {
            Haptics.selection()
            selection = filter
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.caption2.bold())
                }
                Text(label)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(isSelected ? Theme.turf : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(isSelected ? Theme.chipFill(Theme.turf) : Theme.surfaceElevated, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Theme.chipStroke(Theme.turf) : Theme.surfaceStroke,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

/// Sticky-feel month header for the LazyVStack (`pinnedViews: [.sectionHeaders]`): the month title
/// with a compact aggregate on the trailing edge. Opaque background so pinned it cleanly covers
/// cards scrolling beneath it.
struct MatchSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
    }
}

/// Position badge for hand-reported positions: the first reported position, plus "+N" when several
/// were logged. Reuses the shared `PositionBadge` visual; reported positions carry no confidence,
/// so the badge renders at full strength (this is the player's own statement, not an estimate).
struct ReportedPositionBadge: View {
    let positions: [ReportedPosition]

    var body: some View {
        if let first = positions.first {
            HStack(spacing: 4) {
                PositionBadge(role: first.role, side: first.side ?? .center)
                if positions.count > 1 {
                    Text("+\(positions.count - 1)")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
