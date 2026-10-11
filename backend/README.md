# Personal Finances Backend

Node/Express backend for talking to Plaid without putting `PLAID_SECRET` in the iOS app.

## Setup

```sh
cd backend
npm install
cp .env.example .env
```

Fill in `PLAID_CLIENT_ID`, `PLAID_SECRET`, and `PLAID_ENV` in `.env`.
The backend stores users, encrypted Plaid items, Plaid transactions, and monthly summaries in a local PostgreSQL database.

Start PostgreSQL and create the schema:

```sh
npm run db:up
npm run db:migrate
```

The default local connection is:

```sh
DATABASE_URL=postgresql://personal_finances:personal_finances@localhost:5432/personal_finances
```

Generate the Plaid access-token encryption key with:

```sh
openssl rand -base64 32
```

Then set it in `.env`:

```sh
PLAID_ACCESS_TOKEN_ENCRYPTION_KEY=...
```

The schema lives in `migrations/001_initial.sql`. Plaid access tokens remain encrypted with AES-256-GCM in PostgreSQL.

## Import Existing Supabase Data

Keep `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in `.env` for the one-time import, then run:

```sh
npm run db:import:supabase
```

The import copies users, encrypted Plaid items, and monthly summaries in one transaction. It is safe to rerun and never decrypts or logs Plaid access tokens. Supabase credentials are not used by the running backend after migration.

Seed repeatable monthly demo transactions from October 2025 through October 2026 into the connected credit account:

```sh
npm run db:seed:demo
```

## Run

```sh
npm run dev
```

The server listens on `http://localhost:8000` by default.

## Smoke Tests

With the server running in another terminal:

```sh
npm run check:env
npm run smoke:user
npm run smoke:link
npm run smoke:purchases
```

## Endpoints

- `GET /health`
- `POST /api/link/token/create` with optional `{ "userId": "local-user" }`
- `POST /api/users/sign-up` with `{ "username": "mihir" }`
- `POST /api/users/sign-in` with `{ "username": "mihir" }`
- `POST /api/item/public_token/exchange` with `{ "publicToken": "...", "userId": "user_..." }`
- `GET /api/users/:userId/credit-cards`
- `GET /api/users/:userId/monthly-summary?month=2026-09&refresh=false`
- `GET /api/users/:userId/monthly-summary-months`
- `GET /api/users/:userId/monthly-transactions?month=2026-09&refresh=true`
- `POST /api/transactions/sync` with `{ "itemId": "..." }` or `{ "accessToken": "..." }`
- `POST /api/purchase-history` with `{ "itemId": "..." }` or `{ "accessToken": "..." }`

`/api/purchase-history` returns transactions grouped by vendor, sorted by total spend.
`/api/users/:userId/monthly-summary` returns cached monthly totals by budget category. Use `refresh=true` after connecting an account or when you want the backend to pull Plaid again and update PostgreSQL.

Plaid access tokens are encrypted in the backend before they are saved to PostgreSQL. The iOS app should never receive a Plaid access token.

Synced transactions are stored in local PostgreSQL and updated from Plaid using each Item's transaction cursor.
