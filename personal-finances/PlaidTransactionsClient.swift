//
//  PlaidTransactionsClient.swift
//  personal-finances
//
//  Created by Codex on 8/29/26.
//

import Foundation

enum PlaidEnvironment: String, CaseIterable, Identifiable {
    case sandbox
    case development
    case production

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var baseURL: URL {
        switch self {
        case .sandbox:
            URL(string: "https://sandbox.plaid.com")!
        case .development:
            URL(string: "https://development.plaid.com")!
        case .production:
            URL(string: "https://production.plaid.com")!
        }
    }
}

struct PlaidCredentials: Equatable {
    var clientID: String
    var secret: String
    var accessToken: String
    var environment: PlaidEnvironment

    var isComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct PlaidTransaction: Codable, Equatable, Identifiable {
    var id: String { transactionID }

    let transactionID: String
    let accountID: String
    let name: String
    let merchantName: String?
    let amount: Decimal
    let isoCurrencyCode: String?
    let date: String
    let pending: Bool
    let category: [String]?

    var vendorName: String {
        let preferredName = merchantName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferredName, !preferredName.isEmpty {
            return preferredName
        }

        let fallbackName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? "Unknown Vendor" : fallbackName
    }

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case accountID = "account_id"
        case name
        case merchantName = "merchant_name"
        case amount
        case isoCurrencyCode = "iso_currency_code"
        case date
        case pending
        case category
    }
}

struct VendorPurchaseHistory: Identifiable, Equatable {
    var id: String { vendor }

    let vendor: String
    let transactions: [PlaidTransaction]

    var transactionCount: Int {
        transactions.count
    }

    var totalSpend: Decimal {
        transactions.reduce(Decimal.zero) { partialResult, transaction in
            partialResult + transaction.amount
        }
    }

    var currencyCode: String {
        transactions.compactMap(\.isoCurrencyCode).first ?? "USD"
    }
}

enum PurchaseHistoryGrouper {
    static func groupByVendor(_ transactions: [PlaidTransaction]) -> [VendorPurchaseHistory] {
        let purchases = transactions.filter { !$0.pending && $0.amount > 0 }
        let groups = Dictionary(grouping: purchases, by: \.vendorName)

        return groups
            .map { vendor, transactions in
                VendorPurchaseHistory(
                    vendor: vendor,
                    transactions: transactions.sorted { $0.date > $1.date }
                )
            }
            .sorted {
                if $0.totalSpend == $1.totalSpend {
                    return $0.vendor.localizedCaseInsensitiveCompare($1.vendor) == .orderedAscending
                }

                return $0.totalSpend > $1.totalSpend
            }
    }
}

enum PurchaseHistoryStore {
    static func merge(existing: [PlaidTransaction], syncResult: PlaidSyncResult) -> [PlaidTransaction] {
        var transactionsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.transactionID, $0) })

        for transaction in syncResult.added {
            transactionsByID[transaction.transactionID] = transaction
        }

        for transaction in syncResult.modified {
            transactionsByID[transaction.transactionID] = transaction
        }

        for removed in syncResult.removed {
            transactionsByID.removeValue(forKey: removed.transactionID)
        }

        return transactionsByID.values.sorted { $0.date > $1.date }
    }
}

enum PlaidTransactionsError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Plaid returned a response the app could not read."
        case .requestFailed(let message):
            message
        }
    }
}

final class PlaidTransactionsClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func syncPurchaseHistory(credentials: PlaidCredentials, cursor: String? = nil) async throws -> PlaidSyncResult {
        var addedTransactions: [PlaidTransaction] = []
        var modifiedTransactions: [PlaidTransaction] = []
        var removedTransactions: [RemovedPlaidTransaction] = []
        var nextCursor = cursor
        var hasMore = true

        while hasMore {
            let page = try await syncPage(credentials: credentials, cursor: nextCursor)
            addedTransactions.append(contentsOf: page.added)
            modifiedTransactions.append(contentsOf: page.modified)
            removedTransactions.append(contentsOf: page.removed)
            nextCursor = page.nextCursor
            hasMore = page.hasMore
        }

        return PlaidSyncResult(
            added: addedTransactions,
            modified: modifiedTransactions,
            removed: removedTransactions,
            nextCursor: nextCursor
        )
    }

    private func syncPage(credentials: PlaidCredentials, cursor: String?) async throws -> TransactionsSyncResponse {
        let endpoint = credentials.environment.baseURL.appending(path: "transactions/sync")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(TransactionsSyncRequest(
            clientID: credentials.clientID,
            secret: credentials.secret,
            accessToken: credentials.accessToken,
            cursor: cursor,
            count: 500
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlaidTransactionsError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let plaidError = try? decoder.decode(PlaidErrorResponse.self, from: data) {
                throw PlaidTransactionsError.requestFailed(plaidError.displayMessage)
            }

            throw PlaidTransactionsError.requestFailed("Plaid request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(TransactionsSyncResponse.self, from: data)
    }
}

struct PlaidSyncResult: Equatable {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [RemovedPlaidTransaction]
    let nextCursor: String?

    var currentTransactions: [PlaidTransaction] {
        let removedIDs = Set(removed.map(\.transactionID))
        let modifiedByID = Dictionary(uniqueKeysWithValues: modified.map { ($0.transactionID, $0) })

        return added
            .filter { !removedIDs.contains($0.transactionID) }
            .map { modifiedByID[$0.transactionID] ?? $0 }
    }
}

private struct TransactionsSyncRequest: Encodable {
    let clientID: String
    let secret: String
    let accessToken: String
    let cursor: String?
    let count: Int

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case accessToken = "access_token"
        case cursor
        case count
    }
}

private struct TransactionsSyncResponse: Decodable {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [RemovedPlaidTransaction]
    let nextCursor: String
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case added
        case modified
        case removed
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

struct RemovedPlaidTransaction: Decodable, Equatable {
    let transactionID: String

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
    }
}

private struct PlaidErrorResponse: Decodable {
    let errorType: String?
    let errorCode: String?
    let errorMessage: String?
    let displayMessageRaw: String?

    var displayMessage: String {
        let message = displayMessageRaw ?? errorMessage ?? "Plaid request failed."
        if let errorCode {
            return "\(message) (\(errorCode))"
        }
        return message
    }

    enum CodingKeys: String, CodingKey {
        case errorType = "error_type"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case displayMessageRaw = "display_message"
    }
}
