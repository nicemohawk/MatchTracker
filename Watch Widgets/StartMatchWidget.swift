import SwiftUI
import WidgetKit

/// Widgets render in their own extension process where `WatchTheme` isn't linked, so the two
/// palette values the complications actually need live here as a tiny local mirror of the app's
/// design tokens (kept byte-identical to `WatchTheme.background`/`.turf`).
enum WidgetPalette {
    /// Near-black canvas (#0C0D10).
    static let background = Color(red: 0.047, green: 0.051, blue: 0.063)
    /// Emerald turf accent (#30D158).
    static let turf = Color(red: 0.188, green: 0.820, blue: 0.345)
}

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
                .foregroundStyle(WidgetPalette.turf)
                .widgetLabel("Start")
        default:
            VStack(spacing: 1) {
                Image(systemName: "soccerball")
                    .font(.title3)
                    .foregroundStyle(WidgetPalette.turf)
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
                // AccessoryWidgetBackground draws the system's translucent tray for circular
                // (and stays clear for corner), keeping the turf glyph legible on any face.
                .containerBackground(for: .widget) {
                    AccessoryWidgetBackground()
                }
        }
        .configurationDisplayName("Start Match")
        .description("Jump straight into recording a match.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}
