-- Additive identity metadata. Apply after approval and backup, before the new API.
begin;
create table conversation_relationships (
  thread_id text primary key,
  parent_thread_id text not null check (thread_id <> parent_thread_id),
  reported_at timestamptz not null default now()
);

-- Keep the highest retained ancestor visible. Missing parents preserve child rows;
-- malformed cycles or chains exceeding 32 links fall back to separate rows.
create view conversation_roots as
with recursive retained as (
  select distinct lower(coalesce(thread_id, id)) as thread_id
  from agent_sessions session
  where updated_at > now() - interval '30 days'
    and not exists (select 1 from internal_review_threads review
      where review.thread_id = lower(coalesce(session.thread_id, session.id)))
), lineage as (
  select thread_id, thread_id as ancestor_id, array[thread_id] as path, false as cycle
  from retained
  union all
  select lineage.thread_id, relationship.parent_thread_id,
    lineage.path || relationship.parent_thread_id, relationship.parent_thread_id = any(lineage.path)
  from lineage join conversation_relationships relationship on relationship.thread_id = lineage.ancestor_id
  where not lineage.cycle and cardinality(lineage.path) < 34
), terminals as (
  select distinct on (thread_id) thread_id, cycle, cardinality(path) as depth
  from lineage order by thread_id, cardinality(path) desc
)
select retained.thread_id,
  case when terminals.cycle or terminals.depth >= 34 then retained.thread_id
    else coalesce(ancestor.ancestor_id, retained.thread_id) end as root_thread_id
from retained join terminals using (thread_id)
left join lateral (
  select lineage.ancestor_id from lineage
  join retained ancestor on ancestor.thread_id = lineage.ancestor_id
  where lineage.thread_id = retained.thread_id
  order by cardinality(lineage.path) desc limit 1
) ancestor on true;
commit;
