begin;

-- Private single-owner preference, not a multi-tenant identity model.
create table if not exists notification_preferences (
  id text primary key check (id = 'owner'),
  all_since timestamptz,
  all_until timestamptz,
  check ((all_since is null and all_until is null) or
    (all_since is not null and all_until is not null and all_until > all_since))
);
insert into notification_preferences(id) values ('owner') on conflict do nothing;

alter table notification_deliveries add column if not exists event_occurred_at timestamptz;
update notification_deliveries set event_occurred_at = created_at where event_occurred_at is null;
alter table notification_deliveries alter column event_occurred_at set default now();
alter table notification_deliveries alter column event_occurred_at set not null;

-- Rechecked at dispatch, so expiry and manual cancellation work with the browser closed.
-- A single eligibility rule also prevents muting one watch from cancelling global coverage.
create or replace function notification_allowed(conversation text, occurred timestamptz)
returns boolean language sql stable as $$
  select exists (select 1 from conversation_watches
    where thread_id = conversation and enabled and enabled_since <= occurred)
  or exists (select 1 from notification_preferences
    where id = 'owner' and all_until > now() and all_since <= occurred and occurred < all_until)
$$;

commit;
