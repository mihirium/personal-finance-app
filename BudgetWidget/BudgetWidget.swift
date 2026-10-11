import SwiftUI
import WidgetKit

private enum SharedBudgetData {
    static let appGroupIdentifier = "group.mihirsangam.personal-finances"

    private enum Key {
        static let monthlyBudget = "widget.monthlyBudget"
        static let todaySpent = "widget.todaySpent"
        static let monthlySpent = "widget.monthlySpent"
        static let recentTransactions = "widget.recentTransactions"
        static let updatedAt = "widget.updatedAt"
    }

    static func entry(date: Date = Date()) -> DailySpendEntry {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        let updatedAt = Date(timeIntervalSince1970: defaults?.double(forKey: Key.updatedAt) ?? 0)
        let storedTodaySpent = defaults?.double(forKey: Key.todaySpent) ?? 0
        let isCurrentMonth = Calendar.current.isDate(updatedAt, equalTo: date, toGranularity: .month)
        let storedTransactions = defaults?.data(forKey: Key.recentTransactions)
            .flatMap { try? JSONDecoder().decode([WidgetTransaction].self, from: $0) } ?? []
        return DailySpendEntry(
            date: date,
            monthlyBudget: defaults?.double(forKey: Key.monthlyBudget) ?? 0,
            todaySpent: Calendar.current.isDate(updatedAt, inSameDayAs: date) ? storedTodaySpent : 0,
            monthlySpent: isCurrentMonth ? defaults?.double(forKey: Key.monthlySpent) ?? 0 : 0,
            recentTransactions: isCurrentMonth ? storedTransactions : [],
            updatedAt: updatedAt
        )
    }
}

private struct WidgetTransaction: Codable, Identifiable {
    var id: String { "\(date)-\(vendorName)-\(amount)" }

    let vendorName: String
    let amount: Double
    let date: String
}

private struct DailySpendEntry: TimelineEntry {
    let date: Date
    let monthlyBudget: Double
    let todaySpent: Double
    let monthlySpent: Double
    let recentTransactions: [WidgetTransaction]
    let updatedAt: Date

    var dailyAllowance: Double {
        let days = Calendar.current.range(of: .day, in: .month, for: date)?.count ?? 30
        return monthlyBudget / Double(days)
    }

    var usedPercent: Int {
        guard dailyAllowance > 0 else { return 0 }
        return Int((todaySpent / dailyAllowance * 100).rounded())
    }

    var exceededPercent: Int {
        max(usedPercent - 100, 0)
    }

    var isOverBudget: Bool {
        todaySpent > dailyAllowance && dailyAllowance > 0
    }

    var monthlyUsedPercent: Int {
        guard monthlyBudget > 0 else { return 0 }
        return Int((monthlySpent / monthlyBudget * 100).rounded())
    }

    var isOverMonthlyBudget: Bool {
        monthlySpent > monthlyBudget
    }
}

private struct DailySpendProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailySpendEntry {
        DailySpendEntry(
            date: Date(),
            monthlyBudget: 1_750,
            todaySpent: 72,
            monthlySpent: 1_334.06,
            recentTransactions: [
                WidgetTransaction(vendorName: "Grocery Market", amount: 84.21, date: "2026-10-10"),
                WidgetTransaction(vendorName: "Coffee House", amount: 6.75, date: "2026-10-10"),
                WidgetTransaction(vendorName: "Metro", amount: 18, date: "2026-10-09")
            ],
            updatedAt: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DailySpendEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SharedBudgetData.entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailySpendEntry>) -> Void) {
        let entry = SharedBudgetData.entry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date) ?? entry.date
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

private struct DailySpendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DailySpendEntry

    var body: some View {
        if entry.monthlyBudget <= 0 {
            unavailableView
        } else if family == .systemSmall {
            smallContent
        } else {
            mediumContent
        }
    }

    private var smallContent: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 12)

            Circle()
                .trim(from: 0, to: min(Double(entry.usedPercent) / 100, 1))
                .stroke(
                    entry.isOverBudget ? Color.red : Color.green,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(entry.usedPercent)%")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)

                Text("spent today")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .padding(4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.usedPercent) percent spent today")
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private var mediumContent: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THIS MONTH")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("\(entry.monthlyUsedPercent)%")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(entry.isOverMonthlyBudget ? Color.red : Color.primary)

                Text("spent")
                    .font(.subheadline.weight(.semibold))

                ProgressView(value: min(Double(entry.monthlyUsedPercent), 100), total: 100)
                    .tint(entry.isOverMonthlyBudget ? .red : .green)

                Text("\(currency(entry.monthlySpent)) of \(currency(entry.monthlyBudget))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("LATEST")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if entry.recentTransactions.isEmpty {
                    Spacer(minLength: 0)
                    Text("No transactions yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(entry.recentTransactions.prefix(3)) { transaction in
                        transactionRow(transaction)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private var unavailableView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "chart.donut")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Set a monthly budget")
                .font(.headline)
            Text("Open Budget to prepare your daily spending target.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private func transactionRow(_ transaction: WidgetTransaction) -> some View {
        HStack(spacing: 6) {
            Text(transaction.vendorName)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 2)

            Text(currency(transaction.amount))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func currency(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }
}

struct DailySpendWidget: Widget {
    let kind = "DailySpendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailySpendProvider()) { entry in
            DailySpendWidgetView(entry: entry)
        }
        .configurationDisplayName("Daily Spending")
        .description("See how much of today's spending allowance you've used.")
        .supportedFamilies([.systemSmall])
    }
}

struct MonthlySpendWidget: Widget {
    let kind = "MonthlySpendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailySpendProvider()) { entry in
            DailySpendWidgetView(entry: entry)
        }
        .configurationDisplayName("Monthly Spending")
        .description("Track this month's budget and your latest transactions.")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct BudgetWidgetBundle: WidgetBundle {
    var body: some Widget {
        DailySpendWidget()
        MonthlySpendWidget()
    }
}
