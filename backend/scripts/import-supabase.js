import "dotenv/config";

import { createClient } from "@supabase/supabase-js";

import { closeDatabase, databasePool } from "../src/database.js";
import { migrateLocalDatabase } from "./migrate-local-db.js";

const pageSize = 500;

async function fetchAll(supabase, table) {
  const rows = [];

  for (let offset = 0; ; offset += pageSize) {
    const { data, error } = await supabase
      .from(table)
      .select("*")
      .range(offset, offset + pageSize - 1);

    if (error) {
      throw error;
    }

    rows.push(...data);
    if (data.length < pageSize) {
      return rows;
    }
  }
}

async function importUsers(client, rows) {
  for (const row of rows) {
    await client.query(`
      insert into users (user_id, username, created_at)
      values ($1, $2, coalesce($3, now()))
      on conflict (user_id) do update set username = excluded.username
    `, [row.user_id, row.username, row.created_at ?? null]);
  }
}

async function importPlaidItems(client, rows) {
  for (const row of rows) {
    if (!row.encrypted_access_token || !row.access_token_iv || !row.access_token_auth_tag) {
      throw new Error(`Plaid item ${row.plaid_item_id} does not contain a fully encrypted access token.`);
    }

    await client.query(`
      insert into plaid_items (
        id, user_id, plaid_item_id, encrypted_access_token, access_token_iv,
        access_token_auth_tag, cursor, created_at, updated_at
      )
      values ($1, $2, $3, $4, $5, $6, $7, coalesce($8, now()), coalesce($9, now()))
      on conflict (plaid_item_id) do update set
        user_id = excluded.user_id,
        encrypted_access_token = excluded.encrypted_access_token,
        access_token_iv = excluded.access_token_iv,
        access_token_auth_tag = excluded.access_token_auth_tag,
        cursor = excluded.cursor,
        updated_at = excluded.updated_at
    `, [
      row.id,
      row.user_id,
      row.plaid_item_id,
      row.encrypted_access_token,
      row.access_token_iv,
      row.access_token_auth_tag,
      row.cursor,
      row.created_at ?? null,
      row.updated_at ?? null
    ]);
  }
}

async function importMonthlySummaries(client, rows) {
  for (const row of rows) {
    await client.query(`
      insert into monthly_spending_summaries (
        id, user_id, month, total_spent, categories, transaction_count, calculated_at
      )
      values ($1, $2, $3, $4, $5::jsonb, $6, coalesce($7, now()))
      on conflict (user_id, month) do update set
        total_spent = excluded.total_spent,
        categories = excluded.categories,
        transaction_count = excluded.transaction_count,
        calculated_at = excluded.calculated_at
    `, [
      row.id,
      row.user_id,
      row.month,
      row.total_spent ?? 0,
      JSON.stringify(row.categories ?? []),
      row.transaction_count ?? 0,
      row.calculated_at ?? null
    ]);
  }
}

async function main() {
  const supabaseURL = process.env.SUPABASE_URL;
  const supabaseKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseURL || !supabaseKey) {
    throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required for the import.");
  }

  await migrateLocalDatabase();

  const supabase = createClient(supabaseURL, supabaseKey, {
    auth: { persistSession: false, autoRefreshToken: false }
  });
  const [users, plaidItems, monthlySummaries] = await Promise.all([
    fetchAll(supabase, "users"),
    fetchAll(supabase, "plaid_items"),
    fetchAll(supabase, "monthly_spending_summaries")
  ]);

  const client = await databasePool().connect();
  try {
    await client.query("begin");
    await importUsers(client, users);
    await importPlaidItems(client, plaidItems);
    await importMonthlySummaries(client, monthlySummaries);
    await client.query("commit");
  } catch (error) {
    await client.query("rollback");
    throw error;
  } finally {
    client.release();
  }

  console.log(`Imported ${users.length} users, ${plaidItems.length} Plaid items, and ${monthlySummaries.length} monthly summaries.`);
}

try {
  await main();
} finally {
  await closeDatabase();
}
