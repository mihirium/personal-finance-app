import Foundation
import WidgetKit

enum BudgetWidgetSnapshotStore {
    static let appGroupIdentifier = "group.mihirsangam.personal-finances"

    private static let widgetKinds = ["DailySpendWidget", "MonthlySpendWidget"]

    private enum Key {
        static let monthlyBudget = "widget.monthlyBudget"
        static let todaySpent = "widget.todaySpent"
        static let monthlySpent = "widget.monthlySpent"
        static let recentTransactions = "widget.recentTransactions"
        static let updatedAt = "widget.updatedAt"
    }

    private struct RecentTransaction: Codable {
        let vendorName: String
        let amount: Double
        let date: String
    }

    static func save(monthlyBudget: Decimal, transactions: [CreditCardTransaction]) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        let today = dayFormatter.string(from: Date())
        let todaySpent = transactions
            .filter { $0.date == today }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let monthlySpent = transactions.reduce(Decimal.zero) { $0 + $1.amount }
        let recentTransactions = transactions
            .sorted {
                if $0.date == $1.date {
                    return $0.vendorName.localizedCaseInsensitiveCompare($1.vendorName) == .orderedAscending
                }
                return $0.date > $1.date
            }
            .prefix(3)
            .map {
                RecentTransaction(
                    vendorName: $0.vendorName,
                    amount: ($0.amount as NSDecimalNumber).doubleValue,
                    date: $0.date
                )
            }

        defaults.set((monthlyBudget as NSDecimalNumber).doubleValue, forKey: Key.monthlyBudget)
        defaults.set((todaySpent as NSDecimalNumber).doubleValue, forKey: Key.todaySpent)
        defaults.set((monthlySpent as NSDecimalNumber).doubleValue, forKey: Key.monthlySpent)
        defaults.set(try? JSONEncoder().encode(recentTransactions), forKey: Key.recentTransactions)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.updatedAt)
        reloadWidgets()
    }

    static func clear() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.removeObject(forKey: Key.monthlyBudget)
        defaults.removeObject(forKey: Key.todaySpent)
        defaults.removeObject(forKey: Key.monthlySpent)
        defaults.removeObject(forKey: Key.recentTransactions)
        defaults.removeObject(forKey: Key.updatedAt)
        reloadWidgets()
    }

    private static func reloadWidgets() {
        widgetKinds.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
