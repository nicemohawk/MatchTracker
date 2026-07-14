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
        // Indoor sessions have no heatmap, so open on Workrate — the first section they show.
        _section = State(initialValue: summary.record?.format == .indoor ? .workrate : .heatmap)
    }

    enum Section: String, CaseIterable, Identifiable {
        case heatmap = "Heatmap"
        case runs = "Runs"
        case workrate = "Workrate"
        case position = "Position"
        case events = "Events"
        case video = "Video"
        var id: String { rawValue }
    }

    @State private var section: Section
    @State private var ringProgress: Double = 0

    /// Indoor play has no GPS route, so the map/route-derived sections don't apply.
    private var isIndoor: Bool { summary.record?.format == .indoor }

    /// Sections offered for this match. Indoor reduces to the route-free trio.
    private var visibleSections: [Section] {
        isIndoor ? [.workrate, .events, .video] : Section.allCases
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                sectionPicker

                content
                    .padding(.horizontal)
                    .background(
                        Theme.headerGradient(Theme.sectionTint(section.rawValue))
                            .frame(height: 160)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    )
            }
            // Bottom-only: the hero header bleeds up to the very top of the scroll content (and
            // behind the translucent nav bar). Container horizontal padding is unchanged.
            .padding(.bottom)
        }
        // Clear the floating liquid-glass tab bar so the last element of every section
        // (e.g. the heatmap "Low → High" legend) isn't hidden behind it.
        .contentMargins(.bottom, 72, for: .scrollContent)
        // The hero wash is pinned to the ScrollView (not the scrolling content) so it runs UNDER
        // the translucent nav bar — the bar's glass blurs it rather than a hard seam cutting across.
        // It fades to clear at its bottom, melting into `Theme.background` with no visible edge.
        .background(alignment: .top) {
            heroWash
                .frame(height: 340)
                .ignoresSafeArea(edges: .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text(summary.startDate, format: .dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
        // No bar background/hairline, so the wash reads as one continuous field behind the glass.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await uploads.reupload(summary) }
                    } label: {
                        Label("Re-upload to team", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(uploads.isUploading)

                    if let detail = model.detail {
                        ExportMenu(detail: detail, summary: summary)
                    }

                    teamTagMenu
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task {
            model.attach(store.detailModel(for: summary))
            await model.detail?.load()
        }
    }

    /// Tag which of the player's teams this match was played for (multi-team support).
    @ViewBuilder
    private var teamTagMenu: some View {
        let memberships = SettingsStore.shared.teamMemberships
        if memberships.count > 1, let record = summary.record {
            Menu("Played for…") {
                ForEach(memberships) { membership in
                    Button {
                        var updated = record
                        updated.teamCode = membership.code
                        store.save(record: updated)
                    } label: {
                        if record.teamCode == membership.code {
                            Label(membership.code, systemImage: "checkmark")
                        } else {
                            Text(membership.code)
                        }
                    }
                }
            }
        }
    }

    /// Horizontally scrollable capsule chips — full section labels, each carrying its own semantic
    /// tint when selected. Replaces the segmented picker, which truncated ("Heatm…", "Workr…").
    private var sectionPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleSections) { item in
                        sectionChip(item).id(item)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 2)
            }
            .onChange(of: section) { _, newValue in
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func sectionChip(_ item: Section) -> some View {
        let isSelected = section == item
        let tint = Theme.sectionTint(item.rawValue)
        return Button {
            guard section != item else { return }
            withAnimation(.easeInOut(duration: 0.2)) { section = item }
        } label: {
            Text(item.rawValue)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(isSelected ? tint : Color.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(
                    Capsule().fill(isSelected ? Theme.chipFill(tint) : Theme.surfaceElevated)
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Theme.chipStroke(tint) : Theme.surfaceStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var header: some View {
        let detail = model.detail
        let workrate = detail?.analytics?.workrate.workrateScore ?? 0
        return VStack(spacing: 18) {
            HStack(spacing: 20) {
                WorkrateRing(score: workrate, progress: ringProgress)
                    .frame(width: 116, height: 116)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workrate").captionLabel()
                    Text("\(Int(workrate))")
                        .heroNumeral()
                        .foregroundStyle(.primary)
                    Text("Composite effort score")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                StatTile(title: "Duration", value: MatchFormat.shortDuration(summary.duration),
                         systemImage: "clock", tint: Theme.signal)
                if isIndoor {
                    // No route to integrate distance from — surface on-pitch time instead.
                    StatTile(title: "Time on Pitch",
                             value: MatchFormat.shortDuration(detail?.analytics?.workrate.timeOnPitch ?? summary.duration),
                             systemImage: "stopwatch", tint: Theme.pace)
                } else {
                    StatTile(title: "Distance",
                             value: MatchFormat.distance(detail?.analytics?.workrate.totalDistanceMeters ?? summary.distanceMeters),
                             systemImage: "figure.run", tint: Theme.pace)
                }
                StatTile(title: "Sprints", value: "\(detail?.analytics?.workrate.sprintCount ?? 0)",
                         systemImage: "hare", tint: Theme.sprint)
                if let hr = detail?.heartRate {
                    StatTile(title: "Avg HR", value: "\(Int(hr.average))",
                             systemImage: "heart.fill", tint: Theme.heart)
                } else {
                    StatTile(title: "Runs", value: "\(detail?.analytics?.workrate.runCount ?? 0)",
                             systemImage: "bolt.fill", tint: Theme.turf)
                }
            }
        }
        // Interior padding for the ring + numerals + chips; the wash below fills full width.
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
        .onChange(of: workrate) { _, newValue in
            withAnimation(.easeOut(duration: 1.0)) { ringProgress = min(1, newValue / 100) }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { ringProgress = min(1, workrate / 100) }
        }
    }

    /// Turf→signal hero wash, pinned behind the whole ScrollView (see `body`). It fades to clear at
    /// the bottom so it melts into `Theme.background` with no hard line, and — being a ScrollView
    /// background rather than scroll content — extends up under the translucent nav bar, which
    /// blurs it. Dark keeps a luminous tint; light stays a whisper (trait-adaptive via `tintWash`).
    private var heroWash: some View {
        LinearGradient(
            colors: [
                Theme.tintWash(Theme.turf, dark: 0.30, light: 0.14),
                Theme.tintWash(Theme.signal, dark: 0.20, light: 0.09),
                Color.clear
            ],
            startPoint: .top, endPoint: .bottom
        )
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
                case .video:
                    VideoHighlightsSection(detail: detail, matchStart: summary.startDate)
                }
            } else if section == .events {
                EventsSection(detail: detail)
            } else if section == .video {
                VideoHighlightsSection(detail: detail, matchStart: summary.startDate)
            } else if isIndoor {
                ContentUnavailableView("Indoor session — effort from heart rate", systemImage: "house",
                                       description: Text("This indoor session has no GPS route. Workrate is estimated from heart rate; heatmap, runs and position aren't available. The events timeline still works."))
                    .frame(minHeight: 200)
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

/// Apple-Fitness-style workrate ring: an angular `scoreRing` sweep over a faint track, glowing.
struct WorkrateRing: View {
    let score: Double
    /// 0…1 animated fill.
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceStroke, lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.scoreRing,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .glow(Theme.turf, radius: 8)
            Image(systemName: "bolt.fill")
                .font(.title3)
                .foregroundStyle(Theme.turf)
        }
        .accessibilityLabel("Workrate score \(Int(score)) of 100")
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
