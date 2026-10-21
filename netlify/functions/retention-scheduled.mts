import { automaticWorkAllowed } from './lib/work-switch.js';
import { neon } from '@neondatabase/serverless';

export default async function handler() {
  if (!process.env.DATABASE_URL || !await automaticWorkAllowed()) return;
  const sql = neon(process.env.DATABASE_URL);
  // Preserve the existing retention rules, in a shared six-hour maintenance window.
  await sql`delete from notification_deliveries where created_at < now() - interval '7 days'`;
  await sql`delete from question_requests where created_at < now() - interval '7 days'`;
  await sql`delete from agent_events where occurred_at < now() - interval '30 days'`;
  await sql`delete from agent_sessions where last_seen_at < now() - interval '30 days'`;
  await sql`delete from internal_review_threads review where reported_at < now() - interval '37 days'
    and not exists (select 1 from agent_sessions session where lower(coalesce(session.thread_id, session.id)) = review.thread_id)`;
  await sql`delete from conversation_relationships relationship where reported_at < now() - interval '37 days'
    and not exists (select 1 from agent_sessions session where lower(coalesce(session.thread_id, session.id)) = relationship.thread_id)
    and not exists (select 1 from conversation_relationships descendant where descendant.parent_thread_id = relationship.thread_id)`;
}

export const config = { schedule: '17 */6 * * *' };
