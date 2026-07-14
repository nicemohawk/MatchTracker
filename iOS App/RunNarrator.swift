// RunNarrator.swift
// MatchTracker
//
// On-device, Apple-Intelligence labeling for the Runs highlights carousel. Turns the deterministic
// per-run features + match context into short, energetic card titles using the iOS 26 Foundation
// Models framework — entirely on device, no network. Every model touchpoint is gated behind
// availability and degrades silently to the deterministic `reasons` when the model is missing,
// slow, or errors: the UI never surfaces a failure, it just keeps its grounded fallback title.

import Foundation
import Observation
import MatchTrackerKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The compact, deterministic facts about one candidate run handed to the model. Deliberately free
/// of any FoundationModels type so the view layer can build it without importing the framework.
struct RunFeature {
    var id: UUID          // == RunSegment.id
    var index: Int        // stable index the model echoes back in each label
    var minute: Int
    var distanceMeters: Double
    var peakSpeedKmh: Double
    var direction: String            // "" when the attack direction is unknown
    var reasons: [String]
    var nearbyEventKinds: [String]
}

/// Match-level facts that frame the runs (final score + goal minutes).
struct MatchNarrationContext {
    var finalScore: String
    var goalMinutes: [Int]
}

/// Generates and caches highlight titles for a match's runs. `@Observable` so the carousel updates
/// the moment labels arrive; all state is `@MainActor`-isolated.
@MainActor
@Observable
final class RunNarrator {
    /// matchID → (runID → AI title). A present (even empty) entry means the match was processed,
    /// so scrubbing back and forth never re-runs the model.
    private(set) var titlesByMatch: [UUID: [UUID: String]] = [:]

    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var didPrewarm = false
    /// Held as `AnyObject` because `LanguageModelSession` only exists on iOS 26; cast back inside
    /// availability-gated code so the surrounding type stays buildable on the 17.0 deployment floor.
    @ObservationIgnored private var sessionBox: AnyObject?

    /// The AI title for a run, once one has been generated (nil until then, or forever on a device
    /// without Apple Intelligence).
    func title(forRun runID: UUID, inMatch matchID: UUID) -> String? {
        titlesByMatch[matchID]?[runID]
    }

    /// Whether the on-device model can label runs on this device right now.
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    /// Warm the model on first sight of the Runs section so the first real request returns quickly.
    /// A no-op when the model is unavailable or already warmed.
    func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        guard #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available else { return }
        makeSession().prewarm()
    }

    /// Label a match's candidate runs, publishing titles when they arrive. Cached per match id: a
    /// repeat call for an already-processed (or in-flight) match returns immediately, so scrubbing
    /// the carousel never re-runs the model.
    func generateLabels(matchID: UUID, features: [RunFeature], context: MatchNarrationContext) async {
        guard titlesByMatch[matchID] == nil, !inFlight.contains(matchID), !features.isEmpty else { return }
        guard #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available else {
            titlesByMatch[matchID] = [:]   // mark processed; the deterministic reasons stand in
            return
        }
        inFlight.insert(matchID)
        defer { inFlight.remove(matchID) }
        let titles = await label(features: features, context: context)
        titlesByMatch[matchID] = titles ?? [:]
    }

    // MARK: - Model plumbing (iOS 26+)

    @available(iOS 26.0, *)
    private func makeSession() -> LanguageModelSession {
        if let existing = sessionBox as? LanguageModelSession { return existing }
        let session = LanguageModelSession(instructions: Self.instructions)
        sessionBox = session
        return session
    }

    @available(iOS 26.0, *)
    private func label(features: [RunFeature], context: MatchNarrationContext) async -> [UUID: String]? {
        let prompt = Self.prompt(features: features, context: context)
        let indexToID = Dictionary(features.map { ($0.index, $0.id) }, uniquingKeysWith: { first, _ in first })
        do {
            let labels = try await respondWithTimeout(prompt: prompt, seconds: 5)
            var result: [UUID: String] = [:]
            for label in labels.labels {
                guard let id = indexToID[label.runIndex] else { continue }
                let title = label.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { result[id] = title }
            }
            return result.isEmpty ? nil : result
        } catch {
            MatchLog.error("Run labeling skipped: \(error.localizedDescription)", category: "RunNarrator")
            return nil
        }
    }

    /// Race the guided-generation request against a timeout so a stalled model can never block the
    /// carousel; either failure path returns via the caller's deterministic fallback.
    @available(iOS 26.0, *)
    private func respondWithTimeout(prompt: String, seconds: Double) async throws -> RunLabels {
        let session = makeSession()
        return try await withThrowingTaskGroup(of: RunLabels?.self) { group in
            group.addTask { @MainActor in
                try await session.respond(to: prompt, generating: RunLabels.self).content
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil   // timeout sentinel
            }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else { throw TimeoutError() }
            guard let labels = outcome else { throw TimeoutError() }
            return labels
        }
    }

    private struct TimeoutError: Error {}

    // MARK: - Prompt construction (framework-free, deterministic)

    static let instructions = """
        You label a soccer player's most notable runs for a post-match highlights card. Write one \
        short title per run. Each title must be specific and grounded ONLY in the facts given for \
        that run — never invent events, opponents, players, or outcomes. Keep every title to six \
        words or fewer, energetic, plain text, no emoji. Echo back each run's given index.
        """

    static func prompt(features: [RunFeature], context: MatchNarrationContext) -> String {
        let goals = context.goalMinutes.isEmpty
            ? "none"
            : context.goalMinutes.map { "\($0)'" }.joined(separator: ", ")
        var lines = ["Match context: final score \(context.finalScore), goals at \(goals).",
                     "Runs to label:"]
        for feature in features {
            var parts = ["#\(feature.index)",
                         "\(feature.minute)'",
                         String(format: "%.0f m", feature.distanceMeters),
                         String(format: "%.1f km/h peak", feature.peakSpeedKmh)]
            if !feature.direction.isEmpty { parts.append(feature.direction) }
            if !feature.reasons.isEmpty { parts.append("why: " + feature.reasons.joined(separator: "; ")) }
            if !feature.nearbyEventKinds.isEmpty { parts.append("near: " + feature.nearbyEventKinds.joined(separator: ", ")) }
            lines.append(parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Guided-generation schema (iOS 26+)

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct RunLabels {
    @Guide(description: "One label per run in the prompt, echoing each run's given index.", .maximumCount(6))
    var labels: [RunLabel]
}

@available(iOS 26.0, *)
@Generable
struct RunLabel {
    @Guide(description: "The run's index exactly as given in the prompt.")
    var runIndex: Int
    @Guide(description: "Six words or fewer, energetic, no emoji, grounded only in the run's facts.")
    var title: String
}
#endif
