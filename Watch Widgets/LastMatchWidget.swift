import SwiftUI
import WidgetKit
import MatchTrackerKit

/// One entry carrying the most recent match summary the watch app wrote to the app group.
struct LastMatchEntry: TimelineEntry {
    let date: Date
    let snapshot: LastMatchSnapshot?
}

struct LastMatchProvider: TimelineProvider {
    /// Reads the shared snapshot from the app-group container. Returns nil when no match exists yet.
    private func loadSnapshot() -> LastMatchSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { return nil }
        return LastMatchSnapshot.load(from: container)
    }

    func placeholder(in context: Context) -> LastMatchEntry {
        LastMatchEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LastMatchEntry) -> Void) {
        completion(LastMatchEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastMatchEntry>) -> Void) {
        let entry = LastMatchEntry(date: Date(), snapshot: loadSnapshot())
        // The watch app also calls WidgetCenter.reloadAllTimelines() after each match (Wave-2);
        // this periodic refresh keeps the relative date honest between reloads.
        let refresh = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct LastMatchView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: LastMatchSnapshot?

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        default:
            rectangular
        }
    }

    @ViewBuilder private var inline: some View {
        if let snapshot {
            // Inline complications are rendered monochrome by the system, so no tint here.
            Label("\(score(snapshot)) · \(distance(snapshot))", systemImage: "soccerball")
        } else {
            Text("No matches yet")
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "soccerball")
                        .foregroundStyle(WidgetPalette.turf)
                    Text(score(snapshot))
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text(snapshot.endDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(distance(snapshot)) · \(timeOnPitch(snapshot))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fieldName = snapshot.fieldName {
                    Text(fieldName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Label("No matches yet", systemImage: "soccerball")
        }
    }

    private func score(_ snapshot: LastMatchSnapshot) -> String {
        "\(snapshot.goalsUs)\u{2013}\(snapshot.goalsThem)"   // en dash, e.g. "2–1"
    }

    private func distance(_ snapshot: LastMatchSnapshot) -> String {
        String(format: "%.1f km", snapshot.distanceMeters / 1000)
    }

    private func timeOnPitch(_ snapshot: LastMatchSnapshot) -> String {
        "\(Int((snapshot.timeOnPitchSeconds / 60).rounded())) min"
    }
}

/// Compact recap of the wearer's most recent match for the Smart Stack.
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
