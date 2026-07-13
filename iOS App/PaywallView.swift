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
            VStack(alignment: .leading, spacing: 20) {
                Label("Team Features", systemImage: "person.3.fill")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 12) {
                    featureRow("chart.bar.doc.horizontal", "Full team roster stats")
                    featureRow("dot.radiowaves.left.and.right", "Live team dashboard for coaches")
                    featureRow("bubble.left.and.bubble.right", "Match comment threads")
                    featureRow("square.grid.3x3.middle.filled", "Formation detection")
                    featureRow("person.2.badge.plus", "Multiple teams per player")
                }

                Spacer()

                if let product = entitlements.teamProduct {
                    Button {
                        Task {
                            await entitlements.purchaseTeam()
                            if entitlements.entitledToTeam { dismiss() }
                        }
                    } label: {
                        Text("Subscribe — \(product.displayPrice)/month")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(entitlements.purchaseInFlight)
                } else {
                    Text("Subscription unavailable right now.")
                        .foregroundStyle(.secondary)
                }

                Button("Restore Purchases") {
                    Task { await entitlements.restorePurchases() }
                }
                .frame(maxWidth: .infinity)

                if let error = entitlements.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("Solo match tracking and analysis are always free.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func featureRow(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.body)
    }
}
