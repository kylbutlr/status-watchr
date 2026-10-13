alter table agent_sessions add column if not exists turn_id text;
alter table agent_sessions add column if not exists last_event_at timestamptz not null default now();

drop index if exists agent_sessions_thread_id_idx;
create unique index if not exists agent_sessions_thread_turn_idx
  on agent_sessions(thread_id, turn_id)
  where thread_id is not null and turn_id is not null;
create unique index if not exists agent_sessions_thread_only_idx
  on agent_sessions(thread_id)
  where thread_id is not null and turn_id is null;
