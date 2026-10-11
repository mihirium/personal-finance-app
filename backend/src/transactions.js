import { databasePool, query } from "./database.js";
import { syncAllTransactions } from "./plaidClient.js";
import { listPlaidItemsForUser, updatePlaidItemCursor } from "./plaidItems.js";

const transactionColumns = `
  transaction_id, account_id, name, merchant_name, amount,
  iso_currency_code, unofficial_currency_code, transaction_date::text as transaction_date,
  pending, category
`;

export async function syncTransactionsForUser({ userId, plaidClient }) {
  const items = await listPlaidItemsForUser(userId);

  for (const item of items) {
    const hasStoredTransactions = await hasTransactionsForItem(item.plaidItemId);
    const cursor = hasStoredTransactions ? item.cursor : null;
    const syncResult = await syncAllTransactions(plaidClient, item.accessToken, cursor);
    await applyTransactionSync(item.plaidItemId, syncResult);
    await updatePlaidItemCursor(item.plaidItemId, syncResult.nextCursor);
  }

  return items;
}

export async function listTransactionsForUserMonth(userId, month) {
  const result = await query(`
    select ${transactionColumns}
    from plaid_transactions transactions
    join plaid_items items using (plaid_item_id)
    where items.user_id = $1
      and transactions.transaction_date >= $2::date
      and transactions.transaction_date < ($2::date + interval '1 month')
    order by transactions.transaction_date desc, transactions.transaction_id
  `, [userId, `${month}-01`]);

  return result.rows.map(toPlaidTransaction);
}

async function hasTransactionsForItem(plaidItemId) {
  const result = await query(
    "select exists(select 1 from plaid_transactions where plaid_item_id = $1) as exists",
    [plaidItemId]
  );
  return result.rows[0].exists;
}

async function applyTransactionSync(plaidItemId, syncResult) {
  const client = await databasePool().connect();

  try {
    await client.query("begin");

    for (const transaction of [...syncResult.added, ...syncResult.modified]) {
      await client.query(`
        insert into plaid_transactions (
          transaction_id, plaid_item_id, account_id, name, merchant_name, amount,
          iso_currency_code, unofficial_currency_code, transaction_date, pending,
          category, updated_at
        )
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, now())
        on conflict (transaction_id) do update set
          plaid_item_id = excluded.plaid_item_id,
          account_id = excluded.account_id,
          name = excluded.name,
          merchant_name = excluded.merchant_name,
          amount = excluded.amount,
          iso_currency_code = excluded.iso_currency_code,
          unofficial_currency_code = excluded.unofficial_currency_code,
          transaction_date = excluded.transaction_date,
          pending = excluded.pending,
          category = excluded.category,
          updated_at = now()
      `, [
        transaction.transaction_id,
        plaidItemId,
        transaction.account_id,
        transaction.name,
        transaction.merchant_name,
        transaction.amount,
        transaction.iso_currency_code,
        transaction.unofficial_currency_code,
        transaction.date,
        transaction.pending,
        JSON.stringify(transaction.category ?? [])
      ]);
    }

    for (const removed of syncResult.removed) {
      await client.query(
        "delete from plaid_transactions where transaction_id = $1",
        [removed.transaction_id]
      );
    }

    await client.query("commit");
  } catch (error) {
    await client.query("rollback");
    throw error;
  } finally {
    client.release();
  }
}

function toPlaidTransaction(row) {
  return {
    transaction_id: row.transaction_id,
    account_id: row.account_id,
    name: row.name,
    merchant_name: row.merchant_name,
    amount: Number(row.amount),
    iso_currency_code: row.iso_currency_code,
    unofficial_currency_code: row.unofficial_currency_code,
    date: dateString(row.transaction_date),
    pending: row.pending,
    category: row.category ?? []
  };
}

function dateString(value) {
  if (typeof value === "string") {
    return value.slice(0, 10);
  }

  return value.toISOString().slice(0, 10);
}
