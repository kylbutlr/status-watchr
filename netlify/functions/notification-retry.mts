import { automaticWorkAllowed } from "./lib/work-switch.js";
import { neon } from "@neondatabase/serverless";
import { drainNotifications } from "./lib/notifications.js";

export default async function handler() {
  if (!process.env.DATABASE_URL || !await automaticWorkAllowed()) return;
  const sql = neon(process.env.DATABASE_URL);
  try {
    await drainNotifications(sql);
    // Real deletion, not just hiding records in the dashboard query.
    await sql`delete from notification_deliveries where created_at < now() - interval '7 days'`;
    await sql`delete from question_requests where created_at < now() - interval '7 days'`;
    await sql`delete from agent_events where occurred_at < now() - interval '30 days'`;
    await sql`delete from agent_sessions where last_seen_at < now() - interval '30 days'`;
    await sql`delete from internal_review_threads review where reported_at < now() - interval '37 days'
      and not exists (select 1 from agent_sessions session where lower(coalesce(session.thread_id, session.id)) = review.thread_id)`;
    await sql`delete from conversation_relationships relationship where reported_at < now() - interval '37 days'
      and not exists (select 1 from agent_sessions session where lower(coalesce(session.thread_id, session.id)) = relationship.thread_id)
      and not exists (select 1 from conversation_relationships descendant where descendant.parent_thread_id = relationship.thread_id)`;
  } catch {
    console.error("Status Watchr notification retry or retention unavailable");
    throw new Error("Notification maintenance unavailable");
  }
}

export const config = { schedule: "* * * * *" };
