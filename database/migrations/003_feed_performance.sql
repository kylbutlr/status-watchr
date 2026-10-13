create index if not exists agent_sessions_updated_at_idx
  on agent_sessions(updated_at desc);

create index if not exists agent_sessions_active_freshness_idx
  on agent_sessions(status, updated_at desc);

create index if not exists agent_sessions_task_recency_idx
  on agent_sessions((coalesce(thread_id, id)), last_event_at desc, last_seen_at desc);

create index if not exists agent_events_created_at_idx
  on agent_events(created_at desc);
