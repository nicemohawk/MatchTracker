// MatchesView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

struct MatchesView: View {
    @EnvironmentObject private var matches: MatchStore
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if matches.matches.isEmpty {
                    emptyState
                } else {
                    List(matches.matches) { summary in
                        NavigationLink(value: summary.id) {
                            MatchRow(summary: summary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Matches")
            .navigationDestination(for: UUID.self) { id in
                if let summary = matches.matches.first(where: { $0.id == id }) {
                    MatchDetailView(summary: summary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable { await matches.refresh() }
            .overlay {
                if matches.isLoading && matches.matches.isEmpty {
                    ProgressView()
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Matches Yet", systemImage: "figure.soccer")
        } description: {
            Text("Recorded matches from your Apple Watch will appear here.")
        } actions: {
            if let error = matches.loadError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

/// One list row: date, field name, duration, distance, mini position badge.
struct MatchRow: View {
    let summary: MatchSummary
    @EnvironmentObject private var store: MatchStore
    @State private var position: (role: PositionRole, side: PositionSide, confidence: Double)?
    @State private var fieldName: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.startDate, format: .dateTime.weekday().month().day().hour().minute())
                    .font(.subheadline.weight(.semibold))
                Text(fieldName ?? "Unknown field")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(MatchFormat.shortDuration(summary.duration), systemImage: "clock")
                    Label(MatchFormat.distance(summary.distanceMeters), systemImage: "figure.run")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let position {
                PositionBadge(role: position.role, side: position.side, confidence: position.confidence)
            }
        }
        .padding(.vertical, 4)
        .task { await loadBadge() }
    }

    private func loadBadge() async {
        let detail = store.detailModel(for: summary)
        await detail.load()
        if let analytics = detail.analytics {
            position = (analytics.position.role, analytics.position.side, analytics.position.confidence)
            fieldName = analytics.fieldName
        } else if let fieldID = summary.record?.fieldID {
            // Record-only match: resolve the field name directly (no analytics available).
            fieldName = store.fields.field(id: fieldID)?.name
        }
    }
}
