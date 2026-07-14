// BacklogImportView.swift
// MatchTracker
//
// The batch-import sheet. Three states: an intro that explains what import does and gates the CTA
// behind the Team entitlement, a live progress state that scrubs through history, and a completion
// summary. Presented from the Matches teaser card and the Settings entry row.

import SwiftUI
import MatchTrackerKit

struct BacklogImportView: View {
    @Environment(BacklogImporter.self) private var importer
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    @State private var includeDisguisedRuns = false
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let summary = importer.summary, !importer.isImporting {
                        completionState(summary)
                    } else if importer.isImporting {
                        progressState
                    } else {
                        introState
                    }
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Import History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importer.isImporting ? "Hide" : "Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(entitlements: entitlements)
            }
        }
    }

    // MARK: - Intro

    private var introState: some View {
        VStack(alignment: .leading, spacing: 20) {
            hero

            VStack(spacing: 10) {
                explainer("map", Theme.turf, "Build your fields",
                          "Every past match refines a map of the pitches you play on.")
                explainer("chart.line.uptrend.xyaxis", Theme.pace, "Season trends",
                          "Priming your history unlocks season-average heatmaps and workrate baselines.")
                explainer("heart.text.square", Theme.heart, "Heart-rate effort",
                          "Matches without GPS still import, scored from heart rate.")
            }

            coverageCard

            Toggle(isOn: $includeDisguisedRuns) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also scan runs & walks that look like matches")
                        .font(.subheadline.weight(.semibold))
                    Text("Recovers matches you recorded as an Outdoor Run or Walk. Slower — it reads each route.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Theme.turf)
            .padding(14)
            .themedCard(cornerRadius: 16)

            cta

            Text("Solo match tracking and analysis are always free.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.black)
            Text(importer.pendingCount > 0 ? "\(importer.pendingCount) past matches" : "Import your history")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
            if let span = spanText {
                Text(span)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.black.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Theme.turfFlow, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.turf.opacity(0.35), radius: 18, x: 0, y: 8)
    }

    /// Honest route coverage: native soccer workouts have no GPS route, so most of the backlog
    /// imports on heart-rate effort alone.
    @ViewBuilder
    private var coverageCard: some View {
        if importer.pendingCount > 0 {
            HStack(spacing: 14) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.title3)
                    .foregroundStyle(Theme.signal)
                    .frame(width: 30)
                Text(coverageText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(14)
            .themedCard(cornerRadius: 16)
        }
    }

    private var coverageText: String {
        let approx = importer.routeCountIsApproximate ? "about " : ""
        if importer.withRouteCount == 0 {
            return "None have GPS routes — they'll import with heart-rate effort scores."
        }
        return "\(approx)\(importer.withRouteCount) with GPS routes; the rest import with heart-rate effort scores."
    }

    @ViewBuilder
    private var cta: some View {
        if entitlements.entitledToTeam {
            Button {
                Haptics.impact()
                Task { await importer.importAll(includeDisguisedRuns: includeDisguisedRuns) }
            } label: {
                ctaLabel("Import All", enabled: importer.pendingCount > 0 || includeDisguisedRuns)
            }
            .buttonStyle(.plain)
            .disabled(importer.pendingCount == 0 && !includeDisguisedRuns)
        } else {
            Button {
                Haptics.impact()
                showingPaywall = true
            } label: {
                ctaLabel("Unlock with Team", enabled: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func ctaLabel(_ title: String, enabled: Bool) -> some View {
        Text(title)
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.turfFlow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - Progress

    private var progressState: some View {
        VStack(spacing: 24) {
            Text("Importing your history")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                ProgressView(value: Double(importer.completed),
                             total: Double(max(importer.total, 1)))
                    .tint(Theme.turf)

                HStack {
                    Text("\(importer.completed) of \(importer.total)")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    if let date = importer.currentDate {
                        Text(date, format: .dateTime.month().year())
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .themedCard()

            Button(role: .destructive) {
                importer.cancel()
            } label: {
                Text("Cancel")
                    .font(.system(.headline, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.loss)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.chipStroke(Theme.loss), lineWidth: 1))
        }
    }

    // MARK: - Completion

    private func completionState(_ summary: BacklogImporter.Summary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: summary.cancelled ? "pause.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.turf)
                Text(summary.cancelled ? "Import paused" : "History imported")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                if let span = summarySpan(summary) {
                    Text(span).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

            VStack(spacing: 10) {
                statRow(Theme.turf, "figure.soccer", "\(summary.totalMatches) matches imported",
                        summary.routelessImported > 0 ? "\(summary.routelessImported) scored from heart rate" : nil)
                if summary.recoveredFromRuns > 0 {
                    statRow(Theme.pace, "figure.run", "\(summary.recoveredFromRuns) recovered from runs & walks", nil)
                }
                if summary.fieldsCreated > 0 {
                    statRow(Theme.signal, "map.fill", "\(summary.fieldsCreated) new fields mapped", nil)
                }
                if summary.fieldsRefined > 0 {
                    statRow(Theme.sprint, "scope", "\(summary.fieldsRefined) fields refined", nil)
                }
            }

            Button {
                Haptics.selection()
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.turfFlow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Building blocks

    private func explainer(_ symbol: String, _ tint: Color, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    private func statRow(_ tint: Color, _ symbol: String, _ title: String, _ subtitle: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    private var spanText: String? {
        guard let earliest = importer.earliestDate else { return nil }
        return "since \(earliest.formatted(.dateTime.month(.wide).year()))"
    }

    private func summarySpan(_ summary: BacklogImporter.Summary) -> String? {
        guard let earliest = summary.earliest, let latest = summary.latest else { return nil }
        let earliestText = earliest.formatted(.dateTime.month().year())
        let latestText = latest.formatted(.dateTime.month().year())
        return earliestText == latestText ? earliestText : "\(earliestText) – \(latestText)"
    }
}
