import SwiftUI
import WidgetKit

/// Single, timeless entry — the Start-Match complication never changes state.
struct StartMatchEntry: TimelineEntry {
    let date: Date
}

struct StartMatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartMatchEntry {
        StartMatchEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (StartMatchEntry) -> Void) {
        completion(StartMatchEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StartMatchEntry>) -> Void) {
        // Static content: one entry, never refresh.
        completion(Timeline(entries: [StartMatchEntry(date: Date())], policy: .never))
    }
}

struct StartMatchView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "soccerball")
                .font(.title2)
                .widgetLabel("Start")
        default:
            VStack(spacing: 1) {
                Image(systemName: "soccerball")
                    .font(.title3)
                Text("Start")
                    .font(.caption2)
            }
        }
    }
}

/// Tapping the complication deep-links into the watch app's start flow via `matchtracker://start`.
struct StartMatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StartMatchWidget", provider: StartMatchProvider()) { _ in
            StartMatchView()
                .widgetURL(URL(string: "matchtracker://start"))
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Start Match")
        .description("Jump straight into recording a match.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}
