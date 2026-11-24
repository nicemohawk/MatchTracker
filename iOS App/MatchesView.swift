// MatchesView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Every match, newest first. The picture and the result lead; the numbers follow.
struct MatchesView: View {
    /// The search tab is the same list, already searching.
    var isSearchTab = false

    @EnvironmentObject private var matches: MatchStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path: [UUID] = []
    @State private var selection: UUID?
    @State private var filter = MatchFilter()
    @State private var query = ""
    @State private var pendingDelete: MatchSummary?
    @Namespace private var transition
    @State private var sections: [MatchListSection] = []
    @State private var hasBuilt = false

    private struct ListKey: Equatable {
        let revision: Int
        let digests: Int
        let filter: MatchFilter
        let query: String
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    list
                } detail: {
                    if let selection, matches.matches.contains(where: { $0.id == selection }) {
                        detail(selection).id(selection)
                    } else if !matches.matches.isEmpty {
                        ContentUnavailableView("Choose a Match", systemImage: "soccerball")
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    list.navigationDestination(for: UUID.self) { id in detail(id).zoomDestination(id: id, in: transition) }
                }
            }
        }
        .confirmationDialog("Delete this match?", isPresented: Binding(get: { pendingDelete != nil },
                                                                       set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { summary in
            Button("Delete Match", role: .destructive) {
                Task { _ = await matches.delete(summary) }
            }
        } message: { _ in
            Text("It will be removed from MatchTracker and, when possible, from Apple Health.")
        }
    }

    @ViewBuilder
    private func detail(_ id: UUID) -> some View {
        if let summary = matches.matches.first(where: { $0.id == id }) {
            MatchDetailView(summary: summary)
        }
    }

    private var list: some View {
        MatchList(sections: sections, transition: transition, selection: horizontalSizeClass == .regular ? $selection : nil) { pendingDelete = $0 }
            .overlay { emptyState }
            .navigationTitle(isSearchTab ? "Search" : "Matches")
            .modifier(Searching(isActive: isSearchTab, text: $query))
            // Built once per change rather than per render: hundreds of matches, all date-formatted.
            .task(id: ListKey(revision: matches.contentVersion, digests: matches.digestRevision, filter: filter, query: query)) {
                sections = MatchListSection.build(from: matches, filter: filter, query: query)
                hasBuilt = true
                if selection == nil, !isSearchTab { selection = sections.first?.items.first?.id }
            }
            .refreshable { await matches.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FilterMenu(filter: $filter)
                }
            }
    }

    @ViewBuilder
    private var emptyState: some View {
        if matches.matches.isEmpty {
            if matches.didCompleteInitialLoad { NoMatchesView() } else { ProgressView() }
        } else if hasBuilt, sections.isEmpty {
            if query.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "line.3.horizontal.decrease")
                } actions: {
                    Button("Show All Matches") { filter = MatchFilter() }
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

/// Search lives in its own tab where there is one; on iOS 17 it's on the list itself.
private struct Searching: ViewModifier {
    let isActive: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !isActive {
            content
        } else {
            content.searchable(text: $text, prompt: "Opponent, field or month")
        }
    }
}

// MARK: - List

struct MatchList: View {
    let sections: [MatchListSection]
    let transition: Namespace.ID
    var selection: Binding<UUID?>?
    let onDelete: (MatchSummary) -> Void

    var body: some View {
        // A selection binding on a list inside a stack swallows the taps its links need.
        Group {
            if let selection {
                List(selection: selection) { rows }.listStyle(.sidebar)
            } else {
                List { rows }.listStyle(.insetGrouped)
            }
        }
    }

    private var rows: some View {
        ForEach(sections) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    NavigationLink(value: item.id) { MatchRow(item: item, transition: transition) }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { onDelete(item.summary) }
                        }
                        .contextMenu {
                            Button("Delete Match", systemImage: "trash", role: .destructive) { onDelete(item.summary) }
                        }
                }
            }
        }
    }
}

struct MatchRow: View {
    let item: MatchListSection.Item
    let transition: Namespace.ID
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 16) {
            if !dynamicTypeSize.isAccessibilitySize { thumbnail }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(item.numbers)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let digest = item.digest, let result = digest.result {
                if let games = digest.games {
                    ScoreMark(result: result, text: "\(games.won) of \(games.count)", spoken: games.title)
                } else if let us = digest.goalsUs, let them = digest.goalsThem {
                    ScoreMark(result: result, text: "\(us)–\(them)", spoken: "\(result == .won ? "Won" : result == .lost ? "Lost" : "Drew") \(us) to \(them)")
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let heat = item.digest?.heat {
            HeatPitch(heat: PitchHeat(digestHeat: heat))
                .frame(width: 44, height: 66)
                .clipShape(.rect(cornerRadius: 8))
                .zoomSource(id: item.id, in: transition)
                .accessibilityHidden(true)
        } else if let strip = item.digest?.strip {
            EffortStripView(levels: strip)
                .frame(width: 44, height: 66)
                .clipShape(.rect(cornerRadius: 8))
                .zoomSource(id: item.id, in: transition)
        } else {
            Image(systemName: item.symbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 66)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }
}

/// The score, in the color of the result.
private struct ScoreMark: View {
    let result: MatchDigest.Result
    let text: String
    let spoken: String

    var body: some View {
        Text(text)
            .font(.system(.title3, design: .rounded, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel(spoken)
    }

    private var color: Color {
        switch result {
        case .won: return Theme.turf
        case .drawn: return .secondary
        case .lost: return .red
        }
    }
}

// MARK: - Filter

struct MatchFilter: Equatable {
    var format: MatchTrackerKit.MatchFormat?
    var term: SeasonSummary.Term?
    var fieldName: String?

    var isActive: Bool { self != MatchFilter() }

    func matches(_ digest: MatchDigest?, format summaryFormat: MatchTrackerKit.MatchFormat, date: Date) -> Bool {
        if let format, summaryFormat != format { return false }
        if let term, SeasonSummary.Term(containing: date) != term { return false }
        if let fieldName, digest?.fieldName != fieldName { return false }
        return true
    }
}

private struct FilterMenu: View {
    @Binding var filter: MatchFilter
    @EnvironmentObject private var matches: MatchStore

    var body: some View {
        Menu {
            Picker("Type", selection: $filter.format) {
                Text("All Types").tag(MatchTrackerKit.MatchFormat?.none)
                ForEach(MatchTrackerKit.MatchFormat.allCases, id: \.self) {
                    Text($0.title).tag(MatchTrackerKit.MatchFormat?.some($0))
                }
            }
            Picker("Season", selection: $filter.term) {
                Text("All Seasons").tag(SeasonSummary.Term?.none)
                ForEach(terms, id: \.self) { Text($0.title).tag(SeasonSummary.Term?.some($0)) }
            }
            .pickerStyle(.menu)
            Picker("Field", selection: $filter.fieldName) {
                Text("All Fields").tag(String?.none)
                ForEach(fieldNames, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Button("Show All Matches", systemImage: "xmark") { filter = MatchFilter() }
            }
        } label: {
            Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                         : "line.3.horizontal.decrease")
        }
        .accessibilityValue(filter.isActive ? "On" : "Off")
    }

    private var terms: [SeasonSummary.Term] {
        Array(Set(matches.matches.map { SeasonSummary.Term(containing: $0.startDate) })).sorted(by: >)
    }

    private var fieldNames: [String] {
        Array(Set(matches.digests.values.compactMap(\.fieldName))).sorted()
    }
}

// MARK: - Empty

/// Health never says whether reading was refused, so an empty list always offers the way to check.
struct NoMatchesView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Your First Match", systemImage: "applewatch.radiowaves.left.and.right")
        } description: {
            Text("Start a match on your Apple Watch and it will be here when you walk off the pitch.")
        } actions: {
            StartOnWatchButton()
            Button("Not Seeing Your Matches?") {
                if let url = URL(string: "x-apple-health://") { openURL(url) }
            }
        }
    }
}

// MARK: - Sections

struct MatchListSection: Identifiable {
    struct Item: Identifiable {
        let summary: MatchSummary
        let digest: MatchDigest?
        var id: UUID { summary.id }

        private var format: MatchTrackerKit.MatchFormat { summary.record?.format ?? digest?.format ?? .match }

        var title: String { digest?.place ?? format.title }

        var subtitle: String {
            let day = summary.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            let place = title == digest?.fieldName ? nil : digest?.fieldName
            let kind = format == .match || title == format.title ? nil : format.title
            return [day, place, kind].compactMap { $0 }.joined(separator: " · ")
        }

        var numbers: String {
            var parts: [String] = []
            let meters = digest?.distanceMeters ?? summary.distanceMeters
            if meters > 100 { parts.append(UnitSystem.current.distance(meters).text) }
            parts.append("\(Int(((digest?.secondsOnPitch ?? summary.duration) / 60).rounded())) min")
            return parts.joined(separator: " · ")
        }

        var symbolName: String { format == .indoor ? "house.fill" : "soccerball" }

        func contains(_ query: String) -> Bool {
            let haystack = [title, subtitle, summary.startDate.formatted(.dateTime.month(.wide).year())].joined(separator: " ")
            return haystack.localizedStandardContains(query)
        }
    }

    let title: String
    let items: [Item]
    var id: String { title }

    @MainActor
    static func build(from store: MatchStore, filter: MatchFilter, query: String) -> [MatchListSection] {
        let items = store.matches
            .map { Item(summary: $0, digest: store.digests[$0.id]) }
            .filter { filter.matches($0.digest, format: $0.summary.record?.format ?? $0.digest?.format ?? .match,
                                     date: $0.summary.startDate) }
            .filter { query.isEmpty || $0.contains(query) }
        var sections: [MatchListSection] = []
        for (title, group) in Dictionary(grouping: items, by: { $0.summary.startDate.formatted(.dateTime.month(.wide).year()) }) {
            sections.append(MatchListSection(title: title, items: group.sorted { $0.summary.startDate > $1.summary.startDate }))
        }
        return sections.sorted { $0.items[0].summary.startDate > $1.items[0].summary.startDate }
    }
}
