// MatchHistoryExport.swift
// MatchTracker

import CoreTransferable
import Foundation
import MatchTrackerKit
import UniformTypeIdentifiers

/// Every match as one spreadsheet row. Written only when the player actually shares it.
struct MatchHistoryExport: Transferable {
    let matches: [MatchSummary]
    let fieldNames: [UUID: String]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MatchTracker matches.csv")
            try Data(export.csv.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    /// Unknown values are empty cells, never zeros.
    var csv: String {
        let units = UnitSystem.current
        let distanceUnit = units == .metric ? "km" : "mi"
        var lines = ["Date,Field,Minutes,Distance (\(distanceUnit)),Goals for,Goals against,My goals,Assists"]
        for match in matches.sorted(by: { $0.startDate < $1.startDate }) {
            let events = match.record?.events ?? []
            func count(_ kinds: MatchEventKind...) -> Int { events.filter { kinds.contains($0.kind) }.count }
            let hasScore = count(.goalForUs, .goalMine, .goalAgainstUs) > 0
            let meters = match.distanceMeters
            let cells = [
                match.startDate.ISO8601Format(),
                match.record?.fieldID.flatMap { fieldNames[$0] } ?? "",
                match.duration > 0 ? String(Int((match.duration / 60).rounded())) : "",
                meters > 0 ? String(format: "%.2f", units == .metric ? meters / 1000 : meters / 1609.344) : "",
                hasScore ? String(count(.goalForUs, .goalMine)) : "",
                hasScore ? String(count(.goalAgainstUs)) : "",
                events.isEmpty ? "" : String(count(.goalMine)),
                events.isEmpty ? "" : String(count(.assist))
            ]
            lines.append(cells.map(Self.escaped).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escaped(_ cell: String) -> String {
        guard cell.contains(where: { ",\"\n".contains($0) }) else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
