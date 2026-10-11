import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";

import { decryptAccessToken, encryptAccessToken } from "../src/accessTokenCrypto.js";
import { calculateMonthlySpendingSummary } from "../src/monthlySpending.js";
import { groupPurchasesByVendor, mergeTransactions } from "../src/purchaseHistory.js";
import { createUserId, normalizeUsername, validateUsername } from "../src/users.js";

test("groups posted purchases by vendor", () => {
  const history = groupPurchasesByVendor([
    transaction({ id: "1", merchantName: "Coffee Shop", amount: 4.75, date: "2026-08-29" }),
    transaction({ id: "2", merchantName: "Coffee Shop", amount: 6.25, date: "2026-08-28" }),
    transaction({ id: "3", merchantName: "Pending Cafe", amount: 3.5, date: "2026-08-29", pending: true }),
    transaction({ id: "4", name: "Payroll", merchantName: null, amount: -2000, date: "2026-08-27" })
  ]);

  assert.equal(history.length, 1);
  assert.equal(history[0].vendor, "Coffee Shop");
  assert.equal(history[0].transactionCount, 2);
  assert.equal(history[0].totalSpend, 11);
});

test("merges Plaid sync deltas into existing transactions", () => {
  const merged = mergeTransactions(
    [
      transaction({ id: "old", merchantName: "Old Vendor", amount: 10, date: "2026-08-20" }),
      transaction({ id: "edited", merchantName: "Before", amount: 3, date: "2026-08-21" })
    ],
    {
      added: [
        transaction({ id: "new", merchantName: "New Vendor", amount: 15, date: "2026-08-29" })
      ],
      modified: [
        transaction({ id: "edited", merchantName: "After", amount: 5, date: "2026-08-22" })
      ],
      removed: [
        { transaction_id: "old" }
      ]
    }
  );

  assert.deepEqual(merged.map((item) => item.transaction_id), ["new", "edited"]);
  assert.equal(merged.find((item) => item.transaction_id === "edited").merchant_name, "After");
  assert.equal(merged.find((item) => item.transaction_id === "edited").amount, 5);
});

test("creates stable user ids from normalized usernames", () => {
  assert.equal(normalizeUsername("  Mihir.S  "), "mihir.s");
  assert.equal(createUserId("Mihir.S"), createUserId("mihir.s"));
  assert.match(createUserId("mihir.s"), /^user_[a-f0-9]{16}$/);
});

test("validates usernames before hitting the database", () => {
  assert.equal(validateUsername("mi").ok, false);
  assert.equal(validateUsername("bad name").ok, false);
  assert.deepEqual(validateUsername("mihir_01"), {
    ok: true,
    username: "mihir_01"
  });
});

test("encrypts and decrypts Plaid access tokens", () => {
  const previousKey = process.env.PLAID_ACCESS_TOKEN_ENCRYPTION_KEY;
  process.env.PLAID_ACCESS_TOKEN_ENCRYPTION_KEY = crypto.randomBytes(32).toString("base64");

  try {
    const accessToken = "access-sandbox-test-token";
    const encrypted = encryptAccessToken(accessToken);

    assert.notEqual(encrypted.encryptedAccessToken, accessToken);
    assert.ok(encrypted.accessTokenIV);
    assert.ok(encrypted.accessTokenAuthTag);
    assert.equal(decryptAccessToken(encrypted), accessToken);
  } finally {
    restoreEnv("PLAID_ACCESS_TOKEN_ENCRYPTION_KEY", previousKey);
  }
});

test("rejects invalid Plaid access token encryption keys", () => {
  const previousKey = process.env.PLAID_ACCESS_TOKEN_ENCRYPTION_KEY;
  process.env.PLAID_ACCESS_TOKEN_ENCRYPTION_KEY = Buffer.from("too-short").toString("base64");

  try {
    assert.throws(
      () => encryptAccessToken("access-sandbox-test-token"),
      /base64-encoded 32-byte key/
    );
  } finally {
    restoreEnv("PLAID_ACCESS_TOKEN_ENCRYPTION_KEY", previousKey);
  }
});

test("calculates monthly spending summaries by budget category", () => {
  const summary = calculateMonthlySpendingSummary([
    transaction({ id: "food", name: "Local Cafe", amount: 12.31, date: "2026-09-01" }),
    transaction({ id: "shop", name: "Retail Store", amount: 20, date: "2026-09-02" }),
    transaction({ id: "old", name: "Restaurant", amount: 15, date: "2026-08-31" }),
    transaction({ id: "pending", name: "Movie Tickets", amount: 30, date: "2026-09-03", pending: true }),
    transaction({ id: "refund", name: "Refund", amount: -5, date: "2026-09-04" })
  ], "2026-09");

  assert.equal(summary.totalSpent, 32.31);
  assert.equal(summary.transactionCount, 2);
  assert.deepEqual(summary.categories, [
    { category: "food", amount: 12.31 },
    { category: "shopping", amount: 20 },
    { category: "transport", amount: 0 },
    { category: "entertainment", amount: 0 },
    { category: "other", amount: 0 }
  ]);
});

test("can limit monthly spending summaries to selected account ids", () => {
  const summary = calculateMonthlySpendingSummary([
    transaction({ id: "credit", amount: 44, date: "2026-09-01", accountID: "credit-account" }),
    transaction({ id: "checking", amount: 22, date: "2026-09-02", accountID: "checking-account" })
  ], "2026-09", {
    accountIds: ["credit-account"]
  });

  assert.equal(summary.totalSpent, 44);
  assert.equal(summary.transactionCount, 1);
});

function transaction({
  id,
  accountID = "account-1",
  name = "Transaction",
  merchantName = "Vendor",
  amount,
  date,
  pending = false
}) {
  return {
    transaction_id: id,
    account_id: accountID,
    name,
    merchant_name: merchantName,
    amount,
    iso_currency_code: "USD",
    date,
    pending
  };
}

function restoreEnv(name, value) {
  if (value === undefined) {
    delete process.env[name];
    return;
  }

  process.env[name] = value;
}
