import Foundation

// MARK: - Exporters

/// Serializes a match track and its events to portable file formats (GPX for maps, CSV for
/// spreadsheets). Output is deterministic — stable number formatting, ISO8601 timestamps, and a
/// fixed ordering — so exports diff cleanly and can be golden-tested.
public enum MatchExporter {

    // MARK: GPX 1.1

    /// A GPX 1.1 document: the track as a single `<trk>`/`<trkseg>` of elevation-less `<trkpt>`s,
    /// and one `<wpt>` per event (named by the event kind, `<desc>` carrying its note). Waypoints
    /// are positioned at the track point nearest the event's timestamp.
    public static func gpx(track: [TrackPoint], events: [MatchEvent], startDate: Date) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<gpx version="1.1" creator="MatchTracker" xmlns="http://www.topografix.com/GPX/1/1">"#)
        lines.append("<metadata><time>\(iso(startDate))</time></metadata>")

        // Waypoints precede the track per the GPX 1.1 schema ordering.
        for event in sortedEvents(events) {
            let coordinate = nearestCoordinate(to: event.date, in: track)
            lines.append(#"<wpt lat="\#(coord(coordinate.latitude))" lon="\#(coord(coordinate.longitude))">"#)
            lines.append("<time>\(iso(event.date))</time>")
            lines.append("<name>\(xmlEscape(event.kind.rawValue))</name>")
            if let note = event.note, !note.isEmpty {
                lines.append("<desc>\(xmlEscape(note))</desc>")
            }
            lines.append("</wpt>")
        }

        lines.append("<trk>")
        lines.append("<trkseg>")
        for point in track {
            lines.append(#"<trkpt lat="\#(coord(point.coordinate.latitude))" lon="\#(coord(point.coordinate.longitude))">"#)
            lines.append("<time>\(iso(point.timestamp))</time>")
            lines.append("</trkpt>")
        }
        lines.append("</trkseg>")
        lines.append("</trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: CSV

    /// One row per track point: `timestamp,latitude,longitude,speed_mps,course_deg,horizontal_accuracy_m`.
    public static func csv(track: [TrackPoint]) -> String {
        var lines = ["timestamp,latitude,longitude,speed_mps,course_deg,horizontal_accuracy_m"]
        for point in track {
            lines.append([
                iso(point.timestamp),
                coord(point.coordinate.latitude),
                coord(point.coordinate.longitude),
                measure(point.speedMetersPerSecond),
                measure(point.courseDegrees),
                measure(point.horizontalAccuracy)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One row per event: `id,kind,date,note,source`. Events are ordered by date then id.
    public static func eventsCSV(events: [MatchEvent]) -> String {
        var lines = ["id,kind,date,note,source"]
        for event in sortedEvents(events) {
            lines.append([
                event.id.uuidString,
                event.kind.rawValue,
                iso(event.date),
                csvEscape(event.note ?? ""),
                event.source.rawValue
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatting helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// Coordinates to 6 decimal places (~0.1 m), the practical limit of consumer GPS.
    private static func coord(_ value: Double) -> String { String(format: "%.6f", value) }

    /// Speeds/courses/accuracies to 2 decimal places; invalid sentinels (-1) pass through.
    private static func measure(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func sortedEvents(_ events: [MatchEvent]) -> [MatchEvent] {
        events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// The coordinate of the track point closest in time to `date`; origin when the track is empty.
    private static func nearestCoordinate(to date: Date, in track: [TrackPoint]) -> Coordinate2D {
        guard let nearest = track.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }) else {
            return Coordinate2D(latitude: 0, longitude: 0)
        }
        return nearest.coordinate
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func csvEscape(_ string: String) -> String {
        guard string.contains(",") || string.contains("\"") || string.contains("\n") else { return string }
        let escaped = string.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
