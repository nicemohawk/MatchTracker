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
    @State private var clock = StageClock()
    /// What the scroll view has to show things in, and how much of it comes before the picture.
    @State private var visibleSize: CGSize = .zero
    @State private var answerHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum Sheet: String, Identifiable {
        case edit, score, share, map, video
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
        .onChange(of: sheet) { clock.pause() }
        .onDisappear { clock.pause() }
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
        ScrollViewReader { scroller in
            ScrollView {
                if isWide {
                    HStack(alignment: .top, spacing: 32) {
                        picture(detail).frame(maxWidth: 460)
                        VStack(alignment: .leading, spacing: 32) {
                            answer(detail)
                            chapters(detail, scroller)
                        }
                    }
                    .padding(32)
                } else {
                    VStack(spacing: 28) {
                        VStack(spacing: Self.answerSpacing) {
                            answer(detail)
                                .padding(.horizontal)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
                            picture(detail)
                        }
                        chapters(detail, scroller).padding(.horizontal)
                    }
                    .padding(.bottom, 32)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { visibleSize = $0 }
            // Any touch, on anything.
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in clock.endOpening() },
                                 including: clock.isOpening ? .all : .subviews)
        }
        .onChange(of: detail.analyticsRevision, initial: true) {
            guard let analytics = detail.analytics, analytics.hasRoute else { return }
            clock.load(analytics, events: detail.events)
            clock.playOpening(of: detail.matchIdentifier)
        }
    }

    private static let answerSpacing: CGFloat = 16
    private static let stage = "stage"

    /// How it went, before any picture.
    private func answer(_ detail: MatchDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            scoreline(detail)
            if let digest = detail.digest { DigestNumbers(digest: digest) }
            if let headline = detail.headline { Text(headline).font(.title3) }
        }
    }

    /// Room for the picture and the words side by side. Beside a sidebar there often isn't.
    private var isWide: Bool { horizontalSizeClass == .regular && visibleSize.width >= 700 }

    /// What's left of the first screen, so the whole pitch is on it. Big type keeps a pitch worth
    /// looking at and scrolls to it.
    private var stageHeight: CGFloat {
        // Beside the answer, what it shares the height with is its own margins and picker.
        let taken = isWide ? 112 : answerHeight + 2 * Self.answerSpacing
        return min(max(visibleSize.height - taken, 340), 620)
    }

    private func show(on scroller: ScrollViewProxy, _ play: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy) { scroller.scrollTo(Self.stage, anchor: .top) }
        play()
    }

    private func scoreline(_ detail: MatchDetailModel) -> some View {
        MatchScoreline(digest: detail.digest, fallbackTitle: detail.matchFormat.title, startDate: detail.matchStart) {
            sheet = .score
        }
    }

    @ViewBuilder
    private func picture(_ detail: MatchDetailModel) -> some View {
        if let analytics = detail.analytics, analytics.hasRoute {
            MatchStage(clock: clock, analytics: analytics, events: detail.events,
                       seasonHeat: store.season(SeasonSummary.Term(containing: detail.matchStart)).heat,
                       height: stageHeight)
                .id(Self.stage)
        } else if !detail.heartRateSeries.isEmpty {
            HeartRateHero(series: detail.heartRateSeries, start: detail.matchStart)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func chapters(_ detail: MatchDetailModel, _ scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            if let end = detail.suggestedTrimEnd {
                TrimSuggestion(end: end) { store.trim(detail.matchIdentifier, start: nil, end: end) }
            }
            MomentsChapter(detail: detail, onEdit: { sheet = .edit },
                           onShow: detail.analytics?.hasRoute == true ? { moment in show(on: scroller) { clock.show(moment) } } : nil)
            if let runs = detail.analytics?.keyRuns, !runs.isEmpty {
                BestRunsChapter(runs: runs, minutes: detail.minutes) { run in show(on: scroller) { clock.show(run) } }
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
        case .score: ScoreSheet(detail: detail)
        case .share: ShareMatchSheet(detail: detail, summary: summary, teamName: teamName)
        case .map: MatchMapView(detail: detail)
        case .video:
            NavigationStack { MatchVideoView(detail: detail) }
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
                    Text(digest?.opponent.map { "vs \($0)" } ?? digest?.fieldName ?? fallbackTitle)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Add the Score").font(.headline).foregroundStyle(.tint).frame(minHeight: 32)
                }
                Text(details).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edits the score")
    }

    private var details: String {
        let sameYear = Calendar.current.isDate(startDate, equalTo: Date(), toGranularity: .year)
        let day = startDate.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                                               : .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        let hasScore = digest?.result != nil
        let opponent = hasScore ? digest?.opponent.map { "vs \($0)" } : nil
        let field = hasScore || digest?.opponent != nil ? digest?.fieldName : nil
        return [opponent, day, startDate.formatted(date: .omitted, time: .shortened), field]
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
        case .won: return Theme.turf
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
