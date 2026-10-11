create extension if not exists pgcrypto;

create table if not exists users (
  user_id text primary key,
  username text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists plaid_items (
  id uuid primary key default gen_random_uuid(),
  user_id text not null references users(user_id) on delete cascade,
  plaid_item_id text not null unique,
  encrypted_access_token text not null,
  access_token_iv text not null,
  access_token_auth_tag text not null,
  cursor text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists plaid_items_user_id_idx on plaid_items(user_id);

create table if not exists monthly_spending_summaries (
  id uuid primary key default gen_random_uuid(),
  user_id text not null references users(user_id) on delete cascade,
  month text not null check (month ~ '^\d{4}-\d{2}$'),
  total_spent numeric(14, 2) not null default 0,
  categories jsonb not null default '[]'::jsonb,
  transaction_count integer not null default 0,
  calculated_at timestamptz not null default now(),
  unique (user_id, month)
);

create index if not exists monthly_spending_summaries_user_id_idx
  on monthly_spending_summaries(user_id);
