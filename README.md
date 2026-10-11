# Personal Finances

Personal Finances is a SwiftUI budgeting app backed by Plaid, a Node.js API, and PostgreSQL. It connects a user's bank accounts, stores synchronized transactions locally, presents monthly spending by category, and exposes daily and monthly home-screen widgets.

## Features

- Simple username-based sign-up and sign-in for local development
- Plaid Link account connection
- Persisted connected credit-card accounts
- Monthly spending overview with an interactive category ring
- Month picker with historical transaction loading
- Transactions ordered by date or grouped by category
- Category-specific transaction details
- Light and dark appearance modes
- Daily spending and monthly overview widgets
- Docker-based local PostgreSQL database
- Encrypted Plaid access-token storage

## Technology

| Layer | Technology |
| --- | --- |
| iOS app | SwiftUI, NavigationStack, custom chart shapes, Plaid LinkKit |
| Widgets | WidgetKit, SwiftUI, App Groups |
| Backend | Node.js, Express, Plaid Node SDK |
| Database | PostgreSQL 16 in Docker |
| Database client | `pg` connection pool |
| Token encryption | AES-256-GCM using Node `crypto` |

The iOS app and widget currently target iOS 18.5.

## System Architecture

```mermaid
flowchart LR
    User[User] --> App[SwiftUI iOS app]
    App --> Link[Plaid Link SDK]
    App --> API[Node and Express API]
    Link --> Plaid[Plaid API]
    API --> Plaid
    API --> DB[(PostgreSQL)]
    App --> Shared[App Group snapshot]
    Shared --> Widget[WidgetKit extension]
```

### Responsibilities

**SwiftUI app**

- Owns navigation, appearance, selected month, and presentation state.
- Opens Plaid Link using a short-lived link token supplied by the backend.
- Preloads and caches transaction data by month for the active session.
- Calculates the displayed category totals from cached credit-card transactions.
- Stores the user's monthly budget in app-local `UserDefaults`.
- Publishes a minimal widget snapshot through the shared App Group.

**Node.js backend**

- Keeps Plaid credentials and access tokens away from the iOS client.
- Exchanges Plaid public tokens for access tokens.
- Encrypts access tokens before database storage and decrypts them only when making Plaid requests.
- Synchronizes transaction additions, modifications, and removals.
- Serves connected accounts, monthly transactions, and cached monthly summaries.

**PostgreSQL**

- Stores users, encrypted Plaid Items, synchronization cursors, transactions, and monthly summaries.
- Acts as the app's durable transaction cache so historical screens normally read local data instead of Plaid.

**Widget extension**

- Reads only the budget, daily spend, monthly spend, and three latest transactions from shared `UserDefaults`.
- Does not call the backend or Plaid directly.
- Provides separate small `Daily Spending` and medium `Monthly Spending` widgets.

## Data Flow

### Connecting an account

1. The app requests a link token from `POST /api/link/token/create`.
2. Plaid Link authenticates the institution and returns a temporary public token.
3. The backend exchanges that public token for an access token and Item ID.
4. The backend encrypts the access token with AES-256-GCM and saves it in `plaid_items`.
5. The backend retrieves account metadata and returns safe account details to the app.
6. The app requests a transaction refresh, then preloads the initial month window.

The access token is never returned to or stored by the iOS app.

### Synchronizing transactions

1. The backend loads each user's saved Plaid Items.
2. It calls `/transactions/sync` using the Item's saved cursor.
3. It follows Plaid pagination until `has_more` is false.
4. Added and modified transactions are upserted into `plaid_transactions`.
5. Removed transaction IDs are deleted.
6. The final cursor is stored on the Plaid Item for the next incremental sync.

### Loading months

- App launch preloads the current month and four preceding months.
- Data is kept in an in-memory `[month: CachedMonthlyData]` cache.
- Selecting an already cached month requires no network request.
- Selecting an uncached month loads that month plus three months before and after it.
- Month requests use `refresh=false`, so they read PostgreSQL without calling Plaid.

### Updating widgets

When current-month data or the budget changes, the app writes a compact snapshot to the App Group `group.mihirsangam.personal-finances`. Both widget timelines are then reloaded. The snapshot is cleared on logout and rejects stale month totals after a calendar-month change.

## Architecture Choices

### Backend-owned Plaid integration

All Plaid API calls that require secrets happen on the backend. This prevents `PLAID_SECRET` and long-lived access tokens from entering the mobile binary, device logs, or app storage.

### Local PostgreSQL instead of direct Supabase reads

The running backend uses PostgreSQL through `DATABASE_URL`. Supabase credentials are required only by the optional one-time import command. This keeps the local development path deterministic and leaves deployment hosting as an independent choice.

### Incremental transaction state

Plaid transaction cursors are stored beside each Item. PostgreSQL holds the reconciled transaction state, while Plaid responses are treated as patches rather than complete monthly datasets.

### Client-side monthly cache

The iOS app keeps recently used months in memory because users commonly move between adjacent months and between the Overview and Transactions tabs. The cache also provides one consistent dataset for totals, category slices, transaction lists, and widget snapshots.

### Small widget snapshot

Widgets receive a deliberately narrow, precomputed payload rather than database credentials or full transaction history. This keeps widget rendering fast and avoids background networking from the extension.

### Development authentication

Authentication is currently username-only. A deterministic user ID is generated from the normalized username, and the local session is stored in `UserDefaults`. This is suitable for the current demo but is not production authentication; a production release should use verified authentication and server-issued sessions.

## Current Optimizations

These optimizations are implemented today:

1. **Cursor-based Plaid synchronization**
   Only transaction changes since the saved cursor are requested after the initial sync.

2. **Maximum Plaid sync page size**
   `/transactions/sync` requests up to 500 changes per page and automatically consumes all pages.

3. **Database-backed transaction cache**
   Normal monthly transaction reads come from PostgreSQL and do not call Plaid when `refresh=false`. Connecting an account, explicit transaction refreshes, and saved-account metadata loading still call Plaid.

4. **In-memory month cache on iOS**
   Previously loaded months are reused across tabs and month changes during the app session.

5. **Predictive month preloading**
   Five recent months are loaded at launch. An uncached historical selection loads a seven-month window centered on that selection.

6. **Indexed database lookups**
   Plaid Items are indexed by user, and transactions are indexed by Item/date and account/date for month-range reads.

7. **Cached monthly summaries**
   `monthly_spending_summaries` stores totals, category breakdowns, counts, and calculation timestamps using one row per user and month.

8. **Parallel account retrieval**
   Account metadata for multiple Plaid Items is fetched concurrently with `Promise.all`.

9. **Connection pooling and parameterized SQL**
   The backend reuses a PostgreSQL pool and passes values separately from SQL text.

10. **Compact widget payloads**
    Only the values required for widget rendering are encoded, and no widget-side API call is needed.

## Optimization Roadmap

The following are useful next steps but are **not implemented yet**:

- Process Plaid `SYNC_UPDATES_AVAILABLE` webhooks and make normal app reads database-only.
- Add a multi-month API endpoint to replace sequential monthly HTTP requests.
- Serialize sync work per Plaid Item to prevent concurrent cursor races.
- Bulk-upsert transaction changes instead of issuing one SQL statement per transaction.
- Persist account metadata and refresh it on a TTL or relevant Plaid webhook.
- Move credit-card, posted-purchase, and category filtering fully into SQL.
- Add `ETag` or revision-based validation for unchanged historical month responses.

## Database Schema

| Table | Purpose |
| --- | --- |
| `users` | Local users and unique usernames |
| `plaid_items` | Item ownership, encrypted access-token fields, and sync cursor |
| `plaid_transactions` | Reconciled Plaid transaction state |
| `monthly_spending_summaries` | Cached monthly totals and category summaries |

Migrations live in [`backend/migrations`](backend/migrations). They are applied in filename order and are written to be safely rerunnable.

## Local Setup

### Requirements

- macOS with Xcode capable of building iOS 18.5
- Node.js and npm
- Docker Desktop
- Plaid sandbox credentials

### 1. Configure the backend

```sh
cd backend
npm install
cp .env.example .env
openssl rand -base64 32
```

Add the generated key and your Plaid sandbox credentials to `backend/.env`:

```dotenv
PLAID_CLIENT_ID=...
PLAID_SECRET=...
PLAID_ENV=sandbox
PLAID_ACCESS_TOKEN_ENCRYPTION_KEY=...
DATABASE_URL=postgresql://personal_finances:personal_finances@localhost:5432/personal_finances
```

Never place Plaid secrets, the encryption key, or a Supabase service-role key in the iOS app.

### 2. Start and migrate PostgreSQL

```sh
cd backend
npm run db:up
npm run db:migrate
```

Optionally seed demo transactions:

```sh
npm run db:seed:demo
```

### 3. Start the backend

```sh
cd backend
npm run dev
```

The local API listens on `http://127.0.0.1:8000`. The current iOS clients use this address directly, so the backend must be running on the same Mac as the Simulator.

### 4. Run the iOS app

Open `personal-finances.xcodeproj`, select the `personal-finances` scheme and an iPhone Simulator, then run the app. The App Group capability must remain enabled for both the app and `BudgetWidget` targets.

## Useful Commands

Run these from `backend`:

```sh
npm run check:env           # Validate backend configuration
npm run db:up               # Start PostgreSQL in Docker
npm run db:migrate          # Apply SQL migration files
npm run db:seed:demo        # Insert repeatable demo transactions
npm run dev                 # Start Express with file watching
npm test                    # Run backend tests
npm run smoke:user          # Exercise local sign-up/sign-in
npm run smoke:link          # Request a Plaid link token
npm run smoke:purchases     # Exercise purchase-history behavior
npm run db:down             # Stop the Docker Compose services
```

Inspect the local database:

```sh
docker compose exec db psql -U personal_finances -d personal_finances
```

Inside `psql`:

```sql
\dt
select * from users;
select id, user_id, plaid_item_id, cursor, created_at, updated_at from plaid_items;
select * from plaid_transactions order by transaction_date desc;
select * from monthly_spending_summaries order by month desc;
```

## API Surface

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Backend health check |
| `POST` | `/api/users/sign-up` | Create a local demo user |
| `POST` | `/api/users/sign-in` | Find a local demo user |
| `POST` | `/api/link/token/create` | Create a Plaid Link token |
| `POST` | `/api/item/public_token/exchange` | Exchange and persist a linked Item |
| `GET` | `/api/users/:userId/credit-cards` | Load saved credit-card accounts |
| `GET` | `/api/users/:userId/monthly-summary` | Read or refresh a monthly summary |
| `GET` | `/api/users/:userId/monthly-summary-months` | List months containing data |
| `GET` | `/api/users/:userId/monthly-transactions` | Read a month's local transactions |
| `POST` | `/api/transactions/sync` | Synchronize an Item using its cursor |
| `POST` | `/api/purchase-history` | Return purchases grouped by vendor |

See [`backend/README.md`](backend/README.md) for backend-specific notes and request examples.

## Security Notes

- Plaid access tokens are encrypted at rest with AES-256-GCM using a unique random IV and authentication tag.
- The encryption key is supplied through the backend environment and is not stored in PostgreSQL.
- SQL queries use parameterized values.
- The iOS app receives account and transaction data but never receives saved Plaid access tokens.
- Username-only authentication, local `UserDefaults` sessions, and the development HTTP endpoint must be replaced before production deployment.
- Production deployments should also add authenticated API authorization, TLS, secret management, rate limiting, webhook verification, and a documented encryption-key rotation process.
