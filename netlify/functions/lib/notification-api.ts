import { randomUUID } from "node:crypto";
import { digest, pushConfigured, sendPush, validateSubscription, type SQL } from "./notifications.js";

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export function sameOriginMutation(request: Request) {
  return request.headers.get("origin") === new URL(request.url).origin && request.headers.get("content-type")?.startsWith("application/json") === true;
}

export async function notificationAPI(request: Request, path: string, sql: SQL) {
  if (request.method !== "GET" && !sameOriginMutation(request)) return json({ error: "Same-origin JSON request required" }, 403);
  try {
    if (path === "/notifications" && request.method === "GET") {
      const watches = await sql`select watch.thread_id, watch.enabled, row_to_json(latest) as session
        from conversation_watches watch
        left join lateral (
          select id, thread_id, title, repo, branch, status, status_detail, last_seen_at,
            last_event_at, started_at, finished_at
          from agent_sessions where coalesce(thread_id, id) = watch.thread_id
          order by coalesce(last_event_at, started_at, last_seen_at) desc, last_seen_at desc, id desc limit 1
        ) latest on true
        where not exists (select 1 from internal_review_threads review where review.thread_id = lower(watch.thread_id))
        order by watch.updated_at desc, watch.thread_id`;
      const devices = await sql`select id, created_at from push_subscriptions order by created_at desc`;
      const preferences = await sql`select all_until = 'infinity'::timestamptz as always_on,
        case when isfinite(all_until) then all_until else null end as all_until
        from notification_preferences where id = 'owner' and all_until > now()`;
      return json({ configured: pushConfigured(), publicKey: pushConfigured() ? process.env.WATCHR_VAPID_PUBLIC_KEY : null, watches, devices, allAlways: preferences[0]?.always_on === true, allUntil: preferences[0]?.all_until ?? null, serverNow: new Date().toISOString() });
    }
    if (Number(request.headers.get("content-length")) > 4096) return json({ error: "Request too large" }, 413);
    const raw = await request.text();
    if (raw.length > 4096) return json({ error: "Request too large" }, 413);
    const body = JSON.parse(raw) as Record<string, unknown>;
    if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "JSON object required" }, 400);
    if (path === "/notifications/all" && request.method === "PUT") {
      const timed = body.mode === undefined && typeof body.minutes === 'number' && [0, 15, 60, 240].includes(body.minutes);
      const always = body.mode === 'always' && body.minutes === undefined && body.until === undefined;
      const midnight = body.mode === 'midnight' && body.minutes === undefined && typeof body.until === 'string'
        && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(body.until)
        && Date.parse(body.until) > Date.now() && Date.parse(body.until) <= Date.now() + 26 * 60 * 60_000;
      if ((!timed || body.until !== undefined) && !always && !midnight) return json({ error: "Choose a supported notification duration" }, 400);
      const until = always ? 'infinity' : midnight ? body.until as string : body.minutes === 0 ? null : new Date(Date.now() + Number(body.minutes) * 60_000).toISOString();
      await sql`insert into notification_preferences(id, all_since, all_until)
        values ('owner', case when ${until}::timestamptz is null then null else now() end, ${until}::timestamptz)
        on conflict(id) do update set all_since = case when excluded.all_until is null then null
          when notification_preferences.all_until > now() then notification_preferences.all_since else now() end,
          all_until = excluded.all_until`;
      await sql`delete from notification_deliveries where delivered_at is null and not notification_allowed(thread_id, event_occurred_at)`;
      return json({ saved: true });
    }
    if (path === "/notifications/watch" && request.method === "PUT") {
      if (typeof body.threadId !== "string" || body.threadId.length > 200 || typeof body.enabled !== "boolean") return json({ error: "Invalid watch preference" }, 400);
      const exists = await sql`select id from agent_sessions where coalesce(thread_id, id) = ${body.threadId}
        and not exists (select 1 from internal_review_threads review where review.thread_id = lower(${body.threadId})) limit 1`;
      if (!exists.length && body.enabled) return json({ error: "Conversation not found" }, 404);
      if (!exists.length) {
        await sql`update conversation_watches set enabled = false, updated_at = now() where thread_id = ${body.threadId}`;
        await sql`delete from notification_deliveries where thread_id = ${body.threadId} and delivered_at is null and not notification_allowed(thread_id, event_occurred_at)`;
        return json({ enabled: false });
      }
      await sql`insert into conversation_watches(thread_id, enabled) values (${body.threadId}, ${body.enabled})
        on conflict(thread_id) do update set enabled = excluded.enabled, updated_at = now(),
          enabled_since = case when excluded.enabled and not conversation_watches.enabled then now() else conversation_watches.enabled_since end`;
      if (!body.enabled) await sql`delete from notification_deliveries where thread_id = ${body.threadId} and delivered_at is null and not notification_allowed(thread_id, event_occurred_at)`;
      return json({ enabled: body.enabled });
    }
    if (path === "/notifications/subscribe" && request.method === "POST") {
      if (!pushConfigured()) return json({ error: "Phone notifications are not configured on the server yet" }, 503);
      const subscription = validateSubscription(body.subscription);
      const id = digest(subscription.endpoint);
      const count = await sql`select count(*)::int as count from push_subscriptions`;
      const existing = await sql`select id from push_subscriptions where id = ${id}`;
      if (Number(count[0]?.count) >= 10 && !existing.length) return json({ error: "Remove an old device before adding another" }, 409);
      await sql`insert into push_subscriptions(id, subscription) values (${id}, ${JSON.stringify(subscription)}::jsonb)
        on conflict(id) do update set subscription = excluded.subscription`;
      return json({ id });
    }
    if (path === "/notifications/unsubscribe" && request.method === "POST") {
      if (typeof body.id !== "string") return json({ error: "Device required" }, 400);
      await sql`delete from push_subscriptions where id = ${body.id}`;
      return json({ removed: true });
    }
    if (path === "/notifications/test" && request.method === "POST") {
      if (typeof body.id !== "string") return json({ error: "Device required" }, 400);
      const rows = await sql`update push_subscriptions set last_test_at = now() where id = ${body.id}
        and (last_test_at is null or last_test_at < now() - interval '1 minute') returning subscription`;
      if (!rows.length) return json({ error: "Enable this device first, or wait one minute before testing again" }, 429);
      await sendPush(validateSubscription(rows[0].subscription), randomUUID(), "test");
      return json({ accepted: true });
    }
    return json({ error: "Not found" }, 404);
  } catch {
    return json({ error: "Notification request failed. Check configuration and try again." }, 503);
  }
}
