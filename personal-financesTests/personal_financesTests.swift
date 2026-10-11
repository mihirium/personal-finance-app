//
//  personal_financesTests.swift
//  personal-financesTests
//
//  Created by Mihir Sangameswar on 8/29/26.
//

import Foundation
import Testing
@testable import personal_finances

struct personal_financesTests {

    @Test func groupsPostedPurchasesByVendor() {
        let transactions = [
            transaction(id: "1", name: "TST* Coffee", merchantName: "Coffee Shop", amount: 4.75, date: "2026-08-29"),
            transaction(id: "2", name: "Coffee Shop", merchantName: "Coffee Shop", amount: 6.25, date: "2026-08-28"),
            transaction(id: "3", name: "Pending Cafe", merchantName: "Pending Cafe", amount: 3.50, date: "2026-08-29", pending: true),
            transaction(id: "4", name: "Payroll", merchantName: nil, amount: -2_000, date: "2026-08-27")
        ]

        let history = PurchaseHistoryGrouper.groupByVendor(transactions)

        #expect(history.count == 1)
        #expect(history.first?.vendor == "Coffee Shop")
        #expect(history.first?.transactionCount == 2)
        #expect(history.first?.totalSpend == 11.00)
    }

    @Test func mergesPlaidSyncDeltasIntoExistingTransactions() {
        let existing = [
            transaction(id: "old", name: "Old Vendor", merchantName: "Old Vendor", amount: 10, date: "2026-08-20"),
            transaction(id: "edited", name: "Before", merchantName: "Before", amount: 3, date: "2026-08-21")
        ]
        let result = PlaidSyncResult(
            added: [
                transaction(id: "new", name: "New Vendor", merchantName: "New Vendor", amount: 15, date: "2026-08-29")
            ],
            modified: [
                transaction(id: "edited", name: "After", merchantName: "After", amount: 5, date: "2026-08-22")
            ],
            removed: [
                RemovedPlaidTransaction(transactionID: "old")
            ],
            nextCursor: "next-cursor"
        )

        let merged = PurchaseHistoryStore.merge(existing: existing, syncResult: result)

        #expect(merged.map(\.transactionID) == ["new", "edited"])
        #expect(merged.first(where: { $0.transactionID == "edited" })?.vendorName == "After")
        #expect(merged.first(where: { $0.transactionID == "edited" })?.amount == 5)
    }

    private func transaction(
        id: String,
        name: String,
        merchantName: String?,
        amount: Decimal,
        date: String,
        pending: Bool = false
    ) -> PlaidTransaction {
        PlaidTransaction(
            transactionID: id,
            accountID: "account-1",
            name: name,
            merchantName: merchantName,
            amount: amount,
            isoCurrencyCode: "USD",
            date: date,
            pending: pending,
            category: nil
        )
    }
}
