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
    @Environment(BacklogImporter.self) private var importer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int { case payoff, health, firstMatch }
    @State private var step = Step.payoff
    @State private var isRequestingHealth = false
    @State private var isImporting = false
    @State private var importFailed = false

    var body: some View {
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
        }
        .id(step)
        .transition(.opacity)
        .scrollBounceBehavior(.basedOnSize)
        .bottomActionBar { actions }
        .background(Theme.background.ignoresSafeArea())
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
        Task { await environment.matches.refresh() }
    }
}

// MARK: - 1. What you get

private struct PayoffPage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ExampleHeatPitch()
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 240 : 400)
                .frame(maxWidth: .infinity)
            OnboardingHeading(title: "See where you played",
                              detail: "Wear your Apple Watch in a match. Afterward you get your heat map, your best runs and the score.")
        }
    }
}

/// Title and one paragraph, the same on every page.
private struct OnboardingHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(detail).font(.title3).foregroundStyle(Theme.secondaryLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A portrait pitch, attacking up, with one player's match on it.
private struct ExampleHeatPitch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Canvas { context, size in
                var context = context
                let field = CGRect(origin: .zero, size: size)
                SoccerPitch.fillTurf(&context, rect: field)
            }
            Image(decorative: Self.heat, scale: 1)
                .resizable()
                .interpolation(.high)
                .padding(10)
                .opacity(isVisible ? 1 : 0)
            Canvas { context, size in
                // SoccerPitch draws lengthwise along x; stand it up.
                var upright = context
                upright.translateBy(x: size.width / 2, y: size.height / 2)
                upright.rotate(by: .degrees(-90))
                let length = size.height - 20, width = size.width - 20
                SoccerPitch.draw(in: &upright, rect: CGRect(x: -length / 2, y: -width / 2, width: length, height: width))
            }
        }
        .aspectRatio(CGSize(width: 68 + 6, height: 105 + 6), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1.1).delay(0.2)) { isVisible = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Example heat map. A right winger, mostly along the right side in the attacking half.")
        .accessibilityAddTraits(.isImage)
    }

    /// A right winger's match, summed from a few spots and blurred by its own size.
    private static let heat: CGImage = {
        let width = 68, height = 105
        // x across (0 left), y up the field (0 own goal), spread and weight, in field fractions.
        let spots: [(x: Double, y: Double, spread: Double, weight: Double)] = [
            (0.80, 0.68, 0.13, 1.0), (0.74, 0.55, 0.15, 0.75), (0.83, 0.42, 0.13, 0.55), (0.66, 0.80, 0.11, 0.65),
            (0.52, 0.86, 0.09, 0.45), (0.58, 0.62, 0.16, 0.35), (0.70, 0.27, 0.14, 0.28), (0.42, 0.50, 0.18, 0.16)
        ]
        var values = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let x = (Double(column) + 0.5) / Double(width)
                let y = 1 - (Double(row) + 0.5) / Double(height)
                values[row * width + column] = spots.reduce(0) { sum, spot in
                    let dx = x - spot.x, dy = (y - spot.y) * 105 / 68
                    return sum + spot.weight * exp(-(dx * dx + dy * dy) / (2 * spot.spread * spot.spread))
                }
            }
        }
        let peak = values.max() ?? 1
        let pixels = values.flatMap { value -> [UInt8] in
            let t = value / peak
            // Clear, through green, to almost white.
            let alpha = min(1, max(0, (t - 0.04) / 0.5))
            let glow = max(0, (t - 0.45) / 0.55)
            let red = 0.10 + 0.85 * glow, green = 0.72 + 0.28 * min(1, t * 1.2), blue = 0.28 + 0.48 * glow
            return [red, green, blue, 1].map { UInt8(($0 * alpha * 255).rounded()) }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
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
                .padding(.top, 32)
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
            Text("Matches you record are also sent to the MatchTracker server, where your team can see them. You can delete them in Settings.")
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
                Text("For your next match").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                OnboardingRow(symbol: "applewatch", title: "Wear it snug",
                              detail: "Above the wrist bone, so it can read your heart rate.")
                OnboardingRow(symbol: "play", title: "Start at kickoff",
                              detail: "Open MatchTracker on your watch and tap the match you’re playing. Your iPhone can stay in your bag.")
                OnboardingRow(symbol: "soccerball", title: "Log goals when play stops",
                              detail: "End the match at the whistle and it shows up here.")
            }
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var history: some View {
        if let summary = importer.summary {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.totalMatches.formatted()).heroNumeral().foregroundStyle(Theme.turf)
                Text(summary.totalMatches == 1 ? "match imported" : "matches imported").font(.title2.bold())
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
                    .font(.title2.bold())
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
