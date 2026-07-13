//
//  EntitlementStore.swift
//  MatchTracker
//

import Foundation
import Observation
import StoreKit

/// StoreKit 2 subscription state for team features (roster stats beyond one team, live team
/// dashboard, chat, formation). Solo-player analytics stay free — gate checks call
/// `entitledToTeam`, which is also granted in DEBUG via `-MatchTrackerEntitleTeam` for tests.
@Observable
@MainActor
final class EntitlementStore {
    static let teamMonthlyProductID = "com.nicemohawk.MatchTracker.team.monthly"

    private(set) var entitledToTeam = false
    private(set) var teamProduct: Product?
    private(set) var purchaseInFlight = false
    private(set) var lastError: String?

    @ObservationIgnored private var transactionListener: Task<Void, Never>?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MatchTrackerEntitleTeam") {
            entitledToTeam = true
        }
        #endif
        transactionListener = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    func loadProducts() async {
        do {
            teamProduct = try await Product.products(for: [Self.teamMonthlyProductID]).first
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MatchTrackerEntitleTeam") { return }
        #endif
        var active = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == Self.teamMonthlyProductID,
               transaction.revocationDate == nil {
                active = true
            }
        }
        entitledToTeam = active
    }

    func purchaseTeam() async {
        guard let teamProduct, !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await teamProduct.purchase()
            if case .success(let verification) = result,
               case .verified(let transaction) = verification {
                await transaction.finish()
            }
            await refreshEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
