create table if not exists agent_sessions (
  id text primary key,
  thread_id text,
  title text not null,
  repo text,
  branch text,
  status text not null check (status in ('working', 'needs_you', 'finished', 'failed', 'stale')),
  status_detail text,
  last_seen_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists agent_sessions_thread_id_idx on agent_sessions(thread_id) where thread_id is not null;
create index if not exists agent_sessions_status_idx on agent_sessions(status, last_seen_at desc);

create table if not exists agent_events (
  id text primary key,
  session_id text not null references agent_sessions(id) on delete cascade,
  event_type text not null,
  label text not null,
  detail text,
  tone text not null check (tone in ('working', 'attention', 'success', 'danger', 'quiet')),
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists agent_events_session_idx on agent_events(session_id, occurred_at desc);
create index if not exists agent_events_recent_idx on agent_events(occurred_at desc);
