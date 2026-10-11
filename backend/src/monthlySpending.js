import { query } from "./database.js";
import { listTransactionsForUserMonth, syncTransactionsForUser } from "./transactions.js";

const budgetCategories = ["food", "shopping", "transport", "entertainment", "other"];
const monthlySummaryColumns = `
  user_id, month, total_spent, categories, transaction_count, calculated_at
`;

export function normalizeMonth(value = currentMonth()) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}$/.test(value)) {
    return null;
  }

  return value;
}

export function currentMonth(date = new Date()) {
  return date.toISOString().slice(0, 7);
}

export function calculateMonthlySpendingSummary(transactions, month, options = {}) {
  const allowedAccountIds = options.accountIds ? new Set(options.accountIds) : null;
  const categoryTotals = new Map(budgetCategories.map((category) => [category, 0]));
  let totalSpent = 0;
  let transactionCount = 0;

  for (const transaction of transactions) {
    if (!isMonthlySpend(transaction, month, allowedAccountIds)) {
      continue;
    }

    const amount = Number(transaction.amount);
    const category = categoryForTransaction(transaction);
    categoryTotals.set(category, roundMoney(categoryTotals.get(category) + amount));
    totalSpent = roundMoney(totalSpent + amount);
    transactionCount += 1;
  }

  return {
    month,
    totalSpent,
    transactionCount,
    categories: budgetCategories.map((category) => ({
      category,
      amount: categoryTotals.get(category) ?? 0
    }))
  };
}

export async function findMonthlySpendingSummary(userId, month) {
  if (!userId || !month) {
    return null;
  }

  const result = await query(`
    select ${monthlySummaryColumns}
    from monthly_spending_summaries
    where user_id = $1 and month = $2
  `, [userId, month]);

  return result.rows[0] ? toMonthlySpendingSummary(result.rows[0]) : null;
}

export async function listMonthlySpendingMonths(userId) {
  if (!userId) {
    return [];
  }

  const result = await query(`
    select month from (
      select month
      from monthly_spending_summaries
      where user_id = $1
        and (transaction_count > 0 or total_spent > 0)

      union

      select to_char(transactions.transaction_date, 'YYYY-MM') as month
      from plaid_transactions transactions
      join plaid_items items using (plaid_item_id)
      where items.user_id = $1
    ) available_months
    order by month desc
  `, [userId]);

  return result.rows.map((row) => row.month).filter(normalizeMonth);
}

export async function refreshMonthlySpendingSummary({ userId, month, plaidClient }) {
  const items = await syncTransactionsForUser({ userId, plaidClient });
  const creditAccountIds = [];

  for (const item of items) {
    const accountsResponse = await plaidClient.accountsGet({
      access_token: item.accessToken
    });
    creditAccountIds.push(...accountsResponse.data.accounts
      .filter((account) => account.type === "credit")
      .map((account) => account.account_id));
  }

  const transactions = await listTransactionsForUserMonth(userId, month);
  const summary = calculateMonthlySpendingSummary(transactions, month, {
    accountIds: creditAccountIds
  });
  return saveMonthlySpendingSummary(userId, summary);
}

export async function saveMonthlySpendingSummary(userId, summary) {
  const result = await query(`
    insert into monthly_spending_summaries (
      user_id, month, total_spent, categories, transaction_count, calculated_at
    )
    values ($1, $2, $3, $4::jsonb, $5, $6)
    on conflict (user_id, month) do update set
      total_spent = excluded.total_spent,
      categories = excluded.categories,
      transaction_count = excluded.transaction_count,
      calculated_at = excluded.calculated_at
    returning ${monthlySummaryColumns}
  `, [
    userId,
    summary.month,
    summary.totalSpent,
    JSON.stringify(summary.categories),
    summary.transactionCount,
    new Date().toISOString()
  ]);

  return toMonthlySpendingSummary(result.rows[0]);
}

function isMonthlySpend(transaction, month, allowedAccountIds) {
  const amount = Number(transaction.amount);
  if (allowedAccountIds && !allowedAccountIds.has(transaction.account_id)) {
    return false;
  }

  return !transaction.pending
    && Number.isFinite(amount)
    && amount > 0
    && typeof transaction.date === "string"
    && transaction.date.startsWith(month);
}

function categoryForTransaction(transaction) {
  const searchableText = [
    transaction.name,
    transaction.merchant_name,
    ...(transaction.category ?? [])
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  if (["food", "drink", "restaurant", "coffee", "cafe"].some((term) => searchableText.includes(term))) {
    return "food";
  }

  if (["shop", "store", "merchandise", "retail"].some((term) => searchableText.includes(term))) {
    return "shopping";
  }

  if (["transport", "taxi", "uber", "lyft", "parking", "gas"].some((term) => searchableText.includes(term))) {
    return "transport";
  }

  if (["entertainment", "recreation", "movie", "music", "ticket"].some((term) => searchableText.includes(term))) {
    return "entertainment";
  }

  return "other";
}

function roundMoney(value) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function toMonthlySpendingSummary(row) {
  return {
    userId: row.user_id,
    month: row.month,
    totalSpent: Number(row.total_spent ?? 0),
    transactionCount: Number(row.transaction_count ?? 0),
    categories: budgetCategories.map((category) => {
      const categoryRow = (row.categories ?? []).find((item) => item.category === category);
      return {
        category,
        amount: Number(categoryRow?.amount ?? 0)
      };
    }),
    calculatedAt: row.calculated_at
  };
}
