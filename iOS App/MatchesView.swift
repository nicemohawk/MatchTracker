// MatchesView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

struct MatchesView: View {
    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var fields: FieldsModel
    @Environment(LiveMatchStore.self) private var liveMatches
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(BacklogImporter.self) private var backlogImporter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            Group {
                if matches.matches.isEmpty && !liveMatches.isLive {
                    emptyState
                } else {
                    // ScrollView + LazyVStack (not List) so cards get scroll transitions and a
                    // pressed-state scale — List swallows both.
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if showBacklogTeaser {
                                backlogTeaser
                            }
                            // On iOS 26+ the live match rides in the tab bar's bottom accessory
                            // (see RootTabView), so this in-list card would be a duplicate affordance.
                            if #unavailable(iOS 26.0), liveMatches.isLive {
                                liveCard
                            }
                            ForEach(matches.matches) { summary in
                                NavigationLink(value: summary.id) {
                                    MatchRow(summary: summary)
                                }
                                .buttonStyle(PressableCardStyle())
                                .scrollTransition(.interactive(timingCurve: .easeOut),
                                                  axis: .vertical) { content, phase in
                                    content
                                        .opacity(phase.isIdentity ? 1 : 0.55)
                                        .scaleEffect(phase.isIdentity ? 1 : 0.965)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
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
            }
            .refreshable { await matches.refresh() }
            .overlay {
                if matches.isLoading && matches.matches.isEmpty {
                    ProgressView()
                }
            }
            .task { await backlogImporter.scanIfNeeded() }
            .sheet(isPresented: $showingImport) { BacklogImportView() }
        }
    }

    /// Quiet upsell for the historic-backlog import: shown once there's a meaningful backlog of
    /// workout-only matches and the player hasn't imported yet. Scan + teaser are free; the batch
    /// import itself is gated inside the sheet.
    private var showBacklogTeaser: Bool {
        backlogImporter.pendingCount >= 5 && !backlogImporter.hasImported
    }

    private var backlogTeaser: some View {
        Button {
            Haptics.selection()
            showingImport = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(Theme.turf)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(backlogImporter.pendingCount) past matches found")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Import your history to build fields & season trends")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "sparkles")
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.signal)
            }
            .padding(16)
            .themedCard()
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: update.distanceMeters)
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

/// Card press feedback: a quick settle-down scale, mirroring what a UICollectionView highlight
/// gives for free. Applied to the match cards now that they live in a ScrollView.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
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
                    HStack(spacing: 6) {
                        Text(fieldName ?? "Unknown field")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        formatBadge
                    }
                }
                Spacer()
                if let score {
                    Text(score)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(scoreTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.chipFill(scoreTint), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.chipStroke(scoreTint), lineWidth: 1))
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

    /// A small glyph + label for non-default match formats (pickup / indoor). `.match` shows nothing.
    @ViewBuilder
    private var formatBadge: some View {
        switch summary.record?.format ?? .match {
        case .match:
            EmptyView()
        case .smallSided:
            formatLabel(icon: "figure.cooldown", text: "Pickup")
        case .indoor:
            formatLabel(icon: "house", text: "Indoor")
        }
    }

    private func formatLabel(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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
        if us > them { return Theme.turf }
        if us < them { return Theme.loss }
        return Theme.bench
    }

    private func loadBadge() async {
        let detail = store.detailModel(for: summary)
        await detail.load()
        if let analytics = detail.analytics {
            // Indoor sessions carry only a placeholder position estimate — don't badge one.
            if summary.record?.format != .indoor {
                position = (analytics.position.role, analytics.position.side, analytics.position.confidence)
            }
            fieldName = analytics.fieldName
        } else if let fieldID = summary.record?.fieldID {
            // Record-only match: resolve the field name directly (no analytics available).
            fieldName = store.fields.field(id: fieldID)?.name
        }
    }
}
