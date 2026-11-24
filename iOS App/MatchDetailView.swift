// MatchDetailView.swift
// MatchTracker

import Combine
import MatchTrackerKit
import SwiftUI

/// The story of one match, in the order a player would tell it: the score, the picture, how I did,
/// the moments, my best runs, how hard it was. Everything measurable lives one push away.
struct MatchDetailView: View {
    let summary: MatchSummary
    @EnvironmentObject private var store: MatchStore
    @StateObject private var model = DetailLoader()
    @State private var sheet: Sheet?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum Sheet: String, Identifiable {
        case edit, share, map, video
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                switch detail.state {
                case .loading where detail.analytics == nil:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let reason) where detail.analytics == nil:
                    ContentUnavailableView {
                        Label("Couldn’t Load This Match", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(reason)
                    } actions: {
                        Button("Try Again") { Task { await detail.retry() } }
                    }
                default:
                    story(detail)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $sheet) { sheet in
            if let detail = model.detail { content(of: sheet, detail) }
        }
        .confirmationDialog("Delete this match?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Match", role: .destructive) {
                Task {
                    _ = await store.delete(summary)
                    dismiss()
                }
            }
        } message: {
            Text("It will be removed from MatchTracker and, when possible, from Apple Health.")
        }
        .task {
            model.attach(store.detailModel(for: summary))
            await model.detail?.load()
        }
    }

    // MARK: - Story

    @ViewBuilder
    private func story(_ detail: MatchDetailModel) -> some View {
        ScrollView {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 32) {
                    picture(detail).frame(maxWidth: 460)
                    VStack(alignment: .leading, spacing: 32) {
                        scoreline(detail)
                        chapters(detail)
                    }
                }
                .padding(32)
            } else {
                VStack(spacing: 28) {
                    scoreline(detail).padding(.horizontal)
                    picture(detail)
                    chapters(detail).padding(.horizontal)
                }
                .padding(.bottom, 32)
            }
        }
    }

    private func scoreline(_ detail: MatchDetailModel) -> some View {
        MatchScoreline(digest: detail.digest, fallbackTitle: detail.matchFormat.title, startDate: detail.matchStart) {
            sheet = .edit
        }
    }

    @ViewBuilder
    private func picture(_ detail: MatchDetailModel) -> some View {
        if let analytics = detail.analytics, analytics.hasRoute {
            MatchStage(analytics: analytics, events: detail.events, matchStart: detail.matchStart,
                       seasonHeat: store.season(SeasonSummary.Term(containing: detail.matchStart)).heat)
        } else if !detail.heartRateSeries.isEmpty {
            HeartRateHero(series: detail.heartRateSeries, start: detail.matchStart)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func chapters(_ detail: MatchDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            if let digest = detail.digest {
                VStack(alignment: .leading, spacing: 14) {
                    MatchNumbers(digest: digest)
                    if let headline = detail.headline {
                        Text(headline).font(.title3)
                    }
                }
            }
            if let end = detail.suggestedTrimEnd {
                TrimSuggestion(end: end) { store.trim(detail.matchIdentifier, start: nil, end: end) }
            }
            MomentsChapter(detail: detail, onEdit: { sheet = .edit }, onVideo: { sheet = .video })
            if let runs = detail.analytics?.keyRuns, !runs.isEmpty {
                BestRunsChapter(runs: runs)
            }
            if let analytics = detail.analytics {
                EffortChapter(detail: detail, analytics: analytics)
            }
            if let notes = detail.record?.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes").font(.title2.bold())
                    Text(notes)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var teamName: String? {
        SettingsStore.shared.teamMemberships.first { $0.code == SettingsStore.shared.teamCode }?.name
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Share", systemImage: "square.and.arrow.up") { sheet = .share }
                .disabled(model.detail?.analytics == nil)
            MatchCommentsButton(matchUUID: summary.id)
            Menu {
                Button("Edit Match", systemImage: "pencil") { sheet = .edit }
                Button("Video", systemImage: "video") { sheet = .video }
                if model.detail?.analytics?.hasRoute == true {
                    Button("Show on Map", systemImage: "map") { sheet = .map }
                }
                Divider()
                Button("Delete Match", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    @ViewBuilder
    private func content(of sheet: Sheet, _ detail: MatchDetailModel) -> some View {
        switch sheet {
        case .edit: EditMatchView(detail: detail)
        case .share: ShareMatchSheet(detail: detail, summary: summary, teamName: teamName)
        case .map: MatchMapView(detail: detail)
        case .video:
            NavigationStack {
                ScrollView { VideoHighlightsSection(detail: detail, matchStart: detail.matchStart).padding() }
                    .navigationTitle("Video")
                    .navigationBarTitleDisplayMode(.inline)
                    .closeToolbar()
            }
        }
    }
}

// MARK: - Scoreline

/// Result, score, when and where. Tapping it is how you fix any of them.
private struct MatchScoreline: View {
    let digest: MatchDigest?
    let fallbackTitle: String
    let startDate: Date
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(spacing: 4) {
                if let digest, let result = digest.result, let us = digest.goalsUs, let them = digest.goalsThem {
                    Text(word(result)).font(.headline).foregroundStyle(color(result))
                    Text("\(us) – \(them)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                } else {
                    Text(digest?.opponent.map { "vs \($0)" } ?? fallbackTitle)
                        .font(.largeTitle.bold())
                    Text("Add Score").font(.subheadline).foregroundStyle(.tint)
                }
                Text(details).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edits the match")
    }

    private var details: String {
        let sameYear = Calendar.current.isDate(startDate, equalTo: Date(), toGranularity: .year)
        let day = startDate.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                                               : .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        let opponent = digest?.result == nil ? nil : digest?.opponent.map { "vs \($0)" }
        return [opponent, day, startDate.formatted(date: .omitted, time: .shortened), digest?.fieldName]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func word(_ result: MatchDigest.Result) -> String {
        switch result {
        case .won: return "Won"
        case .drawn: return "Drew"
        case .lost: return "Lost"
        }
    }

    private func color(_ result: MatchDigest.Result) -> Color {
        switch result {
        case .won: return .green
        case .drawn: return .secondary
        case .lost: return .red
        }
    }
}

/// Offered, never applied: the recording ran on after the match did.
private struct TrimSuggestion: View {
    let end: Date
    let onTrim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This recording kept going after you stopped playing.")
                .font(.body)
            Button("End It at \(end.formatted(date: .omitted, time: .shortened))", action: onTrim)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }
}

extension View {
    /// The standard way out of a sheet.
    func closeToolbar() -> some View { modifier(CloseToolbar()) }
}

private struct CloseToolbar: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// Bridges the store's cached `MatchDetailModel` (a reference type) into a `StateObject` so the
/// view re-renders as its `@Published` analytics load.
@MainActor
final class DetailLoader: ObservableObject {
    @Published private(set) var detail: MatchDetailModel?
    private var cancellable: AnyCancellable?

    func attach(_ model: MatchDetailModel) {
        guard detail !== model else { return }
        detail = model
        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }
}
