// CohortBenchmarkCard.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// How you compare with other players, in words: "ahead of 64 in every 100".
struct CohortBenchmarkView: View {
    @State private var cohort: BenchmarkCohort = .everyone
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading, tooFew, failed(String)
        case loaded(CohortBenchmark)
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Compare with", selection: $cohort) {
                    Text("Everyone").tag(BenchmarkCohort.everyone)
                    Text("Your age").tag(BenchmarkCohort.ageBand)
                    Text("Your position").tag(BenchmarkCohort.position)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .readableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("How You Compare")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: cohort) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooFew:
            ContentUnavailableView("Not enough players yet", systemImage: "chart.bar",
                                   description: Text("We only compare groups of 25 or more, so nobody can be picked out."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load the comparison", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.prominentAction)
            }
        case .loaded(let benchmark):
            let metrics = Self.metrics(benchmark.percentiles)
            List {
                Section {
                    if let best = metrics.first {
                        Text("\(best.strength), ahead of \(best.standing) in every 100 players.")
                            .font(.title2.bold())
                            .padding(.vertical, 4)
                    }
                    ForEach(metrics, id: \.title) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(metric.title) {
                                Text("Ahead of \(metric.standing)").monospacedDigit()
                            }
                            ProgressView(value: Double(metric.standing), total: 100).tint(Theme.turf)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(metric.title)
                        .accessibilityValue("Ahead of \(metric.standing) in every 100 players")
                    }
                } footer: {
                    Text("Compared with \(benchmark.sampleSize.formatted()) players\(cohort == .everyone ? "" : " in \(benchmark.cohort)"), over recent months.")
                }
            }
            .contentMargins(.top, 8, for: .scrollContent)
            .readableFormWidth()
        }
    }

    private struct Metric {
        let title: String
        let strength: String
        let standing: Int
    }

    /// Strongest first.
    private static func metrics(_ percentiles: CohortBenchmark.Percentiles) -> [Metric] {
        [
            ("Distance per match", "Your strength is covering ground", percentiles.distancePerMatchMeters),
            ("Top speed", "Your strength is top speed", percentiles.topSpeedMetersPerSecond),
            ("Sprinting", "Your strength is sprinting", percentiles.sprintDistanceMeters),
            ("Fast running", "Your strength is fast running", percentiles.highSpeedRunningMeters),
            ("Effort", "Your strength is effort", percentiles.workrate)
        ]
        .map { Metric(title: $0.0, strength: $0.1, standing: min(99, max(0, Int($0.2.rounded())))) }
        .sorted { $0.standing > $1.standing }
    }

    private func load() async {
        phase = .loading
        do {
            let benchmark = try await TeamService.benchmark(cohort: cohort)
            phase = benchmark.map(Phase.loaded) ?? .tooFew
        } catch {
            if !Task.isCancelled { phase = .failed(TeamService.explain(error)) }
        }
    }
}
