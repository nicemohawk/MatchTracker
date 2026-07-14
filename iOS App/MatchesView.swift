// MatchesView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

struct MatchesView: View {
    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var fields: FieldsModel
    @Environment(LiveMatchStore.self) private var liveMatches
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if matches.matches.isEmpty && !liveMatches.isLive {
                    emptyState
                } else {
                    List {
                        if liveMatches.isLive {
                            liveCard
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        ForEach(matches.matches) { summary in
                            NavigationLink(value: summary.id) {
                                MatchRow(summary: summary)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Matches")
            .navigationDestination(for: UUID.self) { id in
                if let summary = matches.matches.first(where: { $0.id == id }) {
                    MatchDetailView(summary: summary)
                }
            }
            .toolbar {
                // Coach live dashboard (team feature), most useful at iPad width.
                if horizontalSizeClass == .regular, entitlements.entitledToTeam,
                   !SettingsStore.shared.teamCode.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            CoachDashboardView(teamCode: SettingsStore.shared.teamCode)
                        } label: {
                            Image(systemName: "field.of.view.wide")
                        }
                    }
                }
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

    /// Watch-streamed match in progress: jump to the live sideline dashboard.
    private var liveCard: some View {
        NavigationLink {
            LiveMatchView(store: liveMatches, projector: liveProjector)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.heart)
                    .frame(width: 12, height: 12)
                    .glow(Theme.heart, radius: 6)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LIVE · Match in progress")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.turf)
                    if let update = liveMatches.latest {
                        Text("\(update.usGoals ?? 0)–\(update.themGoals ?? 0) · \(String(format: "%.1f km", update.distanceMeters / 1000))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.turfFlow, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    /// Field projector for the live position dot, resolved from streamed points.
    private var liveProjector: FieldProjector? {
        let coordinates = liveMatches.recentPoints.suffix(30).map(\.coordinate)
        guard !coordinates.isEmpty,
              let field = fields.store.bestMatch(for: Array(coordinates)) else { return nil }
        return FieldProjector(rectangle: field.rectangle)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.startDate, format: .dateTime.weekday().month().day().hour().minute())
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text(fieldName ?? "Unknown field")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let score {
                    Text(score)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(scoreTint, in: Capsule())
                } else if let position {
                    PositionBadge(role: position.role, side: position.side, confidence: position.confidence)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                metric(MatchFormat.distance(summary.distanceMeters), "Distance", Theme.pace)
                metric(MatchFormat.shortDuration(summary.duration), "Duration", Theme.signal)
                Spacer()
                if score != nil, let position {
                    PositionBadge(role: position.role, side: position.side, confidence: position.confidence)
                }
            }
        }
        .padding(16)
        .themedCard()
        .task { await loadBadge() }
    }

    private func metric(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label).captionLabel()
        }
    }

    /// "us–them" from logged goal events, when any exist.
    private var score: String? {
        guard let events = summary.record?.events, !events.isEmpty else { return nil }
        let us = events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = events.filter { $0.kind == .goalAgainstUs }.count
        guard us > 0 || them > 0 else { return nil }
        return "\(us)–\(them)"
    }

    private var scoreTint: Color {
        guard let events = summary.record?.events else { return Theme.bench }
        let us = events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = events.filter { $0.kind == .goalAgainstUs }.count
        if us > them { return Theme.goal }
        if us < them { return Theme.heart }
        return Theme.bench
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
