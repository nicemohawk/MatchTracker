//
//  ExportMenu.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Share-sheet exports of a match: GPX (track + events as waypoints) and CSVs, via the Kit's
/// `MatchExporter`. Files are staged in the temporary directory with descriptive names.
struct ExportMenu: View {
    @ObservedObject var detail: MatchDetailModel
    let summary: MatchSummary

    var body: some View {
        Menu {
            if !detail.track.isEmpty {
                ShareLink(item: stagedFile(named: "gpx", contents: gpx),
                          preview: SharePreview("\(baseName).gpx")) {
                    Label("Export GPX", systemImage: "map")
                }
                ShareLink(item: stagedFile(named: "track.csv", contents: trackCSV),
                          preview: SharePreview("\(baseName)-track.csv")) {
                    Label("Export Track CSV", systemImage: "tablecells")
                }
            }
            if !(summary.record?.events.isEmpty ?? true) {
                ShareLink(item: stagedFile(named: "events.csv", contents: eventsCSV),
                          preview: SharePreview("\(baseName)-events.csv")) {
                    Label("Export Events CSV", systemImage: "list.bullet.rectangle")
                }
            }
        } label: {
            Label("Export…", systemImage: "square.and.arrow.down")
        }
    }

    private var baseName: String {
        "match-" + summary.startDate.formatted(.iso8601.year().month().day())
    }

    private var gpx: String {
        MatchExporter.gpx(track: detail.track,
                          events: summary.record?.events ?? [],
                          startDate: summary.startDate)
    }

    private var trackCSV: String { MatchExporter.csv(track: detail.track) }

    private var eventsCSV: String { MatchExporter.eventsCSV(events: summary.record?.events ?? []) }

    /// Writes the export to a stable temp URL so ShareLink can hand a file to other apps.
    private func stagedFile(named suffix: String, contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-\(summary.id.uuidString.prefix(8)).\(suffix)")
        try? contents.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
