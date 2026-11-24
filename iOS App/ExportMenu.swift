//
//  ExportMenu.swift
//  MatchTracker
//

import CoreTransferable
import HealthKit
import SwiftUI
import UniformTypeIdentifiers
import MatchTrackerKit

/// Every format with what it's for, and how to get one onto Strava.
struct ExportDataView: View {
    let export: ActivityExport

    static let stravaUploadPage = URL(string: "https://www.strava.com/upload/select")!

    var body: some View {
        List {
            Section {
                ForEach(ExportFile.Format.available(for: export)) { format in
                    ExportLink(export: export, format: format, showsPurpose: true)
                }
            } footer: {
                if !export.track.isEmpty {
                    Text("Files with a route include exactly where you played.")
                }
            }
            if !export.isEmpty {
                Section {
                    Label("Share the FIT file above and save it to Files.", systemImage: "1.circle")
                    Label("Open Strava's upload page, sign in and choose that file.", systemImage: "2.circle")
                    Label("Check that the sport says Football (Soccer).", systemImage: "3.circle")
                    Link(destination: Self.stravaUploadPage) {
                        Label("Open Strava Upload", systemImage: "arrow.up.forward.square")
                    }
                } header: {
                    Text("Upload to Strava")
                } footer: {
                    Text("Strava's app can't open files, so this uses its website. If it turns the FIT file down, use TCX and set the sport yourself.")
                }
            }
        }
        .navigationTitle("Export Data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExportLink: View {
    let export: ActivityExport
    let format: ExportFile.Format
    var showsPurpose = false

    var body: some View {
        let file = ExportFile(export: export, format: format)
        ShareLink(item: file, preview: SharePreview(file.fileName)) {
            Label {
                if showsPurpose {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(format.title).foregroundStyle(Color.primary)
                        Text(format.purpose).font(.footnote).foregroundStyle(Color.secondary)
                    }
                } else {
                    Text(format.title)
                }
            } icon: {
                Image(systemName: format.systemImage)
            }
        }
    }
}

/// One file, made when the receiving app asks for it.
struct ExportFile: Transferable, Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case fit, tcx, gpx, trackCSV, eventsCSV
        var id: Self { self }

        var title: String {
            switch self {
            case .fit: return "FIT"
            case .tcx: return "TCX"
            case .gpx: return "GPX"
            case .trackCSV: return "Positions (CSV)"
            case .eventsCSV: return "Events (CSV)"
            }
        }

        var purpose: String {
            switch self {
            case .fit: return "Strava and most training sites"
            case .tcx: return "Training sites that don't take FIT"
            case .gpx: return "Maps"
            case .trackCSV, .eventsCSV: return "Spreadsheets"
            }
        }

        var systemImage: String {
            switch self {
            case .fit, .tcx: return "figure.run"
            case .gpx: return "map"
            case .trackCSV: return "tablecells"
            case .eventsCSV: return "list.bullet.rectangle"
            }
        }

        var fileSuffix: String {
            switch self {
            case .fit: return ".fit"
            case .tcx: return ".tcx"
            case .gpx: return ".gpx"
            case .trackCSV: return " positions.csv"
            case .eventsCSV: return " events.csv"
            }
        }

        static func available(for export: ActivityExport) -> [Format] {
            allCases.filter { format in
                switch format {
                case .fit, .tcx: return !export.isEmpty
                case .gpx, .trackCSV: return !export.track.isEmpty
                case .eventsCSV: return !export.events.isEmpty
                }
            }
        }
    }

    let export: ActivityExport
    let format: Format

    var fileName: String {
        "Match \(export.startDate.formatted(.iso8601.year().month().day()))\(format.fileSuffix)"
    }

    private var contents: Data {
        switch format {
        case .fit: return MatchExporter.fit(export)
        case .tcx: return Data(MatchExporter.tcx(export).utf8)
        case .gpx: return Data(MatchExporter.gpx(export).utf8)
        case .trackCSV: return Data(MatchExporter.csv(track: export.track).utf8)
        case .eventsCSV: return Data(MatchExporter.eventsCSV(events: export.events).utf8)
        }
    }

    private func write() throws -> SentTransferredFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try contents.write(to: url, options: .atomic)
        return SentTransferredFile(url)
    }

    private static func type(_ fileExtension: String) -> UTType { UTType(filenameExtension: fileExtension) ?? .data }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: type("fit")) { try $0.write() }.exportingCondition { $0.format == .fit }
        FileRepresentation(exportedContentType: type("tcx")) { try $0.write() }.exportingCondition { $0.format == .tcx }
        FileRepresentation(exportedContentType: type("gpx")) { try $0.write() }.exportingCondition { $0.format == .gpx }
        FileRepresentation(exportedContentType: .commaSeparatedText) { try $0.write() }
            .exportingCondition { $0.format == .trackCSV || $0.format == .eventsCSV }
    }
}

extension ActivityExport {
    @MainActor
    init(detail: MatchDetailModel, summary: MatchSummary) {
        self.init(
            name: "Soccer match", startDate: detail.matchStart, endDate: detail.matchEnd, track: detail.track,
            heartRate: detail.heartRateSeries.map { HeartRateSample(date: $0.date, bpm: $0.bpm) },
            events: detail.events,
            halftime: detail.analytics?.halftime,
            distanceMeters: detail.analytics?.distanceMeters,
            activeEnergyKilocalories: summary.workout?.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
        )
    }
}
