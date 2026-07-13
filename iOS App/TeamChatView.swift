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
    @State private var isPosting = false

    private var recentMatches: [MatchSummary] {
        Array(matches.matches.prefix(10))
    }

    var body: some View {
        VStack(spacing: 0) {
            matchPicker
            Divider()
            commentList
            Divider()
            inputBar
        }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(comment.author).font(.caption.bold())
                                Text(comment.postedAt, style: .relative)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(comment.body).font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding()
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                TextField("Add a comment…", text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await post() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isPosting || selectedMatchID == nil)
            }
        }
        .padding()
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
            comments = try await uploads.fetchComments(match: matchID)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load comments: \(error.localizedDescription)"
        }
    }

    private func post() async {
        guard let matchID = selectedMatchID else { return }
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        isPosting = true
        defer { isPosting = false }

        let author = settings.playerName.isEmpty ? "Me" : settings.playerName
        let comment = MatchComment(matchUUID: matchID, author: author, body: body)
        comments.append(comment)   // optimistic
        draft = ""
        do {
            try await uploads.postComment(comment, match: matchID)
            errorMessage = nil
        } catch {
            comments.removeAll { $0.id == comment.id }
            draft = body
            errorMessage = "Couldn't post: \(error.localizedDescription)"
        }
    }
}
