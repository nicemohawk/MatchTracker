// CohortBenchmarkCard.swift
// MatchTracker
//
// "How you compare" — the peer-cohort benchmarking card that lets a player see where they rank
// against an age band, a position, or everyone (benchmark gap #4: Catapult One / SoccerBee rank
// players vs age group / position / world; our roster leaderboard is intra-team only). Mounted in
// TeamView under the leaderboard. Each metric gets a labeled percentile bar; a chip row swaps the
// cohort and refetches. Degrades like FormationView: 404 / no data → a quiet "unlocks as the
// community grows" one-liner (never an error); no API key → hidden entirely.

import SwiftUI
import MatchTrackerKit

struct CohortBenchmarkCard: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cohort: BenchmarkCohort = .ageBand
    @State private var state: LoadState = .loading
    /// Drives the springy percentile-fill entrance; flips true once bars are on screen.
    @State private var appeared = false

    enum LoadState {
        case loading
        case loaded(CohortBenchmark)
        case insufficientData
    }

    var body: some View {
        // No API key yet (unsigned/CI build, or key not bootstrapped) → hidden entirely, exactly
        // like a feature that hasn't unlocked. Building the client here (rather than adding an
        // UploadService passthrough) keeps this wave's file ownership to the card + TeamView; it
        // mirrors UploadService's own `client` construction.
        if let client {
            content
                .task(id: cohort) { await load(using: client) }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            cohortPicker
            body(for: state)
        }
        .padding(18)
        .themedCard()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.turf)
                Text("How you compare")
                    .font(.system(.headline, design: .rounded).weight(.bold))
            }
            if case .loaded(let benchmark) = state {
                Text(caption(for: benchmark))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "vs 1,240 in 30–39 · Midfield" — cohort descriptor plus the (k-anonymised) sample size.
    private func caption(for benchmark: CohortBenchmark) -> String {
        "vs \(Self.grouped(benchmark.sampleSize)) in \(benchmark.cohort)"
    }

    // MARK: - Cohort picker

    private var cohortPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BenchmarkCohort.allCases) { option in
                    chip(option)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ option: BenchmarkCohort) -> some View {
        let isSelected = option == cohort
        return Button {
            guard option != cohort else { return }
            Haptics.selection()
            appeared = false
            cohort = option
        } label: {
            Text(option.label)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Theme.turf : Color.secondary)
                .background(
                    Capsule().fill(isSelected ? Theme.chipFill(Theme.turf) : Theme.surfaceElevated)
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Theme.chipStroke(Theme.turf) : Theme.surfaceStroke,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body states

    @ViewBuilder
    private func body(for state: LoadState) -> some View {
        switch state {
        case .loading:
            metricList(placeholder: true)
        case .loaded(let benchmark):
            metricList(for: benchmark)
            rewards(for: benchmark)
        case .insufficientData:
            // Quiet one-liner — never an error. Switching to "Everyone" is the likeliest way to
            // land in a cohort that's already crossed the k-anonymity floor.
            Text("Benchmarks unlock as the community grows.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func metricList(for benchmark: CohortBenchmark) -> some View {
        VStack(spacing: 16) {
            ForEach(Array(Self.metrics(benchmark.percentiles).enumerated()), id: \.offset) { index, metric in
                percentileBar(label: metric.label, percentile: metric.percentile, tint: metric.tint, index: index)
            }
        }
    }

    /// Redacted, shimmering placeholder bars while the first fetch is in flight.
    private func metricList(placeholder: Bool) -> some View {
        VStack(spacing: 16) {
            ForEach(Self.metricLabels.indices, id: \.self) { index in
                percentileBar(label: Self.metricLabels[index], percentile: 0, tint: Theme.bench, index: index)
            }
        }
        .redacted(reason: .placeholder)
        .benchmarkShimmer()
    }

    private func percentileBar(label: String, percentile: Double, tint: Color, index: Int) -> some View {
        let clamped = max(0, min(100, percentile))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(Self.ordinal(clamped))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceElevated)
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillWidth(clamped, in: geometry.size.width))
                }
            }
            .frame(height: 8)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82).delay(Double(index) * 0.05),
            value: appeared
        )
    }

    /// The animated fill width: 0 before appearance, the true fraction after (or immediately when
    /// Reduce Motion is on, so nothing animates).
    private func fillWidth(_ percentile: Double, in totalWidth: CGFloat) -> CGFloat {
        let shown = (appeared || reduceMotion) ? CGFloat(percentile) / 100 : 0
        return totalWidth * shown
    }

    // MARK: - Contribution rewards

    /// Optional touchline-walk contribution rewards (streak / badges). Rendered only when present.
    @ViewBuilder
    private func rewards(for benchmark: CohortBenchmark) -> some View {
        if benchmark.contributionStreak != nil || benchmark.badgeCount != nil {
            HStack(spacing: 14) {
                if let streak = benchmark.contributionStreak {
                    rewardTag(icon: "flame.fill", tint: Theme.sprint,
                              text: "\(streak)-walk streak")
                }
                if let badges = benchmark.badgeCount {
                    rewardTag(icon: "rosette", tint: Theme.turf,
                              text: "\(badges) \(badges == 1 ? "badge" : "badges")")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private func rewardTag(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(text).font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.chipFill(tint)))
        .overlay(Capsule().strokeBorder(Theme.chipStroke(tint), lineWidth: 1))
    }

    // MARK: - Fetch

    private func load(using client: APIClient) async {
        if case .loaded = state {} else { state = .loading }
        do {
            let benchmark = try await client.benchmark(cohort: cohort)
            state = .loaded(benchmark)
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { appeared = true }
            }
        } catch {
            // 404 (insufficient_data below the k-anonymity floor, or an older backend without the
            // endpoint) collapses to the quiet unlock copy — and so does any other failure, since a
            // benchmark card must never shout an error in the middle of the Team tab.
            state = .insufficientData
        }
    }

    // MARK: - Client

    /// A benchmark client, or nil when there's no API key yet (→ card hidden). Mirrors
    /// `UploadService.client`, reading the same Keychain key / base URL / device id so no
    /// UploadService change is needed for this wave.
    private var client: APIClient? {
        guard let key = KeychainHelper.string(forKey: "apiKey"), !key.isEmpty else { return nil }
        return APIClient(baseURL: settings.baseURL, apiKey: key, deviceID: Self.deviceID)
    }

    private static let deviceID: UUID = {
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        if let string = defaults.string(forKey: "deviceID"), let id = UUID(uuidString: string) {
            return id
        }
        return UUID()
    }()

    // MARK: - Metric mapping & formatting

    private struct Metric { let label: String; let percentile: Double; let tint: Color }

    private static let metricLabels = ["Workrate", "Distance / match", "Sprint distance",
                                       "High-speed running", "Top speed"]

    private static func metrics(_ p: CohortBenchmark.Percentiles) -> [Metric] {
        [
            Metric(label: "Workrate", percentile: p.workrate, tint: Theme.turf),
            Metric(label: "Distance / match", percentile: p.distancePerMatchMeters, tint: Theme.pace),
            Metric(label: "Sprint distance", percentile: p.sprintDistanceMeters, tint: Theme.sprint),
            Metric(label: "High-speed running", percentile: p.highSpeedRunningMeters, tint: Theme.signal),
            Metric(label: "Top speed", percentile: p.topSpeedMetersPerSecond, tint: Theme.heart)
        ]
    }

    private static func grouped(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// "78th", "1st", "22nd" — ordinal for the percentile numeral.
    private static func ordinal(_ percentile: Double) -> String {
        let value = Int(percentile.rounded())
        let suffix: String
        switch (value % 100, value % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }
}

// MARK: - Shimmer

/// Left-to-right sheen for the redacted loading bars, matching FormationView / the leaderboard
/// skeleton. Respects Reduce Motion (no repeating animation).
private struct BenchmarkShimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 1.5)
                    .offset(x: phase * geometry.size.width * 1.5)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    func benchmarkShimmer() -> some View { modifier(BenchmarkShimmer()) }
}
