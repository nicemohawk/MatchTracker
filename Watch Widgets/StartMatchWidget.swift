import CoreLocation
import RelevanceKit
import SwiftUI
import WidgetKit
import MatchTrackerKit

/// The same green the watch app uses (`WatchTheme.turf`), which this process doesn't link.
enum WidgetPalette {
    static var turf: Color { Color(cgColor: KitColors.current.tintOnDark.cgColor) }
}

/// What the app left in the app group.
enum WidgetStorage {
    static let containerURL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)

    static var lastMatch: LastMatchSnapshot? {
        KitColors.refresh()
        return containerURL.flatMap(LastMatchSnapshot.load)
    }

    /// The format a tap on Start will begin, guessed exactly as the app guesses it.
    static func likelyFormat(on date: Date) -> MatchFormat {
        UserDefaults(suiteName: AppGroup.identifier)?.data(forKey: "formatHistory")
            .flatMap { try? JSONDecoder().decode(FormatHistory.self, from: $0) }?
            .predicted(on: date) ?? .match
    }

    static var fields: [FieldModel] {
        guard let containerURL else { return [] }
        let store = FieldStore(directory: containerURL)
        try? store.load()
        return store.fields
    }
}

struct StartMatchEntry: TimelineEntry {
    let date: Date
    let format: MatchFormat
}

struct StartMatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartMatchEntry {
        StartMatchEntry(date: Date(), format: .match)
    }

    func getSnapshot(in context: Context, completion: @escaping (StartMatchEntry) -> Void) {
        completion(StartMatchEntry(date: Date(), format: WidgetStorage.likelyFormat(on: Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StartMatchEntry>) -> Void) {
        // The guess is per weekday, so it changes at midnight and no sooner.
        let today = Date()
        let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: today)) }
        let entries = days.map { StartMatchEntry(date: max($0, today), format: WidgetStorage.likelyFormat(on: $0)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// Worth surfacing at a pitch you've played on, and around kickoff a week after the last match:
    /// leagues repeat.
    @available(watchOS 11.0, *)
    func relevance() async -> WidgetRelevance<Void> {
        var contexts = WidgetStorage.fields
            .sorted { $0.observationCount > $1.observationCount }
            .prefix(10)
            .map { field in
                RelevantContext.location(CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: field.rectangle.center.latitude,
                                                   longitude: field.rectangle.center.longitude),
                    radius: 250, identifier: field.id.uuidString))
            }
        if let last = WidgetStorage.lastMatch {
            let kickoff = last.endDate.addingTimeInterval(7 * 86_400 - last.durationSeconds)
            if kickoff > Date() {
                contexts.append(.date(from: kickoff.addingTimeInterval(-45 * 60),
                                      to: kickoff.addingTimeInterval(15 * 60)))
            }
        }
        return WidgetRelevance(contexts.map { WidgetRelevanceAttribute(context: $0) })
    }
}

struct StartMatchView: View {
    @Environment(\.widgetFamily) private var family
    let format: MatchFormat

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "soccerball")
                .font(.title2)
                .foregroundStyle(WidgetPalette.turf)
                .widgetAccentable()
                .widgetLabel("Start \(format.startTitle.lowercased())")
        case .accessoryInline:
            Label("Start \(format.startTitle.lowercased())", systemImage: "soccerball")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "soccerball")
                    .font(.title)
                    .foregroundStyle(WidgetPalette.turf)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Start \(format.startTitle.lowercased())")
                        .font(.headline)
                    Text("Tap to record")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        default:
            Image(systemName: "soccerball")
                .font(.title)
                .foregroundStyle(WidgetPalette.turf)
                .widgetAccentable()
                .accessibilityLabel("Start \(format.startTitle.lowercased())")
        }
    }
}

private extension MatchFormat {
    var startTitle: String {
        switch self {
        case .match: return "Match"
        case .smallSided: return "Pickup"
        case .indoor: return "Indoor"
        }
    }
}

/// Tapping starts recording: the watch app handles `matchtracker://start`.
struct StartMatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StartMatchWidget", provider: StartMatchProvider()) { entry in
            StartMatchView(format: entry.format)
                .widgetURL(MatchTrackerLink.start.url)
                // The system's translucent tray keeps the glyph legible on any face.
                .containerBackground(for: .widget) {
                    AccessoryWidgetBackground()
                }
        }
        .configurationDisplayName("Start Match")
        .description("Starts recording with one tap.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}
