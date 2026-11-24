// OnboardingView.swift
// MatchTracker
//
// First run, three screens: what you get, the one permission it needs, and your first match. Shown
// once, gated by `@AppStorage("hasOnboarded")`.

import SwiftUI
import MatchTrackerKit

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @Environment(BacklogImporter.self) private var importer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int { case payoff, health, firstMatch }
    @State private var step = Step.payoff
    @State private var isRequestingHealth = false
    @State private var isImporting = false
    @State private var importFailed = false
    private static let top = "top"

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                Group {
                    switch step {
                    case .payoff: PayoffPage()
                    case .health: HealthPage()
                    case .firstMatch: FirstMatchPage(isImporting: isImporting)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .readableWidth(560)
                .id(Self.top)
            }
            // Progress shows at the top, which may be a long way up at large text sizes.
            .onChange(of: isImporting) { scroll.scrollTo(Self.top, anchor: .top) }
        }
        .id(step)
        .transition(.opacity)
        .scrollBounceBehavior(.basedOnSize)
        // Keeps text from scrolling under the clock.
        .safeAreaInset(edge: .top, spacing: 0) {
            Theme.background.frame(height: 1).background(Theme.background.ignoresSafeArea(edges: .top))
        }
        .bottomActionBar { actions }
        .background(Theme.background.ignoresSafeArea())
        .tint(Theme.turf)
        .sensoryFeedback(.selection, trigger: step)
        .sensoryFeedback(.success, trigger: importer.summary) { _, summary in summary?.cancelled == false }
        .alert("Couldn’t Import", isPresented: $importFailed) {
            Button("Try Again", action: importHistory)
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("MatchTracker couldn’t read your workouts from Health. You can import them later from Settings.")
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 4) {
            switch step {
            case .payoff:
                Button("Continue") { advance(to: .health) }
                    .buttonStyle(.primaryAction)
            case .health:
                Button("Continue", action: connectHealth)
                    .buttonStyle(.primaryAction)
                    .disabled(isRequestingHealth)
            case .firstMatch:
                firstMatchActions
            }
        }
    }

    @ViewBuilder
    private var firstMatchActions: some View {
        if importer.summary != nil || importer.pendingCount == 0 {
            Button("Done", action: finish).buttonStyle(.primaryAction)
        } else if isImporting {
            Button("Continue While Importing", action: finish).buttonStyle(.primaryAction)
        } else {
            Button(importer.pendingCount == 1 ? "Import 1 Match" : "Import \(importer.pendingCount) Matches",
                   action: importHistory)
                .buttonStyle(.primaryAction)
            Button("Not Now", action: finish)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func advance(to next: Step) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { step = next }
    }

    private func connectHealth() {
        isRequestingHealth = true
        Task {
            // Onward either way: iOS doesn't say whether reading was allowed, and the app works
            // from the watch regardless.
            try? await environment.matches.healthKit.requestAuthorization(userInitiated: true)
            await importer.scan()
            isRequestingHealth = false
            advance(to: .firstMatch)
        }
    }

    private func importHistory() {
        isImporting = true
        Task {
            await importer.importAll(includeDisguisedRuns: false)
            isImporting = false
            importFailed = importer.summary == nil
        }
    }

    private func finish() {
        hasOnboarded = true
        settings.dressEverything()
        Task { await environment.matches.refresh() }
    }
}

// MARK: - 1. What you get

private struct PayoffPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// As big as it can be with the words still on screen.
    private var pictureHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact { return 240 }
        return horizontalSizeClass == .regular ? 560 : 360
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeatPitch(heat: ExampleMatch.heat)
                .id(settings.kitID)
                .aspectRatio(HeatPitch.aspectRatio(for: .standard), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(height: pictureHeight)
                .accessibilityLabel("Example heat map. A right winger, mostly along the right side in the attacking half.")
                .frame(maxWidth: .infinity)
            OnboardingHeading(title: "See where you played",
                              detail: "Wear your Apple Watch in a match. Afterward you get your heat map, your best runs and the score.")
            KitRow()
        }
    }
}

/// The kits in one line. Choosing one is optional, and changes everything above it at once.
private struct KitRow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your team’s color").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(KitColors.presets) { preset in
                        if let kit = KitColors(id: preset.id) {
                            let isWorn = settings.kitID == preset.id
                            Button { settings.wear(kit) } label: {
                                Circle()
                                    .fill(Color(cgColor: kit.cloth.cgColor))
                                    .overlay { Circle().strokeBorder(Theme.ivory, lineWidth: isWorn ? 4 : 1.5) }
                                    .frame(width: 40, height: 40)
                                    .frame(width: 48, height: 48)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.title)
                            .accessibilityAddTraits(isWorn ? .isSelected : [])
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .sensoryFeedback(.selection, trigger: settings.kitID)
        }
    }
}

/// Title and one paragraph, the same on every page.
private struct OnboardingHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.name(.title)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.title3).foregroundStyle(Theme.secondaryLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A right winger's match, for the first screen to show what a match looks like.
enum ExampleMatch {
    static let heat: PitchHeat = {
        let columns = PitchHeat.defaultColumns, rows = PitchHeat.defaultRows
        // x across (0 left), y up the field (0 own goal), spread and weight, in field fractions.
        let spots: [(x: Double, y: Double, spread: Double, weight: Double)] = [
            (0.82, 0.70, 0.08, 1.0), (0.75, 0.57, 0.09, 0.8), (0.86, 0.47, 0.07, 0.65), (0.66, 0.82, 0.08, 0.7),
            (0.54, 0.88, 0.06, 0.5), (0.58, 0.64, 0.10, 0.45), (0.72, 0.30, 0.09, 0.4), (0.44, 0.50, 0.10, 0.25),
            (0.80, 0.18, 0.06, 0.3)
        ]
        let values = (0..<(columns * rows)).map { index -> Float in
            let x = (Double(index % columns) + 0.5) / Double(columns)
            let y = 1 - (Double(index / columns) + 0.5) / Double(rows)
            var total = 0.0
            for spot in spots {
                let dx = x - spot.x
                let dy = (y - spot.y) * 105 / 68
                let distance = dx * dx + dy * dy
                total += spot.weight * exp(-distance / (2 * spot.spread * spot.spread))
            }
            return Float(total)
        }
        return PitchHeat(columns: columns, rows: rows, values: values)
    }()
}

// MARK: - 2. Health

private struct HealthPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Image(systemName: "heart.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.heart)
                .accessibilityHidden(true)
            OnboardingHeading(title: "Connect Health",
                              detail: "Your matches are workouts in Apple Health. MatchTracker needs to see them to show them.")
            VStack(alignment: .leading, spacing: 20) {
                OnboardingRow(symbol: "eye", title: "Reads your soccer",
                              detail: "Workouts, routes, distance, energy and heart rate.")
                OnboardingRow(symbol: "square.and.arrow.down", title: "Saves your matches",
                              detail: "So the ones you record count in Health and Fitness.")
                OnboardingRow(symbol: "switch.2", title: "Tap Turn On All",
                              detail: "On the next screen. Anything left off goes missing from your matches.")
            }
            Text("Your matches stay on your devices unless you join a team, which then sees the ones you record.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryLabel)
        }
    }
}

private struct OnboardingRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(Theme.secondaryLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.turf)
        }
        .labelStyle(AlignedLabelStyle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 3. First match

private struct FirstMatchPage: View {
    let isImporting: Bool
    @Environment(BacklogImporter.self) private var importer

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            history
            VStack(alignment: .leading, spacing: 20) {
                Text("For your next match").font(.name(.title3)).accessibilityAddTraits(.isHeader)
                OnboardingRow(symbol: "applewatch", title: "Wear it snug",
                              detail: "Above the wrist bone, so it can read your heart rate.")
                OnboardingRow(symbol: "play", title: "Start at kickoff",
                              detail: "Open MatchTracker on your watch and tap the match you’re playing. Your iPhone can stay in your bag.")
                OnboardingRow(symbol: "soccerball", title: "Log goals when play stops",
                              detail: "End the match at the whistle and it shows up here.")
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        if let summary = importer.summary {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.totalMatches.formatted()).heroNumeral().foregroundStyle(Theme.turf)
                Text(summary.totalMatches == 1 ? "match imported" : "matches imported").font(.name(.title3))
                if summary.fieldsCreated > 0 {
                    Text(summary.fieldsCreated == 1 ? "On 1 field" : "On \(summary.fieldsCreated) fields")
                        .font(.title3).foregroundStyle(Theme.secondaryLabel)
                }
            }
            .accessibilityElement(children: .combine)
        } else if importer.pendingCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(importer.pendingCount.formatted()).heroNumeral().foregroundStyle(Theme.turf)
                Text(importer.pendingCount == 1 ? "match already in Health" : "matches already in Health")
                    .font(.name(.title3))
                if let earliest = importer.earliestDate {
                    Text("Going back to \(earliest.formatted(.dateTime.month(.wide).year())). Start with a history.")
                        .font(.title3).foregroundStyle(Theme.secondaryLabel)
                }
                if isImporting {
                    ProgressView(value: Double(importer.completed), total: Double(max(importer.total, 1)))
                        .tint(Theme.turf)
                        .padding(.top, 12)
                    Text("\(importer.completed) of \(importer.total)")
                        .font(.subheadline).monospacedDigit().foregroundStyle(Theme.secondaryLabel)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        } else {
            OnboardingHeading(title: "You’re ready",
                              detail: "No past matches turned up in Health, so your first one starts here. If you expected some, check Health in Settings.")
        }
    }
}
