//
//  PaywallView.swift
//  MatchTracker
//

import SwiftUI
import StoreKit

/// The subscription for team extras. StoreKit draws the price, terms and purchase; if the App Store can't be
/// reached, this says so and offers another go.
struct PaywallView: View {
    let entitlements: EntitlementStore
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .tint(.primary)
                    }
                }
        }
        .tint(Theme.turf)
        .task {
            if entitlements.teamProduct == nil { await load() }
        }
        .onChange(of: entitlements.entitledToTeam) { _, entitled in
            if entitled { dismiss() }
        }
        .alert("Restore Purchases", isPresented: .init(get: { restoreMessage != nil },
                                                       set: { if !$0 { restoreMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let product = entitlements.teamProduct {
            store(product)
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailable
        }
    }

    // MARK: Store

    private func store(_ product: Product) -> some View {
        SubscriptionStoreView(subscriptions: [product]) {
            TeamPitch()
        }
        .subscriptionStoreControlStyle(.prominentPicker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.hidden, for: .cancellation)
        .modifier(LegalPolicies())
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(let verification)) = result, case .verified(let transaction) = verification {
                await transaction.finish()
            }
            await entitlements.refreshEntitlements()
        }
        .tint(Theme.turf)
    }

    // MARK: Unavailable

    private var unavailable: some View {
        ScrollView {
            VStack(spacing: 28) {
                TeamPitch()
                VStack(spacing: 8) {
                    Text("Not available right now").font(.headline)
                    Text("MatchTracker couldn’t load the subscription from the App Store. Try again in a moment.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .readableWidth(560)
        }
        .bottomActionBar {
            VStack(spacing: 8) {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.primaryAction)
                Button("Restore Purchases") { Task { await restore() } }
                    .frame(minHeight: 44)
                    .disabled(isRestoring)
            }
        }
    }

    private func load() async {
        isLoading = true
        await entitlements.loadProducts()
        isLoading = false
    }

    private func restore() async {
        isRestoring = true
        await entitlements.restorePurchases()
        isRestoring = false
        if !entitlements.entitledToTeam { restoreMessage = "There’s no Team subscription on this Apple Account." }
    }
}

/// What the money buys, and what it doesn't.
private struct TeamPitch: View {
    private let features: [(symbol: String, title: String, detail: String)] = [
        ("square.and.pencil", "Write notes on moments", "Say what you saw on a goal or a flag. Your whole team can read it.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MatchTracker Team").font(.largeTitle.bold())
                Text("An extra for whoever wants it.").font(.title3).foregroundStyle(Theme.secondaryLabel)
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(features, id: \.title) { feature in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.headline)
                            Text(feature.detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        }
                    } icon: {
                        Image(systemName: feature.symbol).foregroundStyle(Theme.turf)
                    }
                    .labelStyle(AlignedLabelStyle())
                }
            }
            Text("Always free: your team, its numbers, formations and live matches, recording, heat maps, importing your history and sharing.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

/// Icons in one column, text beside the first line. Stacks at accessibility sizes.
struct AlignedLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                configuration.icon.font(.title3)
                configuration.title
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                configuration.icon.font(.title3).frame(width: iconWidth, alignment: .center)
                configuration.title
            }
        }
    }
}

private struct LegalPolicies: ViewModifier {
    func body(content: Content) -> some View {
        content
            .subscriptionStorePolicyDestination(url: LegalLinks.termsOfUse, for: .termsOfService)
            .subscriptionStorePolicyDestination(url: LegalLinks.privacyPolicy, for: .privacyPolicy)
            .storeButton(.visible, for: .policies)
    }
}
