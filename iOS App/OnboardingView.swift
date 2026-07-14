// OnboardingView.swift
// MatchTracker
//
// First-run onboarding: a three-page full-screen cover, dark-first and confident (Apple
// Fitness / Strava first-run DNA). Shown once — gated by `@AppStorage("hasOnboarded")` — so
// existing installs (and the UI tests that walk them) never see it. Interactive controls carry
// obvious accessibility labels ("Skip", "Continue", "Enable Health Access") so tests can drive
// straight through to the tab bar.

import SwiftUI

struct OnboardingView: View {
    /// Persisted flag the app reads to decide whether to present this cover. Written on finish.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(BacklogImporter.self) private var backlogImporter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page = 0
    @State private var playerName = ""
    @State private var teamCode = ""
    @State private var isRequestingHealth = false

    private let pageCount = 3

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    IdentityPage(reduceMotion: reduceMotion).tag(0)
                    HowItWorksPage().tag(1)
                    SetupPage(playerName: $playerName,
                              teamCode: $teamCode,
                              backlogCount: backlogImporter.pendingCount)
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.snappy, value: page)

                progressDots
                    .padding(.top, 4)
                    .padding(.bottom, 20)

                primaryButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
        }
        .task { await backlogImporter.scanIfNeeded() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Spacer()
            Button("Skip") { finish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Skip")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? AnyShapeStyle(Theme.turf) : AnyShapeStyle(Color.white.opacity(0.18)))
                    .frame(width: index == page ? 22 : 7, height: 7)
                    .animation(.snappy, value: page)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if page < pageCount - 1 {
            Button { advance() } label: {
                primaryLabel("Continue")
            }
            .accessibilityLabel("Continue")
        } else {
            Button { requestHealthAndFinish() } label: {
                primaryLabel(isRequestingHealth ? "Requesting…" : "Enable Health Access",
                             showsProgress: isRequestingHealth)
            }
            .accessibilityLabel("Enable Health Access")
            .disabled(isRequestingHealth)
        }
    }

    private func primaryLabel(_ title: String, showsProgress: Bool = false) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().tint(.black)
            }
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(Theme.turf, in: Capsule())
        .glow(Theme.turf, radius: 10)
    }

    // MARK: - Flow

    private func advance() {
        Haptics.selection()
        withAnimation(.snappy) { page = min(page + 1, pageCount - 1) }
    }

    private func requestHealthAndFinish() {
        // Persist setup fields to the shared store the watch reads too.
        commitSetup()
        isRequestingHealth = true
        Task {
            // Best-effort: onboarding continues whether the user grants or denies.
            try? await environment.matches.healthKit.requestAuthorization()
            isRequestingHealth = false
            finish()
        }
    }

    private func commitSetup() {
        let trimmedName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { SettingsStore.shared.playerName = trimmedName }
        let trimmedCode = teamCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !trimmedCode.isEmpty { SettingsStore.shared.teamCode = trimmedCode }
        environment.settingsChanged()
    }

    private func finish() {
        commitSetup()
        Haptics.impact(.medium)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            hasOnboarded = true
        }
    }
}

// MARK: - Page 1 · Identity

private struct IdentityPage: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            appMark
            VStack(spacing: 12) {
                Text("Track every match")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Every match your Apple Watch records becomes heatmaps, runs, and a workrate score — automatically.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { pulse = true } }
    }

    private var appMark: some View {
        ZStack {
            // Slow ambient glow — a single looping pulse, disabled under Reduce Motion.
            Circle()
                .fill(Theme.turf.opacity(0.22))
                .frame(width: 150, height: 150)
                .blur(radius: 26)
                .scaleEffect(pulse ? 1.15 : 0.9)
                .opacity(pulse ? 0.9 : 0.5)
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                           value: pulse)
            Circle()
                .fill(Theme.chipFill(Theme.turf))
                .overlay(Circle().strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1))
                .frame(width: 128, height: 128)
            Image(systemName: "figure.soccer")
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(Theme.turf)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Page 2 · How it works

private struct HowItWorksPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Text("How it works")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 14) {
                row(icon: "applewatch", tint: Theme.turf,
                    title: "Record on your watch",
                    detail: "Start a soccer workout — no phone needed on the pitch.")
                row(icon: "map", tint: Theme.pace,
                    title: "Auto field + analysis",
                    detail: "Your pitch is detected and the match is analyzed for you.")
                row(icon: "person.3.fill", tint: Theme.signal,
                    title: "Team stats",
                    detail: "Share a team code to compare workrate and build the roster.")
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func row(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Theme.chipFill(tint), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.chipStroke(tint), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .themedCard(cornerRadius: 18)
    }
}

// MARK: - Page 3 · Setup

private struct SetupPage: View {
    @Binding var playerName: String
    @Binding var teamCode: String
    let backlogCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up your profile")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Enable Health access so MatchTracker can read your soccer workouts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                field(title: "Your name") {
                    TextField("Player name", text: $playerName)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Player name")
                }
                field(title: "Team code (optional)") {
                    TextField("ABC123", text: $teamCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: teamCode) { _, newValue in
                            let upper = newValue.uppercased()
                            if upper != newValue { teamCode = upper }
                        }
                        .accessibilityLabel("Team code")
                }
            }

            if backlogCount >= 5 {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.turf)
                    Text("We found \(backlogCount) past matches — import them later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.chipFill(Theme.turf), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).captionLabel()
            content()
                .font(.body)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1))
        }
    }
}
