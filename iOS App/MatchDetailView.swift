// MatchDetailView.swift
// MatchTracker

import SwiftUI
import Combine
import MatchTrackerKit

struct MatchDetailView: View {
    let summary: MatchSummary
    @EnvironmentObject private var store: MatchStore
    @EnvironmentObject private var uploads: UploadService
    @StateObject private var model: DetailLoader

    init(summary: MatchSummary) {
        self.summary = summary
        _model = StateObject(wrappedValue: DetailLoader())
    }

    enum Section: String, CaseIterable, Identifiable {
        case heatmap = "Heatmap"
        case runs = "Runs"
        case workrate = "Workrate"
        case position = "Position"
        case events = "Events"
        var id: String { rawValue }
    }

    @State private var section: Section = .heatmap

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                content
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(Text(summary.startDate, format: .dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await uploads.reupload(summary) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(uploads.isUploading)
            }
        }
        .task {
            model.attach(store.detailModel(for: summary))
            await model.detail?.load()
        }
    }

    private var header: some View {
        let detail = model.detail
        return HStack {
            StatTile(title: "Duration", value: MatchFormat.shortDuration(summary.duration), systemImage: "clock")
            StatTile(title: "Distance",
                     value: MatchFormat.distance(detail?.analytics?.workrate.totalDistanceMeters ?? summary.distanceMeters),
                     systemImage: "figure.run")
            StatTile(title: "Sprints", value: "\(detail?.analytics?.workrate.sprintCount ?? 0)", systemImage: "hare")
            if let hr = detail?.heartRate {
                StatTile(title: "Avg HR", value: "\(Int(hr.average))", systemImage: "heart.fill")
            } else {
                StatTile(title: "Workrate", value: "\(Int(detail?.analytics?.workrate.workrateScore ?? 0))", systemImage: "bolt.fill")
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var content: some View {
        if let detail = model.detail {
            if detail.isLoading && detail.analytics == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if let analytics = detail.analytics {
                switch section {
                case .heatmap:
                    HeatmapSection(detail: detail, analytics: analytics)
                case .runs:
                    RunsSection(detail: detail, analytics: analytics)
                case .workrate:
                    WorkrateSection(detail: detail, analytics: analytics)
                case .position:
                    PositionSection(analytics: analytics)
                case .events:
                    EventsSection(detail: detail)
                }
            } else if section == .events {
                EventsSection(detail: detail)
            } else {
                ContentUnavailableView("No GPS Data Recorded", systemImage: "location.slash",
                                       description: Text("This match has no GPS route, so heatmap, runs, workrate and position aren't available. The events timeline still works."))
                    .frame(minHeight: 200)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

/// Bridges the store's cached `MatchDetailModel` (a reference type) into a `StateObject` so the
/// view re-renders as its `@Published` analytics load.
@MainActor
final class DetailLoader: ObservableObject {
    @Published private(set) var detail: MatchDetailModel?
    private var cancellable: AnyObject?

    func attach(_ model: MatchDetailModel) {
        guard detail !== model else { return }
        detail = model
        // Re-publish whenever the underlying model changes.
        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        } as AnyObject
    }
}
