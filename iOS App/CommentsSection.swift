// CommentsSection.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Strava-style social proof under the analysis: a lightweight team-chat thread on a single match.
/// Reading is not paywalled — it appears whenever a team code is configured. Comments load lazily
/// (a `.task` fires when the section scrolls into view) so they never block the detail screen, and
/// this backend endpoint may 404 on older servers, so every failure degrades to a quiet one-liner
/// rather than an alarming empty state.
struct CommentsSection: View {
    /// The backend match UUID (matches the `uuid` uploads send in the payload).
    let matchUUID: UUID
    @EnvironmentObject private var uploads: UploadService

    @State private var comments: [MatchComment] = []
    @State private var phase: Phase = .loading
    @State private var draft: String = ""
    /// Comments whose network post failed — rendered subtly with a retry affordance.
    @State private var failedIDs: Set<UUID> = []

    private enum Phase { case loading, loaded, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeaderBar(title: "Comments", tint: Theme.signal,
                             subtitle: "Team chat on this match")

            content

            composer
        }
        .padding(.horizontal)
        .task {
            // Lazy load: only reaches here once the section scrolls into view.
            guard phase == .loading else { return }
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                placeholderRow
                placeholderRow
            }
            .redacted(reason: .placeholder)
        case .failed:
            Text("Comments unavailable")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded:
            if comments.isEmpty {
                Text("Be the first to comment")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sortedComments) { comment in
                        CommentRow(
                            comment: comment,
                            hasFailed: failedIDs.contains(comment.id),
                            onRetry: { Task { await retry(comment) } }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
    }

    /// Rounded composer pinned at the section bottom.
    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(Theme.surfaceElevated)
                )
                .overlay(
                    Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 1)
                )

            Button {
                post()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.turf)
            }
            .buttonStyle(.plain)
            .disabled(trimmedDraft.isEmpty)
            .opacity(trimmedDraft.isEmpty ? 0.4 : 1)
        }
        .padding(.top, 4)
    }

    private var placeholderRow: some View {
        CommentRow(
            comment: MatchComment(matchUUID: matchUUID, author: "Placeholder Name",
                                  body: "A teammate's comment goes right about here."),
            hasFailed: false,
            onRetry: {}
        )
    }

    // MARK: - Data

    /// Newest last — reads top-to-bottom like a conversation.
    private var sortedComments: [MatchComment] {
        comments.sorted { $0.postedAt < $1.postedAt }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        do {
            let fetched = try await uploads.fetchComments(match: matchUUID)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                comments = fetched
                phase = .loaded
            }
        } catch {
            phase = .failed
        }
    }

    private func post() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        let author = SettingsStore.shared.playerName.isEmpty ? "Me" : SettingsStore.shared.playerName
        let comment = MatchComment(matchUUID: matchUUID, author: author, body: text)

        // Optimistic insert with a gentle spring, then the network call.
        Haptics.selection()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            comments.append(comment)
            phase = .loaded
        }
        draft = ""
        Task { await send(comment) }
    }

    private func retry(_ comment: MatchComment) async {
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = failedIDs.remove(comment.id)
        }
        await send(comment)
    }

    private func send(_ comment: MatchComment) async {
        do {
            try await uploads.postComment(comment, match: matchUUID)
            withAnimation(.easeInOut(duration: 0.2)) {
                _ = failedIDs.remove(comment.id)
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) {
                _ = failedIDs.insert(comment.id)
            }
        }
    }
}

/// One comment: an initials avatar (deterministically tinted from the author's name), the author
/// and a relative timestamp, then the body. A failed post marks itself quietly and offers a retry.
private struct CommentRow: View {
    let comment: MatchComment
    let hasFailed: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                    Text(comment.postedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(comment.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if hasFailed {
                    Button(action: onRetry) {
                        Label("Couldn't post — tap to retry", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatar: some View {
        let tint = Self.tint(for: comment.author)
        return Text(Self.initials(for: comment.author))
            .font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
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
    /// Avoids `String.hashValue` (seeded per-launch) in favor of a stable scalar sum.
    private static func tint(for name: String) -> Color {
        let palette: [Color] = [Theme.turf, Theme.signal, Theme.pace, Theme.sprint, Theme.heart, Theme.bench]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
