//
//  TeamChatView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Per-match comment thread for the team (parents/coaches reacting to a match). Polls the
/// backend; posting is idempotent by comment id. Entitlement-gated by callers.
struct TeamChatView: View {
    @EnvironmentObject private var uploads: UploadService
    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var selectedMatchID: UUID?
    @State private var comments: [MatchComment] = []
    @State private var draft = ""
    @State private var errorMessage: String?
    /// Comments whose network post failed — rendered with a quiet retry affordance.
    @State private var failedIDs: Set<UUID> = []

    /// A gap longer than this between consecutive messages earns a timestamp separator.
    private static let timestampGap: TimeInterval = 5 * 60

    private var recentMatches: [MatchSummary] {
        Array(matches.matches.prefix(10))
    }

    /// The name posts are authored under — used to right-align the wearer's own bubbles.
    private var myAuthorName: String {
        settings.playerName.isEmpty ? "Me" : settings.playerName
    }

    /// Oldest first, so the thread reads top-to-bottom and the newest bubble sits at the bottom.
    private var sortedComments: [MatchComment] {
        comments.sorted { $0.postedAt < $1.postedAt }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && selectedMatchID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            matchPicker
            Divider()
            commentList
            Divider()
            inputBar
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Match Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedMatchID) { await pollLoop() }
        .onAppear {
            if selectedMatchID == nil { selectedMatchID = recentMatches.first?.id }
        }
    }

    private var matchPicker: some View {
        Picker("Match", selection: $selectedMatchID) {
            ForEach(recentMatches) { summary in
                Text(summary.startDate.formatted(date: .abbreviated, time: .shortened))
                    .tag(Optional(summary.id))
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var commentList: some View {
        if comments.isEmpty {
            ContentUnavailableView(
                "No Comments Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Be the first to react to this match.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(sortedComments.enumerated()), id: \.element.id) { index, comment in
                            if showsTimestamp(at: index) {
                                Text(comment.postedAt, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 2)
                            }
                            MessageRow(
                                comment: comment,
                                isMine: comment.author == myAuthorName,
                                hasFailed: failedIDs.contains(comment.id),
                                onRetry: { Task { await retry(comment) } }
                            )
                            .id(comment.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding()
                }
                .onChange(of: sortedComments.count) {
                    guard let last = sortedComments.last else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.heart)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.surfaceElevated))
                    .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 1))

                Button {
                    post()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.turf)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Whether a timestamp separator precedes the message at `index`: always for the first, then
    /// only when the gap since the previous message is long enough to feel like a new beat.
    private func showsTimestamp(at index: Int) -> Bool {
        let ordered = sortedComments
        guard index > 0, index < ordered.count else { return index == 0 }
        return ordered[index].postedAt.timeIntervalSince(ordered[index - 1].postedAt) > Self.timestampGap
    }

    // MARK: - Networking

    /// Refresh every 15 s while this match is selected; cancels naturally on selection change.
    private func pollLoop() async {
        guard let matchID = selectedMatchID else { return }
        while !Task.isCancelled && selectedMatchID == matchID {
            await refresh(matchID: matchID)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func refresh(matchID: UUID) async {
        do {
            let fetched = try await uploads.fetchComments(match: matchID)
            // Preserve optimistic / failed messages the server hasn't echoed back yet (posts are
            // idempotent by id, so a confirmed message simply replaces its local twin).
            let fetchedIDs = Set(fetched.map(\.id))
            let pending = comments.filter { !fetchedIDs.contains($0.id) }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                comments = fetched + pending
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load comments: \(error.localizedDescription)"
        }
    }

    private func post() {
        guard let matchID = selectedMatchID else { return }
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }

        let comment = MatchComment(matchUUID: matchID, author: myAuthorName, body: body)
        Haptics.selection()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            comments.append(comment)   // optimistic
        }
        draft = ""
        Task { await send(comment) }
    }

    private func retry(_ comment: MatchComment) async {
        withAnimation(.easeInOut(duration: 0.2)) { _ = failedIDs.remove(comment.id) }
        await send(comment)
    }

    private func send(_ comment: MatchComment) async {
        do {
            try await uploads.postComment(comment, match: comment.matchUUID)
            withAnimation(.easeInOut(duration: 0.2)) { _ = failedIDs.remove(comment.id) }
            errorMessage = nil
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) { _ = failedIDs.insert(comment.id) }
        }
    }
}

/// One chat message: the wearer's own posts sit right-aligned in a turf-tinted bubble; teammates
/// sit left with a deterministically tinted initials avatar and a name caption. A long-press
/// reveals the exact time; a failed post marks itself quietly and offers a retry.
private struct MessageRow: View {
    let comment: MatchComment
    let isMine: Bool
    let hasFailed: Bool
    let onRetry: () -> Void

    @State private var revealTime = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine {
                Spacer(minLength: 44)
                column
            } else {
                avatar
                column
                Spacer(minLength: 44)
            }
        }
    }

    private var column: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
            if !isMine {
                Text(comment.author)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(comment.body)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .overlay(bubbleStroke)

            if hasFailed {
                Button(action: onRetry) {
                    Label("Couldn't post — tap to retry", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if revealTime {
                Text(comment.postedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onLongPressGesture {
            withAnimation(.easeInOut(duration: 0.2)) { revealTime.toggle() }
        }
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    @ViewBuilder private var bubbleBackground: some View {
        if isMine {
            bubbleShape.fill(Theme.chipFill(Theme.turf))
        } else {
            bubbleShape.fill(Theme.surfaceElevated)
        }
    }

    @ViewBuilder private var bubbleStroke: some View {
        if isMine {
            bubbleShape.strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1)
        } else {
            bubbleShape.strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        }
    }

    private var avatar: some View {
        let tint = Self.tint(for: comment.author)
        return Text(Self.initials(for: comment.author))
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Theme.chipFill(tint)))
            .overlay(Circle().strokeBorder(Theme.chipStroke(tint), lineWidth: 1))
    }

    /// Up to two initials from the author's name.
    private static func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Deterministic accent from the author's name so a given teammate always keeps the same hue.
    /// Avoids `String.hashValue` (seeded per-launch) in favor of a stable scalar sum — matching
    /// `CommentsSection`.
    private static func tint(for name: String) -> Color {
        let palette: [Color] = [Theme.turf, Theme.signal, Theme.pace, Theme.sprint, Theme.heart, Theme.bench]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
