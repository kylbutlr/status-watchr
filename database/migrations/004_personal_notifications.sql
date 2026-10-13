-- Private single-owner only. Apply manually after approval, before deploying this version.
begin;
create table collector_health (
  id text primary key check (id = 'mac'),
  source_available boolean not null,
  hook_trust text not null check (hook_trust in ('trusted', 'untrusted', 'unknown')),
  last_hook_at timestamptz,
  queued integer not null check (queued >= 0),
  received_at timestamptz not null default now()
);
create table conversation_watches (
  thread_id text primary key,
  enabled boolean not null default false,
  enabled_since timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table push_subscriptions (
  id text primary key,
  subscription jsonb not null,
  created_at timestamptz not null default now(),
  last_test_at timestamptz
);
create table notification_deliveries (
  id text primary key,
  thread_id text not null,
  kind text not null check (kind in ('finished', 'needs_you', 'failed')),
  subscription_id text not null references push_subscriptions(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '1 hour',
  next_attempt_at timestamptz not null default now(),
  lease_until timestamptz,
  attempts integer not null default 0,
  delivered_at timestamptz
);
create index notification_delivery_due on notification_deliveries(next_attempt_at) where delivered_at is null;
commit;
