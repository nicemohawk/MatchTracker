//
//  PaywallView.swift
//  MatchTracker
//

import SwiftUI

/// Upsell sheet for the team subscription. Presented from any gated feature; takes the store
/// directly so it makes no assumptions about environment wiring.
struct PaywallView: View {
    let entitlements: EntitlementStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero

                    VStack(spacing: 10) {
                        featureRow("chart.bar.doc.horizontal", "Full team roster stats", Theme.turf)
                        featureRow("dot.radiowaves.left.and.right", "Live team dashboard for coaches", Theme.signal)
                        featureRow("bubble.left.and.bubble.right", "Match comment threads", Theme.pace)
                        featureRow("square.grid.3x3.middle.filled", "Formation detection", Theme.sprint)
                        featureRow("person.2.badge.plus", "Multiple teams per player", Theme.goal)
                    }

                    purchaseControls

                    if let error = entitlements.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.heart)
                    }

                    Text("Solo match tracking and analysis are always free.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    /// Gradient hero banner — the same turfFlow language as the rest of the app.
    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 40))
                .foregroundStyle(.black)
                .glow(Theme.turf, radius: 10)
            Text("Team Features")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(Theme.turfFlow, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.turf.opacity(0.35), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private var purchaseControls: some View {
        if let product = entitlements.teamProduct {
            Button {
                Haptics.impact()
                Task {
                    await entitlements.purchaseTeam()
                    if entitlements.entitledToTeam { dismiss() }
                }
            } label: {
                Text("Subscribe — \(product.displayPrice)/month")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.turfFlow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(entitlements.purchaseInFlight ? 0.4 : 1)
                    .glow(Theme.turf, radius: entitlements.purchaseInFlight ? 0 : 8)
            }
            .buttonStyle(.plain)
            .disabled(entitlements.purchaseInFlight)
        } else {
            Text("Subscription unavailable right now.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }

        Button("Restore Purchases") {
            Task { await entitlements.restorePurchases() }
        }
        .font(.subheadline)
        .tint(Theme.turf)
        .frame(maxWidth: .infinity)
    }

    private func featureRow(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .glow(tint, radius: 5)
                .frame(width: 30)
            Text(text).font(.body)
            Spacer(minLength: 0)
        }
        .padding(14)
        .themedCard(cornerRadius: 16)
    }
}
