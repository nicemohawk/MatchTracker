import RelevanceKit
import SwiftUI
import WidgetKit
import MatchTrackerKit

/// One entry carrying the most recent match summary the watch app wrote to the app group.
struct LastMatchEntry: TimelineEntry {
    let date: Date
    let snapshot: LastMatchSnapshot?
}

struct LastMatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastMatchEntry {
        LastMatchEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (LastMatchEntry) -> Void) {
        let snapshot = WidgetStorage.lastMatch
        // The gallery sells the widget; on a face nothing is ever made up.
        completion(LastMatchEntry(date: Date(), snapshot: context.isPreview ? snapshot ?? .sample : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastMatchEntry>) -> Void) {
        // The app reloads this after every match.
        completion(Timeline(entries: [LastMatchEntry(date: Date(), snapshot: WidgetStorage.lastMatch)], policy: .never))
    }

    /// The rest of match day.
    @available(watchOS 11.0, *)
    func relevance() async -> WidgetRelevance<Void> {
        guard let end = WidgetStorage.lastMatch?.endDate else { return WidgetRelevance([]) }
        return WidgetRelevance([WidgetRelevanceAttribute(context: .date(from: end, to: end.addingTimeInterval(12 * 3600)))])
    }
}

extension LastMatchSnapshot {
    /// The gallery's example.
    static var sample: LastMatchSnapshot {
        LastMatchSnapshot(matchID: UUID(), endDate: Date(), fieldName: "Riverside Park", durationSeconds: 5400,
                          timeOnPitchSeconds: 4320, distanceMeters: 7400, goalsUs: 3, goalsThem: 1, sprintCount: 12)
    }

    /// The watch writes 0–0 both for a goalless draw and for a match nobody kept score in, so 0–0
    /// says nothing.
    var result: String? {
        goalsUs + goalsThem > 0 ? MatchResultText.title(goalsUs: goalsUs, goalsThem: goalsThem) : nil
    }

    var distance: UnitSystem.Measure? {
        distanceMeters > 0 ? UnitSystem.current.roughDistance(distanceMeters) : nil
    }
}

struct LastMatchView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: LastMatchSnapshot?

    var body: some View {
        if let snapshot {
            let minutes = UnitSystem.minutes(snapshot.timeOnPitchSeconds)
            switch family {
            case .accessoryInline:
                Label([snapshot.result, snapshot.distance?.text ?? minutes.text].compactMap { $0 }.joined(separator: " · "),
                      systemImage: "soccerball")
            default:
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.result ?? "Last match")
                        .font(.headline)
                        .foregroundStyle(snapshot.goalsUs > snapshot.goalsThem
                                         ? AnyShapeStyle(WidgetPalette.turf) : AnyShapeStyle(.primary))
                        .widgetAccentable()
                    Text([snapshot.distance?.text, minutes.text].compactMap { $0 }.joined(separator: " · "))
                        .font(.body)
                    Text([snapshot.endDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                          snapshot.fieldName].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement()
                .accessibilityLabel([snapshot.result, snapshot.distance?.spoken, minutes.spoken]
                    .compactMap { $0 }.joined(separator: ", "))
            }
        } else {
            Label("No matches yet", systemImage: "soccerball")
        }
    }
}

struct LastMatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LastMatchWidget", provider: LastMatchProvider()) { entry in
            LastMatchView(snapshot: entry.snapshot)
                // Rectangular accessories get the system's translucent tray; inline stays clear.
                .containerBackground(for: .widget) {
                    AccessoryWidgetBackground()
                }
        }
        .configurationDisplayName("Last Match")
        .description("Your most recent match at a glance.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}
