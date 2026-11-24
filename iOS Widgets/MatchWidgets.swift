import SwiftUI
import WidgetKit
import MatchTrackerKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var relevance: TimelineEntryRelevance?
}

/// Reads what the app last wrote. The app reloads timelines when that changes, so nothing here polls.
struct SnapshotProvider: TimelineProvider {
    private func snapshot() -> WidgetSnapshot? {
        KitColors.refresh()
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: MatchTrackerKit.AppGroup.identifier)
            .flatMap(WidgetSnapshot.load)
    }

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let current = snapshot()
        // The gallery sells the widget; on the Home Screen nothing is ever made up.
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? current ?? .sample : current))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = snapshot()
        let now = Date()
        // Worth seeing for the rest of match day; after that the stack can decide.
        let freshUntil = snapshot?.lastMatch?.endDate.addingTimeInterval(12 * 3600) ?? now
        let relevance = freshUntil > now
            ? TimelineEntryRelevance(score: 100, duration: freshUntil.timeIntervalSince(now))
            : TimelineEntryRelevance(score: 10)
        completion(Timeline(entries: [SnapshotEntry(date: now, snapshot: snapshot, relevance: relevance)],
                            policy: .never))
    }
}

struct LastMatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LastMatch", provider: SnapshotProvider()) { entry in
            WidgetContent { family, monochrome in
                LastMatchWidgetView(snapshot: entry.snapshot, family: family, monochrome: monochrome)
            }
            .widgetURL(entry.snapshot?.lastMatch.map { MatchTrackerLink.match($0.id).url })
        }
        .configurationDisplayName("Last Match")
        .description("The score, where you played, and how far you ran.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SeasonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Season", provider: SnapshotProvider()) { entry in
            WidgetContent { family, _ in
                SeasonWidgetView(snapshot: entry.snapshot, family: family)
            }
            .widgetURL(MatchTrackerLink.season.url)
        }
        .configurationDisplayName("Season")
        .description("Your record, your form, and the ground you've covered.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Reads the family and rendering mode once, so the views themselves can be drawn anywhere.
private struct WidgetContent<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @ViewBuilder let content: (WidgetFamily, Bool) -> Content

    private var isOnCloth: Bool { renderingMode == .fullColor && [.systemSmall, .systemMedium, .systemLarge].contains(family) }

    var body: some View {
        if isOnCloth {
            content(family, false)
                .foregroundStyle(SurfacePalette.ivory)
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) { WidgetCloth() }
        } else {
            content(family, renderingMode != .fullColor)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
    }
}
