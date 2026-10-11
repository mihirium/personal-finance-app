import { decryptAccessToken, encryptAccessToken } from "./accessTokenCrypto.js";
import { query } from "./database.js";

const plaidItemColumns = `
  id, user_id, plaid_item_id, encrypted_access_token, access_token_iv,
  access_token_auth_tag, cursor, created_at, updated_at
`;

export async function savePlaidItem({ userId, plaidItemId, accessToken, cursor = null }) {
  if (!userId) {
    throw new Error("userId is required to save a Plaid item.");
  }

  const encryptedToken = encryptAccessToken(accessToken);
  const now = new Date().toISOString();
  const result = await query(`
    insert into plaid_items (
      user_id, plaid_item_id, encrypted_access_token, access_token_iv,
      access_token_auth_tag, cursor, updated_at
    )
    values ($1, $2, $3, $4, $5, $6, $7)
    on conflict (plaid_item_id) do update set
      user_id = excluded.user_id,
      encrypted_access_token = excluded.encrypted_access_token,
      access_token_iv = excluded.access_token_iv,
      access_token_auth_tag = excluded.access_token_auth_tag,
      cursor = excluded.cursor,
      updated_at = excluded.updated_at
    returning ${plaidItemColumns}
  `, [
    userId,
    plaidItemId,
    encryptedToken.encryptedAccessToken,
    encryptedToken.accessTokenIV,
    encryptedToken.accessTokenAuthTag,
    cursor,
    now
  ]);

  return toPlaidItem(result.rows[0]);
}

export async function findPlaidItemByPlaidItemId(plaidItemId) {
  if (!plaidItemId) {
    return null;
  }

  const result = await query(
    `select ${plaidItemColumns} from plaid_items where plaid_item_id = $1`,
    [plaidItemId]
  );

  return result.rows[0] ? toPlaidItem(result.rows[0]) : null;
}

export async function listPlaidItemsForUser(userId) {
  if (!userId) {
    return [];
  }

  const result = await query(
    `select ${plaidItemColumns} from plaid_items where user_id = $1 order by created_at asc`,
    [userId]
  );

  return result.rows.map(toPlaidItem);
}

export async function updatePlaidItemCursor(plaidItemId, cursor) {
  if (!plaidItemId) {
    return;
  }

  await query(`
    update plaid_items
    set cursor = $1, updated_at = $2
    where plaid_item_id = $3
  `, [cursor, new Date().toISOString(), plaidItemId]);
}

function toPlaidItem(row) {
  return {
    id: row.id,
    userId: row.user_id,
    plaidItemId: row.plaid_item_id,
    cursor: row.cursor,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    accessToken: decryptAccessToken({
      encryptedAccessToken: row.encrypted_access_token,
      accessTokenIV: row.access_token_iv,
      accessTokenAuthTag: row.access_token_auth_tag
    })
  };
}
