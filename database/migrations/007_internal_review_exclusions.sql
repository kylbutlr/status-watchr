-- Additive, private single-owner metadata. Apply before deploying the updated API.
begin;
create table internal_review_threads (
  thread_id text primary key,
  reported_at timestamptz not null default now()
);
commit;
