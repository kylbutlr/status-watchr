import { createHash } from "node:crypto";
import webpush, { type PushSubscription } from "web-push";
import type { NeonQueryFunction } from "@neondatabase/serverless";

export type SQL = NeonQueryFunction<false, false>;
export const digest = (value: string) => createHash("sha256").update(value).digest("hex");
function runNotificationIdentity(threadId: string, turnId: string, status: string, attentionId?: string) {
  return digest(JSON.stringify([threadId, turnId, status, status === "needs_you" ? attentionId : null]));
}
export function pushConfigured() {
  return Boolean(process.env.WATCHR_VAPID_PUBLIC_KEY && process.env.WATCHR_VAPID_PRIVATE_KEY && process.env.WATCHR_VAPID_SUBJECT);
}

export function validateSubscription(value: unknown): PushSubscription {
  if (!value || typeof value !== "object") throw new Error("Invalid subscription");
  const item = value as Partial<PushSubscription>;
  if (typeof item.endpoint !== "string" || item.endpoint.length > 2048) throw new Error("Invalid subscription");
  const url = new URL(item.endpoint);
  // Exact provider allowlist prevents the authenticated endpoint becoming an SSRF proxy.
  if (url.protocol !== "https:" || url.port || url.username || url.password || url.hash ||
      !["web.push.apple.com", "fcm.googleapis.com", "updates.push.services.mozilla.com"].includes(url.hostname)) throw new Error("Unsupported push service");
  const keys = item.keys;
  if (!keys || !/^[A-Za-z0-9_-]{87}$/.test(keys.p256dh) || !/^[A-Za-z0-9_-]{22}$/.test(keys.auth)) throw new Error("Invalid subscription keys");
  return { endpoint: url.href, keys: { p256dh: keys.p256dh, auth: keys.auth } };
}

export function notificationIdentity(body: Record<string, unknown>, now = Date.now()) {
  if (body.notificationEligible === false) return null;
  const { threadId, turnId, status, attentionId, occurredAt } = body;
  if (typeof threadId !== "string" || typeof turnId !== "string" || !threadId || !turnId) return null;
  if (!["finished", "needs_you", "failed"].includes(String(status))) return null;
  const occurred = typeof occurredAt === "string" ? Date.parse(occurredAt) : NaN;
  // Recovery must not turn historical completions into a burst of new phone alerts.
  if (!Number.isFinite(occurred) || occurred > now + 60_000 || now - occurred > 10 * 60_000) return null;
  if (status === "needs_you" && (typeof attentionId !== "string" || !attentionId)) return null;
  return runNotificationIdentity(threadId, turnId, String(status), typeof attentionId === "string" ? attentionId : undefined);
}

async function completionStillActionable(sql: SQL, job: Record<string, unknown>) {
  const runs = await sql`
    select turn_id, status, started_at from agent_sessions
    where thread_id = ${job.thread_id}
    order by started_at desc, turn_id desc limit 20
  `;
  const completed = runs.find(run => typeof run.turn_id === "string" &&
    `${runNotificationIdentity(String(job.thread_id), run.turn_id, "finished")}:${job.subscription_id}` === job.id);
  // Retention or newer history can remove the evidence needed for an old queued alert.
  if (!completed || completed.status !== "finished") return false;
  const uuid7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const timestamp = (value: unknown) => value instanceof Date ? value.getTime() : Date.parse(String(value));
  const completedStart = timestamp(completed.started_at);
  const completedAt = timestamp(job.event_occurred_at);
  return !runs.some(run => {
    if (run.turn_id === completed.turn_id) return false;
    // UUIDv7's timestamp retains millisecond precision when Stop receipt/source seconds do not.
    if (typeof run.turn_id === "string" && typeof completed.turn_id === "string" &&
        uuid7.test(run.turn_id) && uuid7.test(completed.turn_id)) {
      const startedMs = Number.parseInt(run.turn_id.replace(/-/g, "").slice(0, 12), 16);
      const completedMs = Number.parseInt(completed.turn_id.replace(/-/g, "").slice(0, 12), 16);
      if (startedMs !== completedMs) return startedMs > completedMs;
      // The remaining bits can be random; ties fall back to observed source start times.
    }
    const started = timestamp(run.started_at);
    return Number.isFinite(started) && (started > completedStart || started >= completedAt);
  });
}

export function notificationPayload(id: string, kind: string, conversationTitle?: string | null, replyPreview?: string | null) {
  const cleanTitle = typeof conversationTitle === "string"
    ? Array.from(conversationTitle.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim()).slice(0, 120).join("")
    : "";
  const normalizedReply = kind === "finished" && typeof replyPreview === "string"
    ? replyPreview.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim()
    : "";
  let cleanReply = "";
  for (const character of normalizedReply) {
    if (cleanReply.length + character.length > 180) break;
    cleanReply += character;
  }
  return JSON.stringify({
    title: "Status Watchr",
    // Keep question wire copy compatible with already-installed phone workers' allowlist.
    body: kind === "test" ? "Test notification. Your private phone alert path is connected." : kind === "question" || kind === "needs_you" ? "A watched conversation needs your attention." : kind === "failed" ? "A watched run failed. Open your private dashboard." : "A watched run finished. Open your private dashboard.",
    ...(kind !== "test" && cleanTitle && cleanTitle !== "Untitled task" ? { conversationTitle: cleanTitle } : {}),
    ...(cleanReply ? { replyPreview: cleanReply } : {}),
    tag: id,
    url: "/",
  });
}

export async function sendPush(subscription: PushSubscription, id: string, kind: string, ttl = 3600, conversationTitle?: string | null, replyPreview?: string | null) {
  if (!pushConfigured()) throw new Error("Push not configured");
  await webpush.sendNotification(subscription, notificationPayload(id, kind, conversationTitle, replyPreview), {
    TTL: ttl, urgency: "normal", timeout: 10_000,
    topic: digest(id).slice(0, 32),
    vapidDetails: { subject: process.env.WATCHR_VAPID_SUBJECT!, publicKey: process.env.WATCHR_VAPID_PUBLIC_KEY!, privateKey: process.env.WATCHR_VAPID_PRIVATE_KEY! },
  });
}

export function pushFailureDisposition(error: unknown) {
  const status = error && typeof error === "object" && "statusCode" in error ? Number(error.statusCode) : 0;
  return status === 404 || status === 410 ? "revoke" : "retry";
}

export async function drainNotifications(sql: SQL, send = sendPush) {
  if (!pushConfigured()) return;
  // Lease rows atomically across ingestion requests and scheduled retry invocations.
  const jobs = await sql`
    update notification_deliveries set lease_until = now() + interval '2 minutes', attempts = attempts + 1
    where id in (
      select id from notification_deliveries
      where delivered_at is null and expires_at > now() and attempts < 8
        and next_attempt_at <= now() and (lease_until is null or lease_until < now())
      order by created_at limit 10 for update skip locked
    ) returning id, thread_id, kind, subscription_id, event_occurred_at, reply_preview, created_at, question_request_id
  `;
  await Promise.all(jobs.map(async (job) => {
    // Recheck the actual run immediately before dispatch, including persisted retry jobs.
    if (job.kind === "finished" && !await completionStillActionable(sql, job)) {
      await sql`delete from notification_deliveries where id = ${job.id}`;
      return;
    }
    const rows = await sql`
      select s.subscription, coalesce((select case
        when ${job.kind} = 'question' and run.title ~* '^(Untitled task|Codex task|Codex (task|subagent) [0-9a-f]{8}|Subagent [0-9a-f]{8})$'
        then null else run.title end from agent_sessions run
        where run.thread_id = ${job.thread_id}
        order by coalesce(run.last_event_at, run.started_at, run.last_seen_at) desc,
          run.last_seen_at desc, run.id desc limit 1),
        (select question.title from question_requests question where question.id = ${job.question_request_id})) as conversation_title,
        case when exists (select 1 from conversation_watches w
        where w.thread_id = ${job.thread_id} and w.enabled and w.enabled_since <= ${job.event_occurred_at}::timestamptz)
        or exists (select 1 from notification_preferences where id = 'owner' and all_until = 'infinity'::timestamptz)
        then 3600 else greatest(0, least(3600, floor(extract(epoch from
          (select all_until - now() from notification_preferences where id = 'owner'))))) end as ttl
      from push_subscriptions s
      where s.id = ${job.subscription_id} and notification_allowed(${job.thread_id}, ${job.event_occurred_at}::timestamptz)
        and (${job.kind} <> 'question' or (${process.env.WATCHR_QUESTION_ALERTS_ENABLED === 'true'} and exists (
          select 1 from question_requests question where question.id = ${job.question_request_id}
            and question.resolved_at is null and question.expires_at > now()
        )))
        and not exists (select 1 from internal_review_threads review where review.thread_id = lower(${job.thread_id}))
        -- A later working event invalidates this request, even if another request is now pending.
        and (${job.kind} <> 'needs_you' or exists (
          select 1 from agent_sessions run
          where run.thread_id = ${job.thread_id} and run.status = 'needs_you'
            and run.last_event_at >= ${job.event_occurred_at}::timestamptz
            and not exists (
              select 1 from agent_events later
              join agent_sessions source on source.id = later.session_id
              where source.thread_id = ${job.thread_id}
                and later.created_at > ${job.created_at}::timestamptz
                and later.tone <> 'attention'
            )
        ))
    `;
    if (!rows.length) {
      await sql`delete from notification_deliveries where id = ${job.id}`;
      return;
    }
    try {
      await send(validateSubscription(rows[0].subscription), String(job.id), String(job.kind), Number(rows[0].ttl), rows[0].conversation_title as string | null, job.reply_preview as string | null);
      await sql`update notification_deliveries set delivered_at = now(), lease_until = null, reply_preview = null where id = ${job.id}`;
    } catch (error) {
      if (pushFailureDisposition(error) === "revoke") {
        await sql`delete from push_subscriptions where id = ${job.subscription_id}`;
      } else {
        await sql`update notification_deliveries set lease_until = null,
          next_attempt_at = now() + interval '1 minute' * least(60, power(2, attempts)) where id = ${job.id}`;
      }
      // Never log a push error: provider errors can contain endpoint credentials.
    }
  }));
}
