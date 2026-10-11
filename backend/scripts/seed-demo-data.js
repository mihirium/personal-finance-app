import "dotenv/config";

import { closeDatabase, query } from "../src/database.js";
import { calculateMonthlySpendingSummary, saveMonthlySpendingSummary } from "../src/monthlySpending.js";
import { listTransactionsForUserMonth } from "../src/transactions.js";

const demoPurchases = [
  { name: "Neighborhood Grocery", merchant: "Neighborhood Grocery", category: ["Food and Drink", "Groceries"], september: 86.42, october: 92.18 },
  { name: "Corner Cafe", merchant: "Corner Cafe", category: ["Food and Drink", "Coffee"], september: 14.75, october: 18.2 },
  { name: "Pasta House Restaurant", merchant: "Pasta House", category: ["Food and Drink", "Restaurant"], september: 48.3, october: 54.6 },
  { name: "Morning Coffee", merchant: "Morning Coffee", category: ["Food and Drink", "Coffee"], september: 7.85, october: 9.25 },
  { name: "Downtown Retail Store", merchant: "Downtown Retail Store", category: ["Shops", "Retail"], september: 74.99, october: 119.5 },
  { name: "Online Shop", merchant: "Online Shop", category: ["Shops", "Online Marketplace"], september: 39.45, october: 63.2 },
  { name: "Clothing Store", merchant: "Clothing Store", category: ["Shops", "Apparel"], september: 128, october: 89.99 },
  { name: "Uber Ride", merchant: "Uber", category: ["Transportation", "Taxi"], september: 22.4, october: 27.15 },
  { name: "Gas Station", merchant: "City Gas Station", category: ["Transportation", "Gas"], september: 51.7, october: 47.8 },
  { name: "Parking Garage", merchant: "Central Parking", category: ["Transportation", "Parking"], september: 18, october: 24 },
  { name: "Movie Tickets", merchant: "Cinema", category: ["Entertainment", "Movies"], september: 31.5, october: 36 },
  { name: "Music Subscription", merchant: "Music Subscription", category: ["Entertainment", "Music"], september: 10.99, october: 10.99 },
  { name: "Electric Bill", merchant: "Metro Electric", category: ["Utilities"], september: 96.25, october: 88.4 },
  { name: "Gym Membership", merchant: "Fitness Club", category: ["Personal Care"], september: 45, october: 45 },
  { name: "Mobile Phone Bill", merchant: "Mobile Wireless", category: ["Utilities", "Phone"], september: 62.1, october: 62.1 }
];

const seedMonths = monthRange("2025-10", "2026-10");
const standardMonthDays = [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 25, 27, 29];
const currentMonthDays = [1, 2, 3, 4, 5, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10];

function monthRange(startMonth, endMonth) {
  const [startYear, startMonthNumber] = startMonth.split("-").map(Number);
  const [endYear, endMonthNumber] = endMonth.split("-").map(Number);
  const months = [];
  let year = startYear;
  let month = startMonthNumber;

  while (year < endYear || (year === endYear && month <= endMonthNumber)) {
    months.push(`${year}-${String(month).padStart(2, "0")}`);
    month += 1;
    if (month === 13) {
      year += 1;
      month = 1;
    }
  }

  return months;
}

function amountForMonth(purchase, month, purchaseIndex) {
  if (month === "2026-09") {
    return purchase.september;
  }
  if (month === "2026-10") {
    return purchase.october;
  }

  const monthIndex = seedMonths.indexOf(month);
  const categoryVariation = ((purchaseIndex % 5) - 2) * 0.015;
  const monthVariation = 0.84 + monthIndex * 0.012;
  return Math.round(purchase.september * (monthVariation + categoryVariation) * 100) / 100;
}

function validDayForMonth(month, day) {
  const [year, monthNumber] = month.split("-").map(Number);
  const lastDay = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
  return Math.min(day, lastDay);
}

async function demoTarget() {
  const result = await query(`
    select items.user_id, transactions.plaid_item_id, transactions.account_id
    from plaid_transactions transactions
    join plaid_items items using (plaid_item_id)
    group by items.user_id, transactions.plaid_item_id, transactions.account_id
    order by count(*) desc
    limit 1
  `);

  if (!result.rows[0]) {
    throw new Error("Connect and sync a credit card before seeding demo transactions.");
  }

  return result.rows[0];
}

async function seedMonth(target, month) {
  const days = month === "2026-10" ? currentMonthDays : standardMonthDays;

  for (const [index, purchase] of demoPurchases.entries()) {
    const day = String(validDayForMonth(month, days[index])).padStart(2, "0");
    await query(`
      insert into plaid_transactions (
        transaction_id, plaid_item_id, account_id, name, merchant_name, amount,
        iso_currency_code, transaction_date, pending, category, updated_at
      )
      values ($1, $2, $3, $4, $5, $6, 'USD', $7, false, $8::jsonb, now())
      on conflict (transaction_id) do update set
        plaid_item_id = excluded.plaid_item_id,
        account_id = excluded.account_id,
        name = excluded.name,
        merchant_name = excluded.merchant_name,
        amount = excluded.amount,
        transaction_date = excluded.transaction_date,
        pending = false,
        category = excluded.category,
        updated_at = now()
    `, [
      `demo-local-${month}-${String(index + 1).padStart(2, "0")}`,
      target.plaid_item_id,
      target.account_id,
      purchase.name,
      purchase.merchant,
      amountForMonth(purchase, month, index),
      `${month}-${day}`,
      JSON.stringify(purchase.category)
    ]);
  }

  const transactions = await listTransactionsForUserMonth(target.user_id, month);
  const summary = calculateMonthlySpendingSummary(transactions, month, {
    accountIds: [target.account_id]
  });
  await saveMonthlySpendingSummary(target.user_id, summary);

  return summary;
}

try {
  const target = await demoTarget();
  const summaries = {};

  for (const month of seedMonths) {
    const summary = await seedMonth(target, month);
    summaries[month] = {
      totalSpent: summary.totalSpent,
      transactionCount: summary.transactionCount
    };
  }

  console.log(JSON.stringify({
    seededMonths: seedMonths.length,
    seededDemoTransactions: demoPurchases.length * seedMonths.length,
    summaries
  }, null, 2));
} finally {
  await closeDatabase();
}
