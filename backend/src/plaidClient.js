import { Configuration, PlaidApi, PlaidEnvironments } from "plaid";

const environmentURLs = {
  sandbox: PlaidEnvironments.sandbox,
  development: "https://development.plaid.com",
  production: PlaidEnvironments.production
};

export function createPlaidClient() {
  const clientID = process.env.PLAID_CLIENT_ID;
  const secret = process.env.PLAID_SECRET;
  const environment = process.env.PLAID_ENV ?? "sandbox";
  const basePath = environmentURLs[environment];

  if (!clientID || !secret) {
    throw new Error("PLAID_CLIENT_ID and PLAID_SECRET must be set.");
  }

  if (!basePath) {
    throw new Error(`Unsupported PLAID_ENV "${environment}". Use sandbox, development, or production.`);
  }

  const configuration = new Configuration({
    basePath,
    baseOptions: {
      headers: {
        "PLAID-CLIENT-ID": clientID,
        "PLAID-SECRET": secret,
        "Plaid-Version": "2020-09-14"
      }
    }
  });

  return new PlaidApi(configuration);
}

export async function syncAllTransactions(plaidClient, accessToken, cursor = null) {
  const added = [];
  const modified = [];
  const removed = [];
  let nextCursor = cursor;
  let hasMore = true;

  while (hasMore) {
    const response = await plaidClient.transactionsSync({
      access_token: accessToken,
      cursor: nextCursor,
      count: 500
    });

    added.push(...response.data.added);
    modified.push(...response.data.modified);
    removed.push(...response.data.removed);
    nextCursor = response.data.next_cursor;
    hasMore = response.data.has_more;
  }

  return {
    added,
    modified,
    removed,
    nextCursor
  };
}

export function toSafePlaidError(error) {
  const plaidError = error?.response?.data;
  if (plaidError) {
    return {
      status: error.response.status ?? 502,
      body: {
        error: plaidError.error_message ?? "Plaid request failed.",
        errorCode: plaidError.error_code,
        errorType: plaidError.error_type,
        requestId: plaidError.request_id
      }
    };
  }

  return {
    status: 500,
    body: {
      error: error?.message ?? "Unexpected server error."
    }
  };
}
