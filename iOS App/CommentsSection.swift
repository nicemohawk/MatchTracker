// CommentsSection.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// The toolbar button that opens a match's comments, with how many there are.
/// Draws nothing when the player has no team to talk to.
struct MatchCommentsButton: View {
    let matchUUID: UUID

    @EnvironmentObject private var settings: SettingsStore
    @State private var count: Int?
    @State private var isShowingComments = false

    var body: some View {
        if !settings.teamCode.isEmpty {
            Button { isShowingComments = true } label: {
                if let count, count > 0 {
                    Label("\(count)", systemImage: "bubble")
                        .labelStyle(.titleAndIcon)
                        .monospacedDigit()
                } else {
                    Image(systemName: "bubble")
                }
            }
            .accessibilityLabel("Comments")
            .accessibilityValue(count.map { $0 == 0 ? "None yet" : "\($0)" } ?? "")
            .task(id: matchUUID) {
                count = try? await TeamService.comments(match: matchUUID).count
            }
            .sheet(isPresented: $isShowingComments) {
                MatchCommentsSheet(matchUUID: matchUUID, count: $count)
            }
        }
    }
}

/// Stands in wherever match detail still embeds comments: the same button, on a line of its own.
struct CommentsSection: View {
    let matchUUID: UUID

    var body: some View {
        MatchCommentsButton(matchUUID: matchUUID)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal)
    }
}

/// What the team said about one match.
struct MatchCommentsSheet: View {
    let matchUUID: UUID
    var count: Binding<Int?> = .constant(nil)

    @EnvironmentObject private var settings: SettingsStore
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var comments: [MatchComment] = []
    @State private var phase: Phase = .loading
    @State private var problems: [UUID: Problem] = [:]
    /// Written here; kept on screen until the server has them.
    @State private var ownIDs: Set<UUID> = []
    @State private var draft = ""
    @State private var authorName = ""
    @State private var isShowingPlan = false
    @State private var sentCount = 0
    @FocusState private var isWriting: Bool

    private enum Phase: Equatable { case loading, loaded, failed(String) }
    private enum Problem { case notSent, needsPlan }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Asked for once, so nobody posts as nobody.
    private var needsName: Bool { settings.playerName.isEmpty }

    private var author: String {
        needsName ? authorName.trimmingCharacters(in: .whitespaces) : settings.playerName
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom) {
                    if case .failed = phase {} else { composer }
                }
                .navigationTitle("Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .task { await poll() }
        .sensoryFeedback(.success, trigger: sentCount)
        .sheet(isPresented: $isShowingPlan) { PaywallView(entitlements: entitlements) }
        .onChange(of: comments.count) { _, newCount in
            if phase == .loaded { count.wrappedValue = newCount }
        }
    }

    // MARK: Thread

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load comments", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    phase = .loading
                    Task { await refresh() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .loaded where comments.isEmpty:
            ContentUnavailableView("No comments yet", systemImage: "bubble",
                                   description: Text("Say something about this match. Your team will see it."))
        case .loaded:
            ScrollViewReader { proxy in
                List(comments) { comment in
                    row(comment)
                        .id(comment.id)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable { await refresh() }
                .onChange(of: comments.last?.id) { _, last in
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(comments.last?.id, anchor: .bottom) }
            }
        }
    }

    private func row(_ comment: MatchComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { byline(comment) }
                VStack(alignment: .leading, spacing: 2) { byline(comment) }
            }
            Text(comment.body)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            switch problems[comment.id] {
            case .notSent:
                Button("Not sent. Try again.") { Task { await send(comment) } }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .tint(Theme.loss)
            case .needsPlan:
                Button("Not sent. Commenting is part of the Team plan.") { isShowingPlan = true }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .multilineTextAlignment(.leading)
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func byline(_ comment: MatchComment) -> some View {
        TeamPlayerName(name: comment.author)
            .font(.subheadline.weight(.semibold))
        Text(comment.postedAt, format: .relative(presentation: .named))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if needsName {
                TextField("Your name", text: $authorName)
                    .textContentType(.name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isWriting)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 22))
                Button("Send", systemImage: "arrow.up", action: post)
                    .labelStyle(.iconOnly)
                    .fontWeight(.semibold)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(trimmedDraft.isEmpty || author.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Data

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func refresh() async {
        do {
            let fetched = try await TeamService.comments(match: matchUUID)
            let fetchedIDs = Set(fetched.map(\.id))
            comments = (fetched + comments.filter { !fetchedIDs.contains($0.id) && ownIDs.contains($0.id) })
                .sorted { $0.postedAt < $1.postedAt }
            phase = .loaded
            count.wrappedValue = comments.count
        } catch {
            // Comments already on screen stay there; the next refresh may do better.
            if phase != .loaded && !Task.isCancelled { phase = .failed(TeamService.explain(error)) }
        }
    }

    private func post() {
        if needsName { settings.playerName = author }
        let comment = MatchComment(matchUUID: matchUUID, author: author, body: trimmedDraft)
        draft = ""
        ownIDs.insert(comment.id)
        comments.append(comment)
        phase = .loaded
        Task { await send(comment) }
    }

    private func send(_ comment: MatchComment) async {
        problems[comment.id] = nil
        do {
            try await TeamService.post(comment)
            sentCount += 1
        } catch {
            problems[comment.id] = TeamService.needsPlan(error) ? .needsPlan : .notSent
        }
    }
}
