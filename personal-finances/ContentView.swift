//
//  ContentView.swift
//  personal-finances
//
//  Created by Mihir Sangameswar on 8/29/26.
//

import SwiftUI
import LinkKit

struct ContentView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @AppStorage("preferredColorScheme") private var preferredColorScheme = AppColorScheme.dark.rawValue
    @State private var isLoadingLinkToken = false
    @State private var statusMessage = "Ready to connect your bank."
    @State private var plaidLinkSession: PlaidLinkSession?
    @State private var creditCards: [CreditCardAccount] = []
    @State private var connectedItemID: String?
    @State private var isLoadingSavedCards = false
    @State private var monthlyBudget: Decimal?
    @State private var spentThisMonth = Decimal.zero
    @State private var isLoadingMonthlySpend = false
    @State private var monthlyTransactions: [CreditCardTransaction] = []
    @State private var monthlyCategories = SpendingCategory.emptyCategories
    @State private var selectedTab: BudgetHomeTab = .overview
    @State private var selectedMonth = ContentView.currentMonthPrefix
    @State private var availableMonths: [String] = []
    @State private var monthlyDataCache: [String: CachedMonthlyData] = [:]

    private let plaidBackendClient = PlaidBackendClient()

    var body: some View {
        NavigationStack {
            Group {
                if let monthlyBudget {
                    BudgetHomeScreen(
                        selectedTab: $selectedTab,
                        monthlyBudget: monthlyBudget,
                        spentThisMonth: spentThisMonth,
                        isLoadingMonthlySpend: isLoadingMonthlySpend,
                        isLoadingSavedCards: isLoadingSavedCards,
                        isLoadingLinkToken: isLoadingLinkToken,
                        statusMessage: statusMessage,
                        categories: spendingCategories,
                        transactions: monthlyTransactions,
                        creditCards: creditCards,
                        connectedItemID: connectedItemID,
                        selectedMonth: selectedMonth,
                        availableMonths: availableMonths,
                        onSelectMonth: selectMonth,
                        onConnect: {
                            Task { await connectBank() }
                        },
                        onLogOut: {
                            BudgetWidgetSnapshotStore.clear()
                            authViewModel.signOut()
                        },
                        selectedColorScheme: appColorScheme,
                        onSelectColorScheme: { colorScheme in
                            preferredColorScheme = colorScheme.rawValue
                        },
                        transactionDestination: { card, itemID in
                            CreditCardTransactionsView(
                                card: card,
                                itemID: itemID,
                                plaidBackendClient: plaidBackendClient
                            )
                        }
                    )
                } else {
                    BudgetSetupView { budget in
                        saveMonthlyBudget(budget)
                    }
                    .padding()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: authViewModel.user?.userID) {
                selectedMonth = Self.currentMonthPrefix
                availableMonths = []
                monthlyDataCache = [:]
                loadMonthlyBudget()
                await loadAvailableMonths()
                await loadSavedCreditCards()
                await preloadMonths(Self.initialPreloadMonths, for: creditCards)
            }
        }
        .preferredColorScheme(appColorScheme.colorScheme)
    }

    private var appColorScheme: AppColorScheme {
        AppColorScheme(rawValue: preferredColorScheme) ?? .dark
    }

    private var spendingCategories: [SpendingCategory] {
        monthlyCategories
    }

    @MainActor
    private func connectBank() async {
        isLoadingLinkToken = true
        statusMessage = "Requesting link token..."

        do {
            let userID = authViewModel.user?.userID ?? "local-user"
            let response = try await plaidBackendClient.createLinkToken(userID: userID)
            print("Plaid link token: \(response.linkToken)")
            print("Plaid link token expires: \(response.expiration)")
            print("Plaid request id: \(response.requestID)")
            openPlaidLink(with: response.linkToken)
        } catch {
            print("Failed to create Plaid link token: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
            isLoadingLinkToken = false
        }
    }

    @MainActor
    private func openPlaidLink(with linkToken: String) {
        let configuration = LinkTokenConfiguration(
            token: linkToken,
            onSuccess: { success in
                print("Plaid Link success public token: \(success.publicToken)")
                print("Plaid Link institution: \(success.metadata.institution.name)")
                print("Plaid Link accounts: \(success.metadata.accounts.map(\.name).joined(separator: ", "))")
                Task {
                    await exchangePublicToken(success.publicToken)
                }
            },
            onExit: { exit in
                if let error = exit.error {
                    print("Plaid Link exited with error: \(error.errorMessage)")
                } else {
                    print("Plaid Link exited without an error.")
                }

                Task { @MainActor in
                    statusMessage = "Plaid Link closed."
                    isLoadingLinkToken = false
                }
            },
            onEvent: { event in
                print("Plaid Link event: \(event.eventName)")
            },
            onLoad: {
                print("Plaid Link loaded.")
            }
        )

        do {
            let session = try Plaid.createPlaidLinkSession(configuration: configuration)
            guard let viewController = UIApplication.shared.rootViewController else {
                print("Unable to find a view controller for Plaid Link.")
                statusMessage = "Unable to open Plaid Link."
                isLoadingLinkToken = false
                return
            }

            plaidLinkSession = session
            statusMessage = "Opening Plaid Link..."
            session.open(using: .viewController(viewController))
        } catch {
            print("Failed to create Plaid Link handler: \(error)")
            statusMessage = "Unable to open Plaid Link."
            isLoadingLinkToken = false
        }
    }

    @MainActor
    private func exchangePublicToken(_ publicToken: String) async {
        statusMessage = "Loading credit card details..."

        do {
            let response = try await plaidBackendClient.exchangePublicToken(
                publicToken,
                userID: authViewModel.user?.userID
            )
            print("Plaid item id: \(response.itemID)")
            print("Plaid exchange request id: \(response.requestID)")
            print("Plaid item persisted: \(response.persisted)")
            print("Plaid credit cards: \(response.creditCards.map(\.displayName).joined(separator: ", "))")

            connectedItemID = response.itemID
            creditCards = response.creditCards.map { $0.withItemID(response.itemID) }
            monthlyDataCache = [:]
            _ = try await plaidBackendClient.fetchMonthlySummary(
                userID: authViewModel.user?.userID ?? "local-user",
                month: selectedMonth,
                refresh: true
            )
            await loadAvailableMonths()
            await preloadMonths(Self.initialPreloadMonths, for: creditCards)
            statusMessage = response.creditCards.isEmpty
                ? "Connected. No credit cards were returned for this institution."
                : "Connected \(response.creditCards.count) credit card account\(response.creditCards.count == 1 ? "" : "s")."
            isLoadingLinkToken = false
        } catch {
            print("Failed to exchange Plaid public token: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
            isLoadingLinkToken = false
        }
    }

    @MainActor
    private func loadSavedCreditCards() async {
        guard let userID = authViewModel.user?.userID else {
            return
        }

        isLoadingSavedCards = true

        do {
            let response = try await plaidBackendClient.fetchSavedCreditCards(userID: userID)
            creditCards = response.creditCards
            connectedItemID = response.creditCards.first?.itemID
            statusMessage = response.creditCards.isEmpty
                ? "Ready to connect your bank."
                : "Loaded \(response.creditCards.count) saved credit card account\(response.creditCards.count == 1 ? "" : "s")."
            print("Loaded saved Plaid credit cards: \(response.creditCards.map(\.displayName).joined(separator: ", "))")
        } catch {
            print("Failed to load saved Plaid credit cards: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
        }

        isLoadingSavedCards = false
    }

    @MainActor
    private func preloadMonths(
        _ months: [String],
        for cards: [CreditCardAccount]
    ) async {
        guard let userID = authViewModel.user?.userID else {
            spentThisMonth = .zero
            monthlyTransactions = []
            monthlyCategories = SpendingCategory.emptyCategories
            return
        }

        let creditAccountIDs = Set(cards.map(\.id))
        let monthsToLoad = months.filter { monthlyDataCache[$0] == nil }

        if monthsToLoad.contains(selectedMonth) {
            isLoadingMonthlySpend = true
        }

        for month in monthsToLoad {
            do {
                let response = try await plaidBackendClient.fetchMonthlyTransactions(
                    userID: userID,
                    month: month,
                    refresh: false
                )
                let transactions = response.transactions
                    .filter { transaction in
                        creditAccountIDs.contains(transaction.accountID)
                            && !transaction.pending
                            && transaction.amount > 0
                    }
                    .sorted { $0.date > $1.date }

                let data = CachedMonthlyData(transactions: transactions)
                monthlyDataCache[month] = data
                print("Preloaded \(month): \(transactions.count) credit card transactions")

                if month == Self.currentMonthPrefix, let monthlyBudget {
                    BudgetWidgetSnapshotStore.save(
                        monthlyBudget: monthlyBudget,
                        transactions: data.transactions
                    )
                }

                if month == selectedMonth {
                    applyCachedMonth(month)
                }
            } catch {
                print("Failed to preload \(month): \(error.localizedDescription)")
                if month == selectedMonth {
                    statusMessage = error.localizedDescription
                }
            }
        }

        isLoadingMonthlySpend = false
    }

    @MainActor
    private func applyCachedMonth(_ month: String) {
        guard month == selectedMonth, let data = monthlyDataCache[month] else {
            return
        }

        spentThisMonth = data.totalSpent
        monthlyCategories = data.categories
        monthlyTransactions = data.transactions
        isLoadingMonthlySpend = false
    }

    @MainActor
    private func loadAvailableMonths() async {
        guard let userID = authViewModel.user?.userID else {
            return
        }

        do {
            let response = try await plaidBackendClient.fetchMonthlySummaryMonths(userID: userID)
            availableMonths = Set(response.months).sorted(by: >)
        } catch {
            print("Failed to load available spending months: \(error.localizedDescription)")
            availableMonths = []
        }
    }

    private func selectMonth(_ month: String) {
        guard month != selectedMonth else {
            return
        }

        selectedMonth = month

        if monthlyDataCache[month] != nil {
            applyCachedMonth(month)
            return
        }

        spentThisMonth = .zero
        monthlyCategories = SpendingCategory.emptyCategories
        monthlyTransactions = []
        isLoadingMonthlySpend = true

        Task {
            await preloadMonths(BudgetMonthFormatter.months(centeredOn: month, radius: 3), for: creditCards)
        }
    }

    private func loadMonthlyBudget() {
        guard let userID = authViewModel.user?.userID else {
            monthlyBudget = nil
            return
        }

        let storedBudget = UserDefaults.standard.double(forKey: monthlyBudgetKey(for: userID))
        monthlyBudget = storedBudget > 0 ? Decimal(storedBudget) : nil
    }

    private func saveMonthlyBudget(_ budget: Decimal) {
        guard let userID = authViewModel.user?.userID else {
            return
        }

        UserDefaults.standard.set((budget as NSDecimalNumber).doubleValue, forKey: monthlyBudgetKey(for: userID))
        monthlyBudget = budget

        if let currentMonthData = monthlyDataCache[Self.currentMonthPrefix] {
            BudgetWidgetSnapshotStore.save(
                monthlyBudget: budget,
                transactions: currentMonthData.transactions
            )
        }
    }

    private func monthlyBudgetKey(for userID: String) -> String {
        "monthlyBudget.\(userID)"
    }

    private static var currentMonthPrefix: String {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        guard let year = components.year, let month = components.month else {
            return ""
        }

        return String(format: "%04d-%02d", year, month)
    }

    private static var initialPreloadMonths: [String] {
        BudgetMonthFormatter.months(endingAt: currentMonthPrefix, count: 5)
    }
}

private enum BudgetHomeTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case transactions = "Transactions"
    case accounts = "Accounts"

    var id: String { rawValue }
}

private enum AppColorScheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            "Light mode"
        case .dark:
            "Dark mode"
        }
    }

    var iconName: String {
        switch self {
        case .light:
            "sun.max"
        case .dark:
            "moon"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

private enum BudgetCategory: String, CaseIterable, Identifiable {
    case food
    case shopping
    case transport
    case entertainment
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food:
            "Food & Drink"
        case .shopping:
            "Shopping"
        case .transport:
            "Transport"
        case .entertainment:
            "Entertainment"
        case .other:
            "Other"
        }
    }

    var color: Color {
        switch self {
        case .food:
            Color(red: 1.0, green: 0.39, blue: 0.42)
        case .shopping:
            Color(red: 1.0, green: 0.74, blue: 0.08)
        case .transport:
            Color(red: 0.29, green: 0.77, blue: 0.90)
        case .entertainment:
            Color(red: 0.64, green: 0.31, blue: 0.92)
        case .other:
            Color(red: 0.04, green: 0.80, blue: 0.34)
        }
    }

}

private struct SpendingCategory: Identifiable {
    let category: BudgetCategory
    let amount: Decimal

    var id: String {
        category.rawValue
    }

    static var emptyCategories: [SpendingCategory] {
        BudgetCategory.allCases.map { SpendingCategory(category: $0, amount: .zero) }
    }

    static var sampleCategories: [SpendingCategory] {
        [
            SpendingCategory(category: .food, amount: Decimal(487)),
            SpendingCategory(category: .shopping, amount: Decimal(313)),
            SpendingCategory(category: .transport, amount: Decimal(149)),
            SpendingCategory(category: .entertainment, amount: Decimal(90)),
            SpendingCategory(category: .other, amount: Decimal(295))
        ]
    }

    static var sampleTotal: Decimal {
        sampleCategories.reduce(.zero) { partialResult, category in
            partialResult + category.amount
        }
    }
}

private struct CachedMonthlyData {
    let totalSpent: Decimal
    let categories: [SpendingCategory]
    let transactions: [CreditCardTransaction]

    init(transactions: [CreditCardTransaction]) {
        self.transactions = transactions
        totalSpent = transactions.reduce(.zero) { $0 + $1.amount }
        categories = BudgetCategory.allCases.map { category in
            SpendingCategory(
                category: category,
                amount: transactions
                    .filter { $0.budgetCategory == category }
                    .reduce(.zero) { $0 + $1.amount }
            )
        }
    }
}

private enum CurrencyFormatter {
    static func string(from amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = amount == Decimal((amount as NSDecimalNumber).intValue) ? 0 : 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}

private enum BudgetMonthFormatter {
    static func title(for month: String) -> String {
        guard let date = parser.date(from: month) else {
            return month
        }

        return titleFormatter.string(from: date)
    }

    static func spendingTitle(for month: String) -> String {
        "\(title(for: month).components(separatedBy: " ").first ?? title(for: month)) SPENDING"
    }

    static func months(endingAt month: String, count: Int) -> [String] {
        guard count > 0 else {
            return []
        }

        return (0..<count).compactMap { shiftedMonth(offsetBy: -$0, from: month) }
    }

    static func months(centeredOn month: String, radius: Int) -> [String] {
        guard radius > 0 else {
            return [month]
        }

        let offsets = [0] + (1...radius).flatMap { [-$0, $0] }
        return offsets.compactMap { shiftedMonth(offsetBy: $0, from: month) }
    }

    private static func shiftedMonth(offsetBy offset: Int, from month: String) -> String? {
        guard let date = parser.date(from: month),
              let shiftedDate = Calendar(identifier: .gregorian).date(byAdding: .month, value: offset, to: date) else {
            return nil
        }

        return parser.string(from: shiftedDate)
    }

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}

private struct BudgetHomeScreen<Destination: View>: View {
    @Binding var selectedTab: BudgetHomeTab

    let monthlyBudget: Decimal
    let spentThisMonth: Decimal
    let isLoadingMonthlySpend: Bool
    let isLoadingSavedCards: Bool
    let isLoadingLinkToken: Bool
    let statusMessage: String
    let categories: [SpendingCategory]
    let transactions: [CreditCardTransaction]
    let creditCards: [CreditCardAccount]
    let connectedItemID: String?
    let selectedMonth: String
    let availableMonths: [String]
    let onSelectMonth: (String) -> Void
    let onConnect: () -> Void
    let onLogOut: () -> Void
    let selectedColorScheme: AppColorScheme
    let onSelectColorScheme: (AppColorScheme) -> Void
    let transactionDestination: (CreditCardAccount, String) -> Destination

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                BudgetSegmentedTabs(selection: $selectedTab)

                switch selectedTab {
                case .overview:
                    BudgetOverviewTab(
                        budget: monthlyBudget,
                        spent: spentThisMonth,
                        isLoading: isLoadingMonthlySpend,
                        categories: categories,
                        transactions: transactions,
                        month: selectedMonth
                    )
                    .id(selectedMonth)
                case .transactions:
                    BudgetTransactionsTab(
                        transactions: transactions,
                        isLoading: isLoadingMonthlySpend,
                        month: selectedMonth
                    )
                case .accounts:
                    BudgetAccountsTab(
                        creditCards: creditCards,
                        connectedItemID: connectedItemID,
                        statusMessage: statusMessage,
                        isLoadingSavedCards: isLoadingSavedCards,
                        transactionDestination: transactionDestination
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Menu {
                    ForEach(availableMonths, id: \.self) { month in
                        Button {
                            onSelectMonth(month)
                        } label: {
                            HStack {
                                Text(BudgetMonthFormatter.title(for: month))
                                if month == selectedMonth {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(BudgetMonthFormatter.title(for: selectedMonth))
                        Image(systemName: "chevron.down")
                            .font(.caption.bold())
                    }
                    .font(.title3)
                    .fontWeight(.semibold)
                    .fontWidth(.expanded)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .textCase(.uppercase)
                }
                .buttonStyle(.plain)

                Spacer()

                Menu {
                    Button(action: onConnect) {
                        Label("Connect accounts", systemImage: "plus")
                    }
                    .disabled(isLoadingLinkToken)

                    Picker("Appearance", selection: Binding(
                        get: { selectedColorScheme },
                        set: { onSelectColorScheme($0) }
                    )) {
                        ForEach(AppColorScheme.allCases) { colorScheme in
                            Label(colorScheme.title, systemImage: colorScheme.iconName)
                                .tag(colorScheme)
                        }
                    }

                    Button(role: .destructive, action: onLogOut) {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.primary, Color(.tertiarySystemFill))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            Text("Budget")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.primary)
        }
    }

}

private struct BudgetSegmentedTabs: View {
    @Binding var selection: BudgetHomeTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BudgetHomeTab.allCases) { tab in
                Button {
                    withAnimation(.snappy) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selection == tab ? Color.primary : Color(.tertiaryLabel))
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

private struct BudgetOverviewTab: View {
    let budget: Decimal
    let spent: Decimal
    let isLoading: Bool
    let categories: [SpendingCategory]
    let transactions: [CreditCardTransaction]
    let month: String
    @State private var selectedCategory: BudgetCategory?
    @State private var presentedCategory: BudgetCategory?

    var body: some View {
        VStack(spacing: 30) {
            spendingHeader

            SpendingPieChart(
                categories: displayCategories,
                budget: budget,
                selectedCategory: selectedCategory,
                onSelectCategory: { category in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                        selectedCategory = category
                    }
                    presentedCategory = category
                }
            )
                .frame(height: 310)
                .padding(.top, 6)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(displayCategories) { category in
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                            selectedCategory = category.category
                        }
                        presentedCategory = category.category
                    } label: {
                        CategoryTile(category: category)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $presentedCategory, onDismiss: {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                selectedCategory = nil
            }
        }) { category in
            CategoryTransactionsSheet(
                category: category,
                month: month,
                transactions: transactions.filter { $0.budgetCategory == category }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var spendingHeader: some View {
        VStack(spacing: 12) {
            Text(BudgetMonthFormatter.spendingTitle(for: month))
                .font(.subheadline)
                .fontWeight(.semibold)
                .fontWidth(.expanded)
                .tracking(3)
                .foregroundStyle(Color(.tertiaryLabel))
                .textCase(.uppercase)

            if isLoading {
                ProgressView()
            }

            Text(CurrencyFormatter.string(from: selectedCategoryAmount ?? spent))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()

            if let selectedCategory, let selectedCategoryAmount {
                HStack(spacing: 10) {
                    Circle()
                        .fill(selectedCategory.color)
                        .frame(width: 12, height: 12)

                    Text(selectedCategory.title)
                        .foregroundStyle(selectedCategory.color)

                    Text("·")
                        .foregroundStyle(Color(.tertiaryLabel))

                    Text("\(categoryPercent(for: selectedCategoryAmount))%")
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .font(.title3)
                .fontWeight(.semibold)
            } else {
                Text("\(spentPercent)% of \(CurrencyFormatter.string(from: budget)) budget")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(spent > budget ? Color.red : Color.green)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var displayCategories: [SpendingCategory] {
        categories
    }

    private var spentPercent: Int {
        let budgetValue = (budget as NSDecimalNumber).doubleValue
        guard budgetValue > 0 else { return 0 }
        let spentValue = (spent as NSDecimalNumber).doubleValue
        return Int((spentValue / budgetValue * 100).rounded())
    }

    private var selectedCategoryAmount: Decimal? {
        guard let selectedCategory else {
            return nil
        }

        return displayCategories.first { $0.category == selectedCategory }?.amount
    }

    private func categoryPercent(for amount: Decimal) -> Int {
        let spentValue = (spent as NSDecimalNumber).doubleValue
        guard spentValue > 0 else { return 0 }
        let amountValue = (amount as NSDecimalNumber).doubleValue
        return Int((amountValue / spentValue * 100).rounded())
    }

}

private struct CategoryTransactionsSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let category: BudgetCategory
    let month: String
    let transactions: [CreditCardTransaction]

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No \(category.title) transactions",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Nothing was recorded in \(BudgetMonthFormatter.title(for: month)).")
                    )
                } else {
                    List {
                        Section {
                            ForEach(transactions) { transaction in
                                TransactionRow(transaction: transaction)
                                    .padding(.vertical, 4)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(BudgetMonthFormatter.title(for: month))

                                HStack {
                                    Text("\(transactions.count) transaction\(transactions.count == 1 ? "" : "s")")
                                    Spacer()
                                    Text(CurrencyFormatter.string(from: total))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var total: Decimal {
        transactions.reduce(.zero) { $0 + $1.amount }
    }
}

private struct BudgetTransactionsTab: View {
    let transactions: [CreditCardTransaction]
    let isLoading: Bool
    let month: String
    @State private var ordering: TransactionOrdering = .date

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                ProgressView("Loading transactions...")
                    .frame(maxWidth: .infinity)
            } else if transactions.isEmpty {
                ContentUnavailableView(
                    "No transactions in \(BudgetMonthFormatter.title(for: month))",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Connect an account or wait for Plaid transactions to sync.")
                )
            } else {
                orderingMenu

                switch ordering {
                case .date:
                    ForEach(dateOrderedTransactions) { transaction in
                        transactionCard(transaction)
                    }
                case .category:
                    ForEach(categorySections, id: \.category) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(section.category.color)
                                    .frame(width: 10, height: 10)

                                Text(section.category.title)
                                    .font(.headline)

                                Spacer()

                                Text("\(section.transactions.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 4)

                            ForEach(section.transactions) { transaction in
                                transactionCard(transaction)
                            }
                        }
                    }
                }
            }
        }
    }

    private var orderingMenu: some View {
        HStack {
            Text("Order by")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Picker("Order transactions", selection: $ordering) {
                    ForEach(TransactionOrdering.allCases) { option in
                        Label(option.title, systemImage: option.iconName)
                            .tag(option)
                    }
                }
            } label: {
                Label(ordering.title, systemImage: ordering.iconName)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Order transactions by \(ordering.title)")
        }
    }

    private var dateOrderedTransactions: [CreditCardTransaction] {
        transactions.sorted {
            if $0.date == $1.date {
                return $0.vendorName.localizedCaseInsensitiveCompare($1.vendorName) == .orderedAscending
            }
            return $0.date > $1.date
        }
    }

    private var categorySections: [(category: BudgetCategory, transactions: [CreditCardTransaction])] {
        BudgetCategory.allCases.compactMap { category in
            let matches = dateOrderedTransactions.filter { $0.budgetCategory == category }
            return matches.isEmpty ? nil : (category, matches)
        }
    }

    private func transactionCard(_ transaction: CreditCardTransaction) -> some View {
        TransactionRow(transaction: transaction)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum TransactionOrdering: String, CaseIterable, Identifiable {
    case date
    case category

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date:
            "Date"
        case .category:
            "Category"
        }
    }

    var iconName: String {
        switch self {
        case .date:
            "calendar"
        case .category:
            "square.grid.2x2"
        }
    }
}

private struct BudgetAccountsTab<Destination: View>: View {
    let creditCards: [CreditCardAccount]
    let connectedItemID: String?
    let statusMessage: String
    let isLoadingSavedCards: Bool
    let transactionDestination: (CreditCardAccount, String) -> Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoadingSavedCards {
                ProgressView("Loading saved accounts...")
                    .frame(maxWidth: .infinity)
            }

            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            if creditCards.isEmpty {
                ContentUnavailableView(
                    "No connected accounts",
                    systemImage: "creditcard",
                    description: Text("Use Settings to connect an account.")
                )
            } else {
                ForEach(creditCards) { card in
                    if let itemID = card.itemID ?? connectedItemID {
                        NavigationLink {
                            transactionDestination(card, itemID)
                        } label: {
                            CreditCardRow(card: card)
                                .padding(16)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        CreditCardRow(card: card)
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }
}

private struct SpendingPieChart: View {
    let categories: [SpendingCategory]
    let budget: Decimal
    let selectedCategory: BudgetCategory?
    let onSelectCategory: (BudgetCategory) -> Void

    var body: some View {
        GeometryReader { proxy in
            let canvasDiameter = min(proxy.size.width, proxy.size.height)
            let popOutDistance = canvasDiameter * 0.065
            let chartDiameter = canvasDiameter - popOutDistance * 2
            let lineWidth = chartDiameter * 0.22
            let chartSize = CGSize(width: canvasDiameter, height: canvasDiameter)

            ZStack {
                Canvas { context, size in
                    let radius = (chartDiameter - lineWidth) / 2
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var trackPath = Path()
                    trackPath.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270),
                        clockwise: false
                    )
                    context.stroke(
                        trackPath,
                        with: .color(Color(.tertiaryLabel).opacity(0.28)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )

                    for segment in chartSegments {
                        let isSelected = segment.category == selectedCategory
                        let isDimmed = selectedCategory != nil && !isSelected
                        let segmentCenter = isSelected
                            ? center.offset(by: segment.popOutOffset(distance: popOutDistance))
                            : center
                        let startAngle = Angle.degrees(segment.startDegrees - 90)
                        let endAngle = Angle.degrees(segment.endDegrees - 90)
                        var path = Path()
                        path.addArc(
                            center: segmentCenter,
                            radius: radius,
                            startAngle: startAngle,
                            endAngle: endAngle,
                            clockwise: false
                        )
                        context.stroke(
                            path,
                            with: .color(segment.category.color.opacity(isDimmed ? 0.24 : 1)),
                            style: StrokeStyle(
                                lineWidth: isSelected ? lineWidth * 1.08 : lineWidth,
                                lineCap: .butt
                            )
                        )
                    }
                }
                .frame(width: canvasDiameter, height: canvasDiameter)
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: selectedCategory)

                Circle()
                    .fill(Color.clear)
                    .contentShape(Circle())
                    .frame(width: canvasDiameter, height: canvasDiameter)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                guard let category = category(
                                    at: value.location,
                                    in: chartSize,
                                    lineWidth: lineWidth,
                                    popOutDistance: popOutDistance
                                ) else {
                                    return
                                }

                                onSelectCategory(category)
                            }
                    )
            }
            .frame(width: canvasDiameter, height: canvasDiameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chartSegments: [ChartSegment] {
        let budgetTotal = max((budget as NSDecimalNumber).doubleValue, 0)
        guard budgetTotal > 0 else {
            return []
        }

        var startDegrees = 0.0
        var segments: [ChartSegment] = []

        for category in categories {
            let value = max((category.amount as NSDecimalNumber).doubleValue, 0)
            guard value > 0, startDegrees < 360 else {
                continue
            }

            let sweep = min(value / budgetTotal * 360, 360 - startDegrees)
            guard sweep > 0 else {
                continue
            }

            let endDegrees = startDegrees + sweep
            segments.append(ChartSegment(
                category: category.category,
                startDegrees: startDegrees,
                endDegrees: endDegrees
            ))
            startDegrees = endDegrees
        }

        return segments
    }

    private func category(
        at location: CGPoint,
        in size: CGSize,
        lineWidth: CGFloat,
        popOutDistance: CGFloat
    ) -> BudgetCategory? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let chartDiameter = min(size.width, size.height) - popOutDistance * 2
        let radius = (chartDiameter - lineWidth) / 2
        let tapTolerance = lineWidth * 0.38
        let innerRadius = radius - lineWidth / 2 - tapTolerance
        let outerRadius = radius + lineWidth / 2 + tapTolerance + popOutDistance

        guard distance >= innerRadius, distance <= outerRadius else {
            return nil
        }

        let rawDegrees = atan2(dx, -dy) * 180 / .pi
        let degrees = rawDegrees < 0 ? rawDegrees + 360 : rawDegrees

        return chartSegments.first { segment in
            degrees >= segment.startDegrees && degrees < segment.endDegrees
        }?.category
    }
}

private struct ChartSegment {
    let category: BudgetCategory
    let startDegrees: Double
    let endDegrees: Double

    func popOutOffset(distance: CGFloat) -> CGSize {
        let middleRadians = ((startDegrees + endDegrees) / 2) * .pi / 180
        return CGSize(
            width: sin(middleRadians) * distance,
            height: -cos(middleRadians) * distance
        )
    }
}

private extension CGPoint {
    func offset(by size: CGSize) -> CGPoint {
        CGPoint(x: x + size.width, y: y + size.height)
    }
}

private struct CategoryTile: View {
    let category: SpendingCategory

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(category.category.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(category.category.title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(CurrencyFormatter.string(from: category.amount))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(.separator).opacity(0.45), lineWidth: 1)
        }
    }
}

private struct CreditCardTransactionsView: View {
    let card: CreditCardAccount
    let itemID: String
    let plaidBackendClient: PlaidBackendClient

    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var transactions: [CreditCardTransaction] = []

    var body: some View {
        List {
            Section {
                CreditCardRow(card: card)
            }

            Section("Transactions") {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                } else if transactions.isEmpty {
                    Text("No transactions returned for this card yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transactions) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                }
            }
        }
        .navigationTitle(card.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTransactions()
        }
    }

    @MainActor
    private func loadTransactions() async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await plaidBackendClient.fetchPurchaseHistory(itemID: itemID)
            transactions = response.transactions
                .filter { $0.accountID == card.id }
                .sorted { $0.date > $1.date }
            print("Loaded \(transactions.count) transactions for \(card.displayName).")
        } catch {
            print("Failed to load transactions for \(card.displayName): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private struct BudgetSetupView: View {
    @State private var budgetText = ""
    @State private var errorMessage: String?

    let onSave: (Decimal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()

            Text("What is your total monthly budget?")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Monthly budget", text: $budgetText)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                saveBudget()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
    }

    private func saveBudget() {
        let cleanedBudget = budgetText
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let budget = Decimal(string: cleanedBudget), budget > 0 else {
            errorMessage = "Enter a monthly budget greater than 0."
            return
        }

        errorMessage = nil
        onSave(budget)
    }
}

private struct BudgetDashboardView: View {
    let spent: Decimal
    let budget: Decimal
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                BudgetPieChart(spent: spent, budget: budget)
                    .frame(width: 230, height: 230)

                VStack(spacing: 4) {
                    if isLoading {
                        ProgressView()
                    }

                    Text("\(currencyText(spent)) / \(currencyText(budget))")
                        .font(.headline)
                        .monospacedDigit()

                    Text("This month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }

            HStack {
                BudgetLegendItem(color: .orange, title: "Spent", value: currencyText(spent))
                Spacer()
                BudgetLegendItem(color: remainingColor, title: "Remaining", value: currencyText(remainingBudget))
            }
        }
    }

    private var remainingBudget: Decimal {
        max(budget - spent, .zero)
    }

    private var remainingColor: Color {
        spent > budget ? .red : .green
    }

    private func currencyText(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}

private struct BudgetPieChart: View {
    let spent: Decimal
    let budget: Decimal

    var body: some View {
        ZStack {
            Circle()
                .stroke(spent > budget ? Color.red.opacity(0.2) : Color.green.opacity(0.22), lineWidth: 34)

            Circle()
                .trim(from: 0, to: spentFraction)
                .stroke(
                    spent > budget ? Color.red : Color.orange,
                    style: StrokeStyle(lineWidth: 34, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
        }
        .accessibilityLabel("Monthly budget chart")
        .accessibilityValue("\(spentFraction * 100, specifier: "%.0f") percent spent")
    }

    private var spentFraction: Double {
        let budgetValue = (budget as NSDecimalNumber).doubleValue
        guard budgetValue > 0 else {
            return 0
        }

        let spentValue = (spent as NSDecimalNumber).doubleValue
        return min(max(spentValue / budgetValue, 0), 1)
    }
}

private struct BudgetLegendItem: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .monospacedDigit()
            }
        }
    }
}

private extension UIApplication {
    var rootViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}

private struct CreditCardRow: View {
    let card: CreditCardAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.displayName)
                        .font(.headline)

                    Text(card.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let mask = card.mask {
                    Text("...\(mask)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                BalanceLabel(title: "Current", value: card.currentBalanceText)
                Spacer()
                BalanceLabel(title: "Available", value: card.availableBalanceText)
                Spacer()
                BalanceLabel(title: "Limit", value: card.limitText)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct TransactionRow: View {
    let transaction: CreditCardTransaction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.vendorName)
                    .font(.headline)

                Text(transaction.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(transaction.amountText)
                .font(.subheadline)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

private struct BalanceLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }
}

private final class PlaidBackendClient {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func createLinkToken(userID: String) async throws -> LinkTokenResponse {
        let endpoint = baseURL.appending(path: "api/link/token/create")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(LinkTokenRequest(userID: userID))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(LinkTokenErrorResponse.self, from: data) {
                throw LinkTokenError.requestFailed(errorResponse.error)
            }

            throw LinkTokenError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(LinkTokenResponse.self, from: data)
    }

    func exchangePublicToken(_ publicToken: String, userID: String?) async throws -> PublicTokenExchangeResponse {
        let endpoint = baseURL.appending(path: "api/item/public_token/exchange")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(PublicTokenExchangeRequest(
            publicToken: publicToken,
            userID: userID
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(LinkTokenErrorResponse.self, from: data) {
                throw LinkTokenError.requestFailed(errorResponse.error)
            }

            throw LinkTokenError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(PublicTokenExchangeResponse.self, from: data)
    }

    func fetchPurchaseHistory(itemID: String, fullRefresh: Bool = false) async throws -> PurchaseHistoryResponse {
        let endpoint = baseURL.appending(path: "api/purchase-history")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(PurchaseHistoryRequest(
            itemID: itemID,
            forceFullRefresh: fullRefresh
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(LinkTokenErrorResponse.self, from: data) {
                throw LinkTokenError.requestFailed(errorResponse.error)
            }

            throw LinkTokenError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(PurchaseHistoryResponse.self, from: data)
    }

    func fetchSavedCreditCards(userID: String) async throws -> SavedCreditCardsResponse {
        let endpoint = baseURL.appending(path: "api/users/\(userID)/credit-cards")
        let (data, response) = try await session.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(LinkTokenErrorResponse.self, from: data) {
                throw LinkTokenError.requestFailed(errorResponse.error)
            }

            throw LinkTokenError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(SavedCreditCardsResponse.self, from: data)
    }

    func fetchMonthlySummary(userID: String, month: String, refresh: Bool) async throws -> MonthlySpendingSummaryResponse {
        let endpoint = baseURL.appending(path: "api/users/\(userID)/monthly-summary")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LinkTokenError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "month", value: month),
            URLQueryItem(name: "refresh", value: refresh ? "true" : "false")
        ]

        guard let url = components.url else {
            throw LinkTokenError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(LinkTokenErrorResponse.self, from: data) {
                throw LinkTokenError.requestFailed(errorResponse.error)
            }

            throw LinkTokenError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(MonthlySpendingSummaryResponse.self, from: data)
    }

    func fetchMonthlySummaryMonths(userID: String) async throws -> MonthlySummaryMonthsResponse {
        let endpoint = baseURL.appending(path: "api/users/\(userID)/monthly-summary-months")
        let (data, response) = try await session.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(LinkTokenErrorResponse.self, from: data) {
                throw LinkTokenError.requestFailed(errorResponse.error)
            }

            throw LinkTokenError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(MonthlySummaryMonthsResponse.self, from: data)
    }

    func fetchMonthlyTransactions(userID: String, month: String, refresh: Bool) async throws -> MonthlyTransactionsResponse {
        let endpoint = baseURL.appending(path: "api/users/\(userID)/monthly-transactions")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LinkTokenError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "month", value: month),
            URLQueryItem(name: "refresh", value: refresh ? "true" : "false")
        ]

        guard let url = components.url else {
            throw LinkTokenError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(LinkTokenErrorResponse.self, from: data) {
                throw LinkTokenError.requestFailed(errorResponse.error)
            }

            throw LinkTokenError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(MonthlyTransactionsResponse.self, from: data)
    }
}

private struct LinkTokenRequest: Encodable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "userId"
    }
}

private struct LinkTokenResponse: Decodable {
    let linkToken: String
    let expiration: String
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case linkToken
        case expiration
        case requestID = "requestId"
    }
}

private struct PublicTokenExchangeRequest: Encodable {
    let publicToken: String
    let userID: String?

    enum CodingKeys: String, CodingKey {
        case publicToken
        case userID = "userId"
    }
}

private struct PublicTokenExchangeResponse: Decodable {
    let itemID: String
    let requestID: String
    let persisted: Bool
    let creditCards: [CreditCardAccount]

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case requestID = "requestId"
        case persisted
        case creditCards
    }
}

private struct PurchaseHistoryRequest: Encodable {
    let itemID: String
    let forceFullRefresh: Bool

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case cursor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemID, forKey: .itemID)

        if forceFullRefresh {
            try container.encodeNil(forKey: .cursor)
        }
    }
}

private struct PurchaseHistoryResponse: Decodable {
    let transactions: [CreditCardTransaction]
}

private struct SavedCreditCardsResponse: Decodable {
    let creditCards: [CreditCardAccount]
}

private struct MonthlySpendingSummaryResponse: Decodable {
    let month: String
    let totalSpent: Decimal
    let transactionCount: Int
    let categories: [MonthlySpendingCategoryResponse]

    var spendingCategories: [SpendingCategory] {
        BudgetCategory.allCases.map { budgetCategory in
            let category = categories.first { $0.budgetCategory == budgetCategory }
            return SpendingCategory(category: budgetCategory, amount: category?.amount ?? .zero)
        }
    }
}

private struct MonthlySummaryMonthsResponse: Decodable {
    let months: [String]
}

private struct MonthlyTransactionsResponse: Decodable {
    let month: String
    let transactionCount: Int
    let transactions: [CreditCardTransaction]
}

private struct MonthlySpendingCategoryResponse: Decodable {
    let category: String
    let amount: Decimal

    var budgetCategory: BudgetCategory {
        BudgetCategory(rawValue: category) ?? .other
    }
}

private struct CreditCardAccount: Decodable, Identifiable {
    let id: String
    let itemID: String?
    let name: String
    let officialName: String?
    let mask: String?
    let type: String
    let subtype: String?
    let currentBalance: Decimal?
    let availableBalance: Decimal?
    let limit: Decimal?
    let isoCurrencyCode: String?
    let unofficialCurrencyCode: String?

    enum CodingKeys: String, CodingKey {
        case id
        case itemID = "itemId"
        case name
        case officialName
        case mask
        case type
        case subtype
        case currentBalance
        case availableBalance
        case limit
        case isoCurrencyCode
        case unofficialCurrencyCode
    }

    var displayName: String {
        officialName?.nilIfBlank ?? name
    }

    var details: String {
        [subtype?.nilIfBlank, type.nilIfBlank]
            .compactMap { $0 }
            .joined(separator: " ")
            .capitalized
    }

    var currentBalanceText: String {
        formatCurrency(currentBalance)
    }

    var availableBalanceText: String {
        formatCurrency(availableBalance)
    }

    var limitText: String {
        formatCurrency(limit)
    }

    private func formatCurrency(_ amount: Decimal?) -> String {
        guard let amount else {
            return "-"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = isoCurrencyCode ?? unofficialCurrencyCode ?? "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    func withItemID(_ itemID: String) -> CreditCardAccount {
        CreditCardAccount(
            id: id,
            itemID: itemID,
            name: name,
            officialName: officialName,
            mask: mask,
            type: type,
            subtype: subtype,
            currentBalance: currentBalance,
            availableBalance: availableBalance,
            limit: limit,
            isoCurrencyCode: isoCurrencyCode,
            unofficialCurrencyCode: unofficialCurrencyCode
        )
    }
}

struct CreditCardTransaction: Decodable, Identifiable {
    let transactionID: String
    let accountID: String
    let name: String
    let merchantName: String?
    let amount: Decimal
    let isoCurrencyCode: String?
    let unofficialCurrencyCode: String?
    let date: String
    let pending: Bool
    let category: [String]?

    var id: String {
        transactionID
    }

    var vendorName: String {
        merchantName?.nilIfBlank ?? name
    }

    var amountText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = isoCurrencyCode ?? unofficialCurrencyCode ?? "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    func isInMonth(_ month: String) -> Bool {
        date.hasPrefix(month)
    }

    fileprivate var budgetCategory: BudgetCategory {
        let searchableText = ([name, merchantName].compactMap { $0 } + (category ?? []))
            .joined(separator: " ")
            .lowercased()

        if searchableText.contains("food")
            || searchableText.contains("drink")
            || searchableText.contains("restaurant")
            || searchableText.contains("coffee")
            || searchableText.contains("cafe") {
            return .food
        }

        if searchableText.contains("shop")
            || searchableText.contains("store")
            || searchableText.contains("merchandise")
            || searchableText.contains("retail") {
            return .shopping
        }

        if searchableText.contains("transport")
            || searchableText.contains("taxi")
            || searchableText.contains("uber")
            || searchableText.contains("lyft")
            || searchableText.contains("parking")
            || searchableText.contains("gas") {
            return .transport
        }

        if searchableText.contains("entertainment")
            || searchableText.contains("recreation")
            || searchableText.contains("movie")
            || searchableText.contains("music")
            || searchableText.contains("ticket") {
            return .entertainment
        }

        return .other
    }

    static var sampleTransactions: [CreditCardTransaction] {
        [
            sample(id: "sample-grocery", name: "Grocery Market", merchantName: "Grocery Market", amount: Decimal(231.45), category: ["Food and Drink", "Groceries"]),
            sample(id: "sample-cafe", name: "Cafe Latte", merchantName: "Cafe Latte", amount: Decimal(255.55), category: ["Food and Drink", "Coffee"]),
            sample(id: "sample-retail", name: "Weekend Store", merchantName: "Weekend Store", amount: Decimal(313), category: ["Shops", "Retail"]),
            sample(id: "sample-gas", name: "Gas Station", merchantName: "Gas Station", amount: Decimal(149), category: ["Transportation", "Gas"]),
            sample(id: "sample-movie", name: "Movie Tickets", merchantName: "Movie Tickets", amount: Decimal(90), category: ["Entertainment"]),
            sample(id: "sample-other", name: "Home Supplies", merchantName: "Home Supplies", amount: Decimal(295), category: ["Other"])
        ]
    }

    private static var currentMonthPrefix: String {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        guard let year = components.year, let month = components.month else {
            return ""
        }

        return String(format: "%04d-%02d", year, month)
    }

    private static func sample(
        id: String,
        name: String,
        merchantName: String,
        amount: Decimal,
        category: [String]
    ) -> CreditCardTransaction {
        CreditCardTransaction(
            transactionID: id,
            accountID: "sample-card",
            name: name,
            merchantName: merchantName,
            amount: amount,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: nil,
            date: "\(currentMonthPrefix)-12",
            pending: false,
            category: category
        )
    }

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case accountID = "account_id"
        case name
        case merchantName = "merchant_name"
        case amount
        case isoCurrencyCode = "iso_currency_code"
        case unofficialCurrencyCode = "unofficial_currency_code"
        case date
        case pending
        case category
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct LinkTokenErrorResponse: Decodable {
    let error: String
}

private enum LinkTokenError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid response."
        case .requestFailed(let message):
            message
        }
    }
}
