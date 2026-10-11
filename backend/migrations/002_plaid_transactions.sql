create table if not exists plaid_transactions (
  transaction_id text primary key,
  plaid_item_id text not null references plaid_items(plaid_item_id) on delete cascade,
  account_id text not null,
  name text not null,
  merchant_name text,
  amount numeric(14, 2) not null,
  iso_currency_code text,
  unofficial_currency_code text,
  transaction_date date not null,
  pending boolean not null default false,
  category jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists plaid_transactions_item_date_idx
  on plaid_transactions(plaid_item_id, transaction_date desc);

create index if not exists plaid_transactions_account_date_idx
  on plaid_transactions(account_id, transaction_date desc);
