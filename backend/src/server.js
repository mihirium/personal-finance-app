import "dotenv/config";

import cors from "cors";
import express from "express";

import { groupPurchasesByVendor, mergeTransactions } from "./purchaseHistory.js";
import {
  findMonthlySpendingSummary,
  listMonthlySpendingMonths,
  normalizeMonth,
  refreshMonthlySpendingSummary
} from "./monthlySpending.js";
import { createPlaidClient, syncAllTransactions, toSafePlaidError } from "./plaidClient.js";
import {
  findPlaidItemByPlaidItemId,
  listPlaidItemsForUser,
  savePlaidItem,
  updatePlaidItemCursor
} from "./plaidItems.js";
import { signInUser, signUpUser } from "./users.js";
import { listTransactionsForUserMonth, syncTransactionsForUser } from "./transactions.js";

const app = express();
const port = Number(process.env.PORT ?? 8000);
const itemStore = new Map();

app.use(express.json({ limit: "1mb" }));
app.use(cors({
  origin: parseAllowedOrigins(process.env.APP_ALLOWED_ORIGINS),
  credentials: true
}));

app.get("/health", (_request, response) => {
  response.json({ ok: true });
});

app.post("/api/users/sign-up", async (request, response) => {
  try {
    const result = await signUpUser(request.body?.username);

    if (!result.ok) {
      response.status(result.status).json({ error: result.error });
      return;
    }

    response.status(201).json({ user: result.user });
  } catch (error) {
    response.status(500).json({ error: error.message ?? "Unable to create user." });
  }
});

app.post("/api/users/sign-in", async (request, response) => {
  try {
    const result = await signInUser(request.body?.username);

    if (!result.ok) {
      response.status(result.status).json({ error: result.error });
      return;
    }

    response.json({ user: result.user });
  } catch (error) {
    response.status(500).json({ error: error.message ?? "Unable to sign in." });
  }
});

app.post("/api/link/token/create", async (request, response) => {
  try {
    const plaidClient = createPlaidClient();
    const userId = request.body?.userId ?? "local-user";

    const tokenResponse = await plaidClient.linkTokenCreate({
      user: {
        client_user_id: String(userId)
      },
      client_name: process.env.PLAID_CLIENT_NAME ?? "Personal Finances",
      products: ["transactions"],
      country_codes: ["US"],
      language: "en"
    });

    response.json({
      linkToken: tokenResponse.data.link_token,
      expiration: tokenResponse.data.expiration,
      requestId: tokenResponse.data.request_id
    });
  } catch (error) {
    sendError(response, error);
  }
});

app.post("/api/item/public_token/exchange", async (request, response) => {
  try {
    const publicToken = request.body?.publicToken;
    const userId = request.body?.userId;
    if (!publicToken) {
      response.status(400).json({ error: "publicToken is required." });
      return;
    }

    if (!userId) {
      response.status(400).json({ error: "userId is required so the Plaid item can be saved." });
      return;
    }

    const plaidClient = createPlaidClient();
    const exchangeResponse = await plaidClient.itemPublicTokenExchange({
      public_token: publicToken
    });

    const { access_token: accessToken, item_id: itemId, request_id: requestId } = exchangeResponse.data;
    const accountsResponse = await plaidClient.accountsGet({
      access_token: accessToken
    });
    const accounts = accountsResponse.data.accounts.map(toAccountSummary);

    await savePlaidItem({
      userId: String(userId),
      plaidItemId: itemId,
      accessToken
    });

    itemStore.set(itemId, {
      itemId,
      userId: String(userId),
      accessToken,
      accounts,
      cursor: null,
      transactions: []
    });

    response.json({
      itemId,
      requestId,
      persisted: true,
      accounts,
      creditCards: accounts.filter((account) => account.type === "credit")
    });
  } catch (error) {
    sendError(response, error);
  }
});

app.get("/api/users/:userId/credit-cards", async (request, response) => {
  try {
    const plaidClient = createPlaidClient();
    const items = await listPlaidItemsForUser(request.params.userId);
    const accountsByItem = await Promise.all(items.map(async (item) => {
      const accountsResponse = await plaidClient.accountsGet({
        access_token: item.accessToken
      });
      const accounts = accountsResponse.data.accounts.map(toAccountSummary);

      itemStore.set(item.plaidItemId, {
        itemId: item.plaidItemId,
        userId: item.userId,
        accessToken: item.accessToken,
        accounts,
        cursor: item.cursor,
        transactions: []
      });

      return {
        itemId: item.plaidItemId,
        accounts,
        creditCards: accounts.filter((account) => account.type === "credit")
      };
    }));

    response.json({
      items: accountsByItem,
      creditCards: accountsByItem.flatMap((item) => (
        item.creditCards.map((card) => ({
          ...card,
          itemId: item.itemId
        }))
      ))
    });
  } catch (error) {
    sendError(response, error);
  }
});

app.get("/api/users/:userId/monthly-summary", async (request, response) => {
  try {
    const month = normalizeMonth(request.query.month ?? undefined);
    if (!month) {
      response.status(400).json({ error: "month must use YYYY-MM format." });
      return;
    }

    const shouldRefresh = request.query.refresh === "true";
    const cachedSummary = shouldRefresh
      ? null
      : await findMonthlySpendingSummary(request.params.userId, month);
    const summary = cachedSummary ?? await refreshMonthlySpendingSummary({
      userId: request.params.userId,
      month,
      plaidClient: createPlaidClient()
    });

    response.json(summary);
  } catch (error) {
    sendError(response, error);
  }
});

app.get("/api/users/:userId/monthly-summary-months", async (request, response) => {
  try {
    const months = await listMonthlySpendingMonths(request.params.userId);
    response.json({ months });
  } catch (error) {
    sendError(response, error);
  }
});

app.get("/api/users/:userId/monthly-transactions", async (request, response) => {
  try {
    const month = normalizeMonth(request.query.month ?? undefined);
    if (!month) {
      response.status(400).json({ error: "month must use YYYY-MM format." });
      return;
    }

    if (request.query.refresh === "true") {
      await syncTransactionsForUser({
        userId: request.params.userId,
        plaidClient: createPlaidClient()
      });
    }

    const transactions = await listTransactionsForUserMonth(request.params.userId, month);
    const result = {
      month,
      transactionCount: transactions.length,
      transactions
    };

    if (process.env.NODE_ENV !== "production") {
      console.log(`[monthly-transactions] ${month}`);
    }

    response.json(result);
  } catch (error) {
    sendError(response, error);
  }
});

app.post("/api/transactions/sync", async (request, response) => {
  try {
    const plaidClient = createPlaidClient();
    const item = await itemFromRequest(request);
    const cursor = cursorFromRequest(request, item);
    const accessToken = accessTokenFromRequest(request, item);

    if (!accessToken) {
      response.status(400).json({ error: "itemId or accessToken is required." });
      return;
    }

    const syncResult = await syncAllTransactions(plaidClient, accessToken, cursor);

    if (item) {
      item.cursor = syncResult.nextCursor;
      await updatePlaidItemCursor(item.itemId, syncResult.nextCursor);
    }

    response.json(syncResult);
  } catch (error) {
    sendError(response, error);
  }
});

app.post("/api/purchase-history", async (request, response) => {
  try {
    const plaidClient = createPlaidClient();
    const item = await itemFromRequest(request);
    const accessToken = accessTokenFromRequest(request, item);

    if (!accessToken) {
      response.status(400).json({ error: "itemId or accessToken is required." });
      return;
    }

    const cursor = cursorFromRequest(request, item);
    const existingTransactions = cursor === null
      ? []
      : item?.transactions ?? request.body?.existingTransactions ?? [];
    const syncResult = await syncAllTransactions(plaidClient, accessToken, cursor);
    const transactions = mergeTransactions(existingTransactions, syncResult);
    const vendors = groupPurchasesByVendor(transactions);

    if (item) {
      item.cursor = syncResult.nextCursor;
      item.transactions = transactions;
      await updatePlaidItemCursor(item.itemId, syncResult.nextCursor);
    }

    response.json({
      cursor: syncResult.nextCursor,
      vendors,
      transactionCount: transactions.length,
      transactions
    });
  } catch (error) {
    sendError(response, error);
  }
});

app.listen(port, () => {
  console.log(`Personal finances backend listening on http://localhost:${port}`);
});

async function itemFromRequest(request) {
  const itemId = request.body?.itemId;
  if (!itemId) {
    return null;
  }

  const inMemoryItem = itemStore.get(itemId);
  if (inMemoryItem) {
    return inMemoryItem;
  }

  const storedItem = await findPlaidItemByPlaidItemId(itemId);
  if (!storedItem) {
    return null;
  }

  const item = {
    itemId: storedItem.plaidItemId,
    userId: storedItem.userId,
    accessToken: storedItem.accessToken,
    cursor: storedItem.cursor,
    transactions: []
  };
  itemStore.set(itemId, item);
  return item;
}

function accessTokenFromRequest(request, item) {
  return item?.accessToken ?? request.body?.accessToken ?? process.env.PLAID_ACCESS_TOKEN;
}

function cursorFromRequest(request, item) {
  if (Object.hasOwn(request.body ?? {}, "cursor")) {
    return request.body.cursor;
  }

  return item?.cursor ?? null;
}

function parseAllowedOrigins(value) {
  if (!value) {
    return false;
  }

  return value.split(",").map((origin) => origin.trim()).filter(Boolean);
}

function toAccountSummary(account) {
  return {
    id: account.account_id,
    name: account.name,
    officialName: account.official_name,
    mask: account.mask,
    type: account.type,
    subtype: account.subtype,
    currentBalance: account.balances.current,
    availableBalance: account.balances.available,
    limit: account.balances.limit,
    isoCurrencyCode: account.balances.iso_currency_code,
    unofficialCurrencyCode: account.balances.unofficial_currency_code
  };
}

function sendError(response, error) {
  const safeError = toSafePlaidError(error);
  response.status(safeError.status).json(safeError.body);
}
