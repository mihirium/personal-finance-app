import "dotenv/config";

import { createPlaidClient } from "../src/plaidClient.js";

const port = Number(process.env.PORT ?? 8000);

try {
  const client = createPlaidClient();
  const sandbox = await client.sandboxPublicTokenCreate({
    institution_id: "ins_109508",
    initial_products: ["transactions"],
    options: {
      override_username: "user_transactions_dynamic",
      override_password: "test"
    }
  });

  const exchange = await client.itemPublicTokenExchange({
    public_token: sandbox.data.public_token
  });
  const accessToken = exchange.data.access_token;
  const today = new Date().toISOString().slice(0, 10);

  await client.sandboxTransactionsCreate({
    access_token: accessToken,
    transactions: [
      {
        amount: 12.34,
        date_transacted: today,
        date_posted: today,
        description: "Codex Coffee",
        iso_currency_code: "USD"
      },
      {
        amount: 45.67,
        date_transacted: today,
        date_posted: today,
        description: "Codex Grocery",
        iso_currency_code: "USD"
      }
    ]
  });

  const response = await fetch(`http://127.0.0.1:${port}/api/purchase-history`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      accessToken
    })
  });
  const body = await response.json();

  if (!response.ok) {
    throw new Error(body.error ?? "Purchase history request failed.");
  }

  console.log(JSON.stringify({
    ok: true,
    vendorCount: body.vendors.length,
    transactionCount: body.transactionCount,
    topVendors: body.vendors.slice(0, 5).map((vendor) => ({
      vendor: vendor.vendor,
      totalSpend: vendor.totalSpend,
      transactionCount: vendor.transactionCount
    }))
  }, null, 2));
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    error: error.message
  }, null, 2));
  process.exit(1);
}
