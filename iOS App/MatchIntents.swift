// MatchIntents.swift
// MatchTracker

import AppIntents
import CoreSpotlight
import SwiftUI
import WidgetKit
import MatchTrackerKit

// There is no "log a goal" here: events are logged on the watch, and the phone has no way to add one
// to a match in progress.

// MARK: - The match, as the system sees it

struct MatchEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Match"
    static var defaultQuery = MatchEntityQuery()

    let id: UUID
    let name: String
    let detail: String
    let date: Date

    init(_ digest: MatchDigest, units: UnitSystem) {
        id = digest.id
        date = digest.startDate
        name = [MatchResultText.title(goalsUs: digest.goalsUs, goalsThem: digest.goalsThem), digest.title]
            .compactMap { $0 }.joined(separator: " ")
        detail = [digest.startDate.formatted(date: .abbreviated, time: .shortened),
                  digest.opponent == nil ? nil : digest.fieldName,
                  digest.distanceMeters.map { units.roughDistance($0).text }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: .init(systemName: "soccerball"))
    }
}

@available(iOS 18.0, *)
extension MatchEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet { searchableAttributes }
}

extension MatchEntity {
    /// Score, opponent, ground and date. No heart rate and no coordinates.
    var searchableAttributes: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = detail
        attributes.startDate = date
        attributes.keywords = ["match", "soccer", "football", "game"]
        return attributes
    }
}

struct MatchEntityQuery: EntityStringQuery {
    private var all: [MatchEntity] {
        guard let snapshot = WidgetSnapshot.load(from: AppGroup.containerURL) else { return [] }
        return snapshot.recent.map { MatchEntity($0, units: snapshot.units) }
    }

    func entities(for identifiers: [UUID]) async throws -> [MatchEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [MatchEntity] {
        all.filter { $0.name.localizedCaseInsensitiveContains(string) || $0.detail.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [MatchEntity] {
        Array(all.prefix(20))
    }
}

// MARK: - Intents

struct OpenMatchIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Match"
    static var description = IntentDescription("Opens one of your matches.")

    @Parameter(title: "Match")
    var target: MatchEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        LinkRouter.shared.pending = .match(target.id)
        return .result()
    }
}

struct ShowLastMatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Last Match"
    static var description = IntentDescription("The score and how far you ran in your most recent match.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let snapshot = WidgetSnapshot.load(from: AppGroup.containerURL)
        let spoken = snapshot?.spokenLastMatch ?? "You haven't recorded a match yet."
        return .result(dialog: "\(spoken)", view: SnippetFrame {
            LastMatchWidgetView(snapshot: snapshot, family: .systemMedium)
        })
    }
}

struct SeasonSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Season So Far"
    static var description = IntentDescription("Your record and how far you've run this season.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let snapshot = WidgetSnapshot.load(from: AppGroup.containerURL)
        let spoken = snapshot?.spokenSeason ?? "You haven't recorded a match yet."
        return .result(dialog: "\(spoken)", view: SnippetFrame {
            SeasonWidgetView(snapshot: snapshot, family: .systemMedium)
        })
    }
}

/// The widget's layout at a widget's size, in Siri's card.
struct SnippetFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(minHeight: 130)
            .padding()
    }
}

struct MatchTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowLastMatchIntent(),
                    phrases: ["Show my last match in \(.applicationName)",
                              "How was my last match in \(.applicationName)"],
                    shortTitle: "Last Match", systemImageName: "soccerball")
        AppShortcut(intent: SeasonSummaryIntent(),
                    phrases: ["How am I doing this season in \(.applicationName)",
                              "Show my \(.applicationName) season"],
                    shortTitle: "Season", systemImageName: "chart.bar")
        AppShortcut(intent: StartOnWatchIntent(),
                    phrases: ["Start a match on my watch with \(.applicationName)",
                              "Start a \(.applicationName) match on my watch"],
                    shortTitle: "Start on Watch", systemImageName: "applewatch")
        AppShortcut(intent: OpenMatchIntent(),
                    phrases: ["Open a match in \(.applicationName)"],
                    shortTitle: "Open Match", systemImageName: "sportscourt")
    }
}

// MARK: - Publishing

/// The one call that keeps widgets, Siri and Spotlight up to date.
enum SystemSurfaces {
    private static let indexDomain = "match"
    private static let queue = DispatchQueue(label: "com.nicemohawk.MatchTracker.surfaces", qos: .utility)

    /// Call whenever the digests change (and on a units change). Cheap when nothing is different.
    ///
    /// - Parameter lastMatchHeat: the latest match's heatmap when it's been computed. Leaving it out
    ///   keeps the one already published for that match.
    static func publish(digests: [MatchDigest], lastMatchHeat: HeatmapGrid? = nil) {
        let units = UnitSystem.current
        queue.async {
            let container = AppGroup.containerURL
            let previous = WidgetSnapshot.load(from: container)
            var snapshot = WidgetSnapshot.make(from: digests, heat: lastMatchHeat, units: units)
            if snapshot.heat == nil, let previous, previous.lastMatch?.id == snapshot.lastMatch?.id {
                snapshot.heat = previous.heat
            }
            do {
                guard try snapshot.save(to: container) else { return }
            } catch {
                MatchLog.error("Widget snapshot write failed: \(error.localizedDescription)", category: "widgets")
                return
            }
            WidgetCenter.shared.reloadAllTimelines()
            index(snapshot, replacing: previous)
        }
    }

    /// For the privacy deletion path: leaves nothing behind outside the app.
    static func erase() {
        queue.async {
            try? FileManager.default.removeItem(at: WidgetSnapshot.fileURL(in: AppGroup.containerURL))
            WidgetCenter.shared.reloadAllTimelines()
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [indexDomain])
            if #available(iOS 18.0, *) {
                Task { try? await CSSearchableIndex.default().deleteAppEntities(ofType: MatchEntity.self) }
            }
        }
    }

    private static func index(_ snapshot: WidgetSnapshot, replacing previous: WidgetSnapshot?) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let entities = snapshot.recent.map { MatchEntity($0, units: snapshot.units) }
        let gone = Set(previous?.recent.map(\.id) ?? []).subtracting(entities.map(\.id))
        Task {
            let index = CSSearchableIndex.default()
            do {
                if #available(iOS 18.0, *) {
                    try await index.deleteAppEntities(identifiedBy: Array(gone), ofType: MatchEntity.self)
                    try await index.indexAppEntities(entities)
                } else {
                    try await index.deleteSearchableItems(withIdentifiers: gone.map(\.uuidString))
                    try await index.indexSearchableItems(entities.map {
                        CSSearchableItem(uniqueIdentifier: $0.id.uuidString, domainIdentifier: indexDomain,
                                         attributeSet: $0.searchableAttributes)
                    })
                }
            } catch {
                MatchLog.error("Spotlight indexing failed: \(error.localizedDescription)", category: "widgets")
            }
        }
    }
}
