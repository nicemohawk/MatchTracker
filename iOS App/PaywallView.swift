//
//  PaywallView.swift
//  MatchTracker
//

import SwiftUI
import StoreKit

/// Upsell sheet for the team subscription. Presented from any gated feature; takes the store
/// directly so it makes no assumptions about environment wiring. Dark, premium layout: a glowing
/// accent mark, a short tinted feature list, and a single price card driven by the live StoreKit
/// product. The CTA carries the purchase through its own states (loading → success → dismiss, or an
/// inline error) while all entitlement logic stays in `EntitlementStore`.
struct PaywallView: View {
    let entitlements: EntitlementStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Local presentation state for the CTA; the store still owns the real purchase/entitlement.
    private enum Phase { case idle, purchasing, success }
    @State private var phase: Phase = .idle
    @State private var inlineError: String?
    @State private var heroVisible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    featureList
                    priceSection
                }
                .padding()
                .padding(.top, 8)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(.secondary)
                }
            }
        }
        .onAppear {
            guard !heroVisible else { return }
            if reduceMotion {
                heroVisible = true
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { heroVisible = true }
            }
        }
    }

    // MARK: - Hero

    /// Dark hero: a glowing turf-accent mark over the near-black canvas, title, one-line value prop.
    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.turfFlow)
                    .frame(width: 84, height: 84)
                    .glow(Theme.turf, radius: 16)
                Image(systemName: "person.3.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.black)
            }

            VStack(spacing: 8) {
                Text("MatchTracker Team")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Turn solo tracking into your whole team's edge.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .scaleEffect(heroVisible ? 1 : 0.92)
        .opacity(heroVisible ? 1 : 0)
    }

    // MARK: - Features

    private var featureList: some View {
        VStack(spacing: 10) {
            featureRow("square.grid.3x3.middle.filled", "Formation view", Theme.sprint)
            featureRow("bubble.left.and.bubble.right.fill", "Match chat", Theme.pace)
            featureRow("dot.radiowaves.left.and.right", "Live sideline dashboard", Theme.signal)
            featureRow("person.2.badge.plus.fill", "Multiple teams", Theme.turf)
            featureRow("clock.arrow.circlepath", "Backlog batch import", Theme.heart)
        }
    }

    private func featureRow(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Theme.chipFill(tint), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(text)
                .font(.system(.body, design: .rounded).weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(12)
        .themedCard(cornerRadius: 16)
    }

    // MARK: - Price + purchase

    @ViewBuilder
    private var priceSection: some View {
        VStack(spacing: 16) {
            if let product = entitlements.teamProduct {
                priceCard(product)
                cta(product)
            } else {
                Text("Subscription isn't available right now.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }

            if let inlineError {
                errorLine(inlineError)
            }

            restoreButton
            legalLine
        }
    }

    private func priceCard(_ product: Product) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.displayName)
                    .font(.system(.headline, design: .rounded))
                Text(product.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(product.displayPrice)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("per month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1.5)
        )
    }

    private func cta(_ product: Product) -> some View {
        Button {
            purchase(product)
        } label: {
            ZStack {
                switch phase {
                case .idle:
                    Text("Subscribe — \(product.displayPrice)/mo")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.black)
                case .purchasing:
                    ProgressView()
                        .tint(.black)
                case .success:
                    Image(systemName: "checkmark")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(Theme.turfFlow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .glow(Theme.turf, radius: phase == .success ? 16 : 8)
        }
        .buttonStyle(.plain)
        .disabled(phase != .idle)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6), value: phase)
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task { await entitlements.restorePurchases() }
        }
        .font(.system(.subheadline, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private var legalLine: some View {
        Text("Auto-renews monthly until cancelled. Cancel anytime in Settings. Solo tracking stays free.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func errorLine(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.loss)
            Text(message)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .padding(12)
        .background(Theme.chipFill(Theme.loss), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Purchase flow

    private func purchase(_ product: Product) {
        guard phase == .idle else { return }
        Haptics.impact()
        inlineError = nil
        withAnimation { phase = .purchasing }
        Task {
            await entitlements.purchaseTeam()
            if entitlements.entitledToTeam {
                Haptics.impact(.medium)
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.5)) {
                    phase = .success
                }
                try? await Task.sleep(for: .seconds(0.9))
                dismiss()
            } else {
                withAnimation { phase = .idle }
                if let error = entitlements.lastError {
                    withAnimation { inlineError = error }
                }
            }
        }
    }
}
