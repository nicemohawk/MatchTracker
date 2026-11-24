// BacklogImportView.swift
// MatchTracker
//
// Bring in soccer workouts already in Health. Free. Three states: what's there to import, progress,
// and what came in.

import SwiftUI
import MatchTrackerKit

struct BacklogImportView: View {
    @Environment(BacklogImporter.self) private var importer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var includeRunsAndWalks = false
    @State private var importFailed = false
    @State private var hasScanned = false

    private var isFinished: Bool { importer.summary != nil && !importer.isImporting }

    var body: some View {
        NavigationStack {
            Form {
                if importer.isImporting {
                    progressSection
                } else if let summary = importer.summary {
                    summarySections(summary)
                } else {
                    introSections
                }
            }
            .animation(reduceMotion ? nil : .default, value: importer.isImporting)
            .navigationTitle("Import History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(.primary)
                }
            }
            .bottomActionBar { bottomAction }
        }
        .tint(Theme.turf)
        .task {
            await importer.scan()
            hasScanned = true
        }
        .sensoryFeedback(.success, trigger: isFinished) { _, finished in
            finished && importer.summary?.cancelled == false
        }
        .alert("Couldn’t Read Health", isPresented: $importFailed) {
            Button("Try Again") { startImport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing was imported. Make sure MatchTracker can read your workouts in the Health app.")
        }
    }

    // MARK: Intro

    @ViewBuilder
    private var introSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if importer.pendingCount > 0 {
                    Text(importer.pendingCount.formatted()).heroNumeral()
                    Text(importer.pendingCount == 1 ? "soccer workout in Health" : "soccer workouts in Health")
                        .font(.title3)
                    if let earliest = importer.earliestDate {
                        Text("Since \(earliest.formatted(.dateTime.month(.wide).year()))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                } else if hasScanned {
                    Text("Nothing new to import").font(.title2.bold())
                    Text("Every soccer workout MatchTracker can see in Health is already here.")
                        .foregroundStyle(Theme.secondaryLabel)
                } else {
                    ProgressView("Looking in Health…").frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } footer: {
            if importer.pendingCount > 0 { Text(coverage) }
        }

        Section {
            Toggle("Include runs and walks", isOn: $includeRunsAndWalks)
        } footer: {
            Text("Finds matches you recorded as an outdoor run or walk, when the route stays on one field. Takes longer.")
        }
    }

    private var coverage: String {
        let routes = importer.withRouteCount
        if routes == 0 {
            return "None of them has a GPS route, so you’ll get time and heart rate but no heat map."
        }
        if routes == importer.pendingCount { return "All of them have a GPS route." }
        let count = (importer.routeCountIsApproximate ? "About " : "") + routes.formatted()
        return "\(count) with a GPS route. The rest have time and heart rate but no heat map."
    }

    // MARK: Progress

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: Double(importer.completed), total: Double(max(importer.total, 1)))
                    .tint(Theme.turf)
                Text("\(importer.completed) of \(importer.total)")
                    .font(.headline)
                    .monospacedDigit()
                if let date = importer.currentDate {
                    Text(date, format: .dateTime.month(.wide).day().year())
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Importing")
        } footer: {
            Text("You can close this. The import keeps going while MatchTracker is open.")
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func summarySections(_ summary: BacklogImporter.Summary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.totalMatches.formatted()).heroNumeral()
                Text(summary.totalMatches == 1 ? "match imported" : "matches imported").font(.title3)
                if let span = span(of: summary) {
                    Text(span).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        } footer: {
            if summary.cancelled { Text("You stopped early. Import again to bring in the rest.") }
        }
        Section {
            if summary.fieldsCreated > 0 {
                LabeledContent("New fields", value: summary.fieldsCreated.formatted())
            }
            if summary.recoveredFromRuns > 0 {
                LabeledContent("From runs and walks", value: summary.recoveredFromRuns.formatted())
            }
            if summary.routelessImported > 0 {
                LabeledContent("Without a GPS route", value: summary.routelessImported.formatted())
            }
        }
    }

    private func span(of summary: BacklogImporter.Summary) -> String? {
        guard let earliest = summary.earliest, let latest = summary.latest else { return nil }
        let first = earliest.formatted(.dateTime.month(.wide).year())
        let last = latest.formatted(.dateTime.month(.wide).year())
        return first == last ? first : "\(first) to \(last)"
    }

    // MARK: Action

    private var bottomAction: some View {
        Group {
            if importer.isImporting {
                Button("Stop Importing", role: .destructive) { importer.cancel() }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else if isFinished {
                Button("Done") { dismiss() }.buttonStyle(.primaryAction)
            } else {
                Button(importTitle, action: startImport)
                    .buttonStyle(.primaryAction)
                    .disabled(importer.pendingCount == 0 && !includeRunsAndWalks)
            }
        }
    }

    private var importTitle: String {
        switch importer.pendingCount {
        case 0: return includeRunsAndWalks ? "Look for Matches" : "Import"
        case 1: return "Import 1 Match"
        default: return "Import \(importer.pendingCount) Matches"
        }
    }

    private func startImport() {
        Task {
            await importer.importAll(includeDisguisedRuns: includeRunsAndWalks)
            importFailed = importer.summary == nil
        }
    }
}
