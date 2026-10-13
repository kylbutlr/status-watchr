-- Apply before the corresponding hosted bundle. No production data is rewritten.
begin;
create table question_requests (
  id text primary key,
  thread_id text not null,
  attention_id text not null,
  turn_id text not null,
  title text not null,
  opened_at timestamptz,
  resolved_at timestamptz,
  expires_at timestamptz not null default now() + interval '1 hour',
  created_at timestamptz not null default now()
);
alter table notification_deliveries drop constraint notification_deliveries_kind_check;
alter table notification_deliveries add constraint notification_deliveries_kind_check
  check (kind in ('finished', 'needs_you', 'failed', 'question'));
alter table notification_deliveries add column question_request_id text references question_requests(id) on delete cascade;
commit;
