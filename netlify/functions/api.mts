import { workPermission, automaticWorkAllowed } from "./lib/work-switch.js";
import { neon } from "@neondatabase/serverless";
import { notificationAPI } from "./lib/notification-api.js";
import { notificationIdentity, drainNotifications } from "./lib/notifications.js";
import { ingestQuestion } from './lib/question-events.js';
import { normalizedIngestEvent } from "./lib/ingest-event.js";
import {
  clearedSessionCookie,
  createSessionValue,
  hasValidIngestToken,
  hasValidSession,
  isPasswordConfigured,
  sessionCookie,
  verifyAccessPassword,
} from "./lib/auth.js";

const statuses = new Set(["working", "needs_you", "finished", "failed", "stale"]);
const tones = new Set(["working", "attention", "success", "danger", "quiet"]);
const sessionPageSize = 10;

type SessionCursor = { status: string; priority: number; lastSeenAt: string; id: string };

type JsonRecord = Record<string, unknown>;

function json(body: unknown, status = 200, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

function notModified(revision: string) {
  return new Response(null, {
    status: 304,
    headers: { "cache-control": "private, no-cache", "x-status-watchr-revision": revision },
  });
}

function database() {
  const connectionString = process.env.DATABASE_URL;
  return connectionString ? neon(connectionString) : null;
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseSessionCursor(value: string | null, status: string): SessionCursor | null {
  if (!value || value.length > 2_048) return null;
  try {
    const parsed = JSON.parse(value) as Partial<SessionCursor>;
    const expectedPriority: Record<string, number> = { needs_you: 0, failed: 1, working: 2, finished: 3, stale: 4 };
    if (
      parsed.status !== status ||
      !Number.isInteger(parsed.priority) || Number(parsed.priority) < 0 || Number(parsed.priority) > 4 ||
      (status !== "all" && parsed.priority !== expectedPriority[status]) ||
      typeof parsed.lastSeenAt !== "string" || !Number.isFinite(Date.parse(parsed.lastSeenAt)) ||
      typeof parsed.id !== "string" || parsed.id.length === 0 || parsed.id.length > 512
    ) return null;
    return parsed as SessionCursor;
  } catch {
    return null;
  }
}

function requiredString(value: unknown, field: string) {
  if (typeof value !== "string" || value.trim().length === 0) throw new Error(`${field} is required`);
  return value.trim();
}

async function readJson(request: Request) {
  if (Number(request.headers.get("content-length")) > 16_384) throw new Error("Request too large");
  const raw = await request.text();
  if (raw.length > 16_384) throw new Error("Request too large");
  const value = JSON.parse(raw);
  if (!isRecord(value)) throw new Error("JSON object required");
  return value;
}

export default async function handler(request: Request) {
  try { return await route(request); }
  catch { return json({ error: "Service unavailable. Try again shortly." }, 503); }
}

async function route(request: Request) {
  const requestUrl = new URL(request.url);
  const path = requestUrl.pathname.replace(/^\/api/, "") || "/health";
  if (path === "/work-state" && request.method === "GET") {
    if (!hasValidSession(request) && !hasValidIngestToken(request)) return json({ error: "Authentication required" }, 401);
    return json(await workPermission());
  }
  // Reject unacknowledged automatic uploads before opening Neon. The native outbox retains them.
  if ((path === "/events" || path === "/collector") && request.method === "POST") {
    if (!hasValidIngestToken(request)) return json({ error: "Ingestion authentication required" }, 401);
    if (!await automaticWorkAllowed()) return json({ error: "Automatic work paused by App Switchr" }, 503, { "retry-after": "30" });
  }
  const sql = database();

  if (path === "/health" && request.method === "GET") {
    return json({ ok: true, service: "status-watchr", databaseConfigured: Boolean(sql), passwordConfigured: isPasswordConfigured() });
  }

  if (path === "/auth/session" && request.method === "GET") {
    return json({ authenticated: hasValidSession(request), passwordConfigured: isPasswordConfigured() });
  }

  if (path === "/auth/login" && request.method === "POST") {
    try {
      const body = await readJson(request);
      const password = requiredString(body.password, "password");
      if (!isPasswordConfigured()) return json({ error: "Access credentials are not configured" }, 503);
      if (!verifyAccessPassword(password)) return json({ error: "Incorrect password" }, 401);
      return json({ authenticated: true }, 200, { "set-cookie": sessionCookie(createSessionValue()) });
    } catch {
      return json({ error: "Invalid login request" }, 400);
    }
  }

  if (path === "/auth/logout" && request.method === "POST") {
    return json({ authenticated: false }, 200, { "set-cookie": clearedSessionCookie() });
  }

  if (!sql) return json({ error: "DATABASE_URL is not configured" }, 503);

  if (path === "/collector" && request.method === "POST") {
    if (!hasValidIngestToken(request)) return json({ error: "Ingestion authentication required" }, 401);
    const body = await readJson(request);
    if (typeof body.sourceAvailable !== "boolean" || !["trusted", "untrusted", "unknown"].includes(String(body.hookTrust)) ||
        !Number.isInteger(body.queued) || Number(body.queued) < 0 || Number(body.queued) > 5000) return json({ error: "Invalid collector health" }, 400);
    await sql`insert into collector_health (id, source_available, hook_trust, last_hook_at, queued)
      values ('mac', ${body.sourceAvailable}, ${String(body.hookTrust)}, ${typeof body.lastHookAt === "string" ? body.lastHookAt : null}::timestamptz, ${Number(body.queued)})
      on conflict(id) do update set source_available = excluded.source_available, hook_trust = excluded.hook_trust,
        last_hook_at = excluded.last_hook_at, queued = excluded.queued, received_at = now()`;
    return json({ accepted: true }, 202);
  }

  if (path === "/collector" && request.method === "GET") {
    if (!hasValidSession(request)) return json({ error: "Authentication required" }, 401);
    const rows = await sql`select source_available, hook_trust, last_hook_at, queued, received_at from collector_health where id = 'mac'`;
    return json({ collector: rows[0] ?? null });
  }

  if (path === "/notifications" || path.startsWith("/notifications/")) {
    if (!hasValidSession(request)) return json({ error: "Authentication required" }, 401);
    return notificationAPI(request, path, sql);
  }

  if (path === "/sessions" && request.method === "GET") {
    if (!hasValidSession(request)) return json({ error: "Authentication required" }, 401);
    const requestedStatus = requestUrl.searchParams.get("status") ?? "all";
    if (requestedStatus !== "all" && !statuses.has(requestedStatus)) return json({ error: "Invalid session status" }, 400);
    const cursorValue = requestUrl.searchParams.get("cursor");
    const cursor = parseSessionCursor(cursorValue, requestedStatus);
    if (cursorValue && !cursor) return json({ error: "Invalid session cursor" }, 400);
    const revisionRows = await sql`
      select concat(
        greatest(
          coalesce((select updated_at from agent_sessions order by updated_at desc limit 1), '-infinity'::timestamptz),
          coalesce((select created_at from agent_events order by created_at desc limit 1), '-infinity'::timestamptz)
        )::text,
        ':',
        (select count(*) from agent_sessions where status in ('working', 'needs_you') and updated_at < now() - interval '2 hours'),
        ':reviews:', coalesce((select max(reported_at)::text from internal_review_threads), 'empty'),
        ':', (select count(*) from internal_review_threads),
        ':relationships:', coalesce((select max(reported_at)::text from conversation_relationships), 'empty'),
        ':', (select count(*) from conversation_relationships)
      ) as revision,
      coalesce((select md5(string_agg(thread_id || '>' || root_thread_id, ',' order by thread_id))
        from conversation_roots where thread_id <> root_thread_id), 'empty') as grouping_revision
    `;
    const groupingRevision = String(revisionRows[0]?.grouping_revision ?? "empty");
    const revision = `${String(revisionRows[0]?.revision ?? "empty")}:groups:${groupingRevision}`;
    if (!cursor && requestUrl.searchParams.get("since") === revision) return notModified(revision);

    const rows = await sql`
      with raw_sessions as (
        select id, thread_id, turn_id, title, repo, branch, status, status_detail, last_seen_at, last_event_at, started_at, finished_at, updated_at
        from agent_sessions session
        where updated_at > now() - interval '30 days'
          and not exists (select 1 from internal_review_threads review where review.thread_id = lower(coalesce(session.thread_id, session.id)))
      ), ranked_sessions as (
        select session.*,
          row_number() over (
            partition by coalesce(thread_id, id)
            order by started_at desc nulls last, last_event_at desc, id desc
          ) as task_rank
        from raw_sessions session
      ), visible_sessions as (
        select id, thread_id, turn_id, title, repo, branch,
          case
            when status in ('working', 'needs_you') and updated_at < now() - interval '2 hours' then 'stale'
            else status
          end as status,
          case
            when status in ('working', 'needs_you') and updated_at < now() - interval '2 hours' then 'No recent collector heartbeat'
            else status_detail
          end as status_detail,
          last_seen_at, last_event_at, started_at, finished_at
        from ranked_sessions session
        where task_rank = 1
          and lower(coalesce(thread_id, id)) in (select thread_id from conversation_roots where thread_id = root_thread_id)
      ), summary as (
        select count(*) filter (where status = 'working') as working_count,
          count(*) filter (where status = 'needs_you') as needs_you_count,
          count(*) filter (where status = 'finished') as finished_count,
          count(*) filter (where status = 'failed') as failed_count,
          count(*) filter (where status = 'stale') as stale_count
        from visible_sessions
      ), paged_sessions as (
        select session.*,
          case session.status when 'needs_you' then 0 when 'failed' then 1 when 'working' then 2 when 'finished' then 3 when 'stale' then 4 else 5 end as status_rank
        from visible_sessions session
        where (${requestedStatus === "all" ? null : requestedStatus}::text is null or session.status = ${requestedStatus === "all" ? null : requestedStatus})
          and (${cursor?.priority ?? null}::integer is null
            or case session.status when 'needs_you' then 0 when 'failed' then 1 when 'working' then 2 when 'finished' then 3 when 'stale' then 4 else 5 end > ${cursor?.priority ?? null}::integer
            or (case session.status when 'needs_you' then 0 when 'failed' then 1 when 'working' then 2 when 'finished' then 3 when 'stale' then 4 else 5 end = ${cursor?.priority ?? null}::integer
              and session.last_seen_at < ${cursor?.lastSeenAt ?? null}::timestamptz)
            or (case session.status when 'needs_you' then 0 when 'failed' then 1 when 'working' then 2 when 'finished' then 3 when 'stale' then 4 else 5 end = ${cursor?.priority ?? null}::integer
              and session.last_seen_at = ${cursor?.lastSeenAt ?? null}::timestamptz
              and session.id < ${cursor?.id ?? null}::text))
        order by status_rank, session.last_seen_at desc, session.id desc
        limit ${sessionPageSize + 1}
      )
      select session.*,
        summary.working_count as summary_working_count,
        summary.needs_you_count as summary_needs_you_count,
        summary.finished_count as summary_finished_count,
        summary.failed_count as summary_failed_count,
        summary.stale_count as summary_stale_count,
        latest_event.id as latest_event_id,
        latest_event.event_type as latest_event_type,
        latest_event.label as latest_event_label,
        latest_event.detail as latest_event_detail,
        latest_event.tone as latest_event_tone,
        latest_event.occurred_at as latest_event_occurred_at
      from summary
      left join paged_sessions session on true
      left join lateral (
        select event.id, event.event_type, event.label, event.detail, event.tone, event.occurred_at
        from agent_events event
        inner join raw_sessions event_session on event_session.id = event.session_id
        where session.id is not null and (
          (session.thread_id is not null and session.thread_id = event_session.thread_id)
          or (session.thread_id is null and session.id = event_session.id)
        )
          and event.occurred_at > now() - interval '7 days'
        order by event.occurred_at desc
        limit 1
      ) latest_event on true
      order by session.status_rank, session.last_seen_at desc, session.id desc
    `;
    const dataRows = rows.filter((row) => typeof row.id === "string");
    const pageRows = dataRows.slice(0, sessionPageSize);
    const lastPageRow = pageRows.at(-1);
    const nextCursor = dataRows.length > sessionPageSize && lastPageRow ? JSON.stringify({
      status: requestedStatus,
      priority: Number(lastPageRow.status_rank),
      lastSeenAt: lastPageRow.last_seen_at,
      id: lastPageRow.id,
    } satisfies SessionCursor) : null;
    const summaryRow = rows[0];
    const counts = {
      working: Number(summaryRow?.summary_working_count ?? 0),
      needs_you: Number(summaryRow?.summary_needs_you_count ?? 0),
      finished: Number(summaryRow?.summary_finished_count ?? 0),
      failed: Number(summaryRow?.summary_failed_count ?? 0),
      stale: Number(summaryRow?.summary_stale_count ?? 0),
    };
    const sessions = pageRows.map(({ status_rank: _rank, summary_working_count: _working, summary_needs_you_count: _needsYou, summary_finished_count: _finished, summary_failed_count: _failed, summary_stale_count: _stale, latest_event_id: _id, latest_event_type: _type, latest_event_label: _label, latest_event_detail: _detail, latest_event_tone: _tone, latest_event_occurred_at: _occurredAt, ...session }) => session);
    const events = pageRows.flatMap((row) => row.latest_event_id ? [{
      id: row.latest_event_id,
      session_id: row.id,
      event_type: row.latest_event_type,
      label: row.latest_event_label,
      detail: row.latest_event_detail,
      tone: row.latest_event_tone,
      occurred_at: row.latest_event_occurred_at,
    }] : []);
    return json({ revision, groupingRevision, sessions, events, counts, nextCursor }, 200, { "x-status-watchr-revision": revision });
  }

  const sessionEventsMatch = /^\/sessions\/([^/]+)\/events$/.exec(path);
  if (sessionEventsMatch && request.method === "GET") {
    if (!hasValidSession(request)) return json({ error: "Authentication required" }, 401);
    let sessionId: string;
    try {
      sessionId = decodeURIComponent(sessionEventsMatch[1]);
    } catch {
      return json({ error: "Invalid session ID" }, 400);
    }
    const events = await sql`
      with selected_session as (
        select id, thread_id
        from agent_sessions
        where id = ${sessionId}
          and not exists (select 1 from internal_review_threads review where review.thread_id = lower(coalesce(agent_sessions.thread_id, agent_sessions.id)))
        limit 1
      ), related_sessions as (
        select candidate.id, candidate.title,
          lower(coalesce(candidate.thread_id, candidate.id)) <> lower(coalesce(selected.thread_id, selected.id)) as is_subtask
        from agent_sessions candidate
        cross join selected_session selected
        where not exists (select 1 from internal_review_threads review where review.thread_id = lower(coalesce(candidate.thread_id, candidate.id)))
          and (
            (selected.thread_id is not null and candidate.thread_id = selected.thread_id)
            or (selected.thread_id is null and candidate.id = selected.id)
            or lower(coalesce(candidate.thread_id, candidate.id)) in (
              select thread_id from conversation_roots
              where root_thread_id = lower(coalesce(selected.thread_id, selected.id))
            )
          )
      )
      select event.id, event.session_id, event.event_type, event.label,
        case when related.is_subtask then related.title else null end as subtask_title,
        event.detail, event.tone, event.occurred_at
      from agent_events event join related_sessions related on related.id = event.session_id
      where event.occurred_at > now() - interval '30 days'
      order by event.occurred_at desc
      limit 100
    `;
    return json({ events });
  }

  if (path === "/events" && request.method === "POST") {
    if (!hasValidIngestToken(request)) return json({ error: "Ingestion authentication required" }, 401);
    try {
      const body = normalizedIngestEvent(await readJson(request));
      if (body.eventType === 'local/threads/relationships') {
        const relationships = body.threadRelationships as { threadId: string; parentThreadId: string }[];
        await sql`insert into conversation_relationships(thread_id, parent_thread_id)
          select unnest(${relationships.map(row => row.threadId)}::text[]),
                 unnest(${relationships.map(row => row.parentThreadId)}::text[])
          on conflict(thread_id) do update set parent_thread_id = excluded.parent_thread_id, reported_at = now()
          where conversation_relationships.parent_thread_id <> excluded.parent_thread_id`;
        return json({ accepted: true }, 202);
      }
      if (body.eventType === 'local/threads/titles') {
        const titles = body.threadTitles as { threadId: string; title: string }[];
        await sql`with incoming as (
          select unnest(${titles.map(row => row.threadId)}::text[]) as thread_id,
                 unnest(${titles.map(row => row.title)}::text[]) as title
        ) update agent_sessions session set title = incoming.title, updated_at = now()
          from incoming where lower(coalesce(session.thread_id, session.id)) = incoming.thread_id
            and session.status in ('finished', 'failed', 'stale')
            and session.updated_at > now() - interval '30 days'
            and session.title ~* '^(Untitled task|Codex task|Codex (task|subagent) [0-9a-f]{8}|Subagent [0-9a-f]{8})$'
            and not exists (select 1 from internal_review_threads review where review.thread_id = incoming.thread_id)`;
        return json({ accepted: true }, 202);
      }
      if (body.eventType === "local/threads/excluded") {
        await sql.transaction([
          sql`insert into internal_review_threads(thread_id)
            select unnest(${body.excludedThreadIds}::text[]) on conflict(thread_id) do nothing`,
          sql`delete from notification_deliveries where delivered_at is null
            and lower(thread_id) = any(${body.excludedThreadIds}::text[])`,
        ]);
        return json({ accepted: true }, 202);
      }
      const sessionId = requiredString(body.sessionId, "sessionId");
      const excluded = await sql`select thread_id from internal_review_threads
        where thread_id = lower(${typeof body.threadId === "string" ? body.threadId : sessionId}) limit 1`;
      if (excluded.length) return json({ accepted: true, ignored: true }, 202);
      if (String(body.eventType).startsWith('local/question/')) {
        if (process.env.WATCHR_QUESTION_ALERTS_ENABLED !== 'true') return json({ accepted: true, ignored: true }, 202);
        await ingestQuestion(sql, body);
        try { await drainNotifications(sql); } catch { /* Scheduled retry owns recovery. */ }
        return json({ accepted: true }, 202);
      }
      const eventId = requiredString(body.eventId, "eventId");
      const eventType = requiredString(body.eventType, "eventType");
      const title = requiredString(body.title, "title");
      // Older collectors and titleless hooks must not erase a conversation's known name.
      const placeholderTitlePattern = '^(Untitled task|Codex task|Codex (task|subagent) [0-9a-f]{8}|Subagent [0-9a-f]{8})$';
      const placeholderTitle = new RegExp(placeholderTitlePattern, 'i').test(title);
      const status = requiredString(body.status, "status");
      const label = requiredString(body.label, "label");
      const tone = requiredString(body.tone, "tone");
      const observedAt = typeof body.observedAt === "string" ? body.observedAt : null;
      if (!statuses.has(status)) throw new Error("status is invalid");
      if (!tones.has(tone)) throw new Error("tone is invalid");
      const notificationId = notificationIdentity(body);
      const parentThreadId = typeof body.parentThreadId === 'string' ? body.parentThreadId : null;

      const [, inserted] = await sql.transaction([
        sql`
          insert into agent_sessions (id, thread_id, turn_id, title, repo, branch, status, status_detail, last_seen_at, last_event_at, started_at, finished_at)
          values (
            ${sessionId}, ${typeof body.threadId === "string" ? body.threadId : null}, ${typeof body.turnId === "string" ? body.turnId : null},
            coalesce((select known.title from agent_sessions known
              where ${placeholderTitle} and coalesce(known.thread_id, known.id) = ${typeof body.threadId === "string" ? body.threadId : sessionId}
                and known.title !~* ${placeholderTitlePattern}
              order by known.last_seen_at desc, known.id desc limit 1), ${title}),
            ${typeof body.repo === "string" ? body.repo : null}, ${typeof body.branch === "string" ? body.branch : null},
            ${status}, ${typeof body.statusDetail === "string" ? body.statusDetail : null},
            coalesce(${observedAt}::timestamptz, ${typeof body.occurredAt === "string" ? body.occurredAt : null}::timestamptz, now()),
            coalesce(${typeof body.occurredAt === "string" ? body.occurredAt : null}::timestamptz, now()),
            coalesce(${typeof body.startedAt === "string" ? body.startedAt : null}::timestamptz, ${typeof body.occurredAt === "string" ? body.occurredAt : null}::timestamptz, now()),
            ${typeof body.finishedAt === "string" ? body.finishedAt : null}
          )
          on conflict (id) do update set
            thread_id = excluded.thread_id,
            turn_id = excluded.turn_id,
            title = case when excluded.title ~* ${placeholderTitlePattern} then agent_sessions.title else excluded.title end,
            repo = excluded.repo,
            branch = excluded.branch,
            status = case
              when agent_sessions.status in ('finished', 'failed', 'stale') and excluded.status in ('working', 'needs_you') then agent_sessions.status
              when excluded.last_event_at >= agent_sessions.last_event_at then excluded.status else agent_sessions.status end,
            status_detail = case
              when agent_sessions.status in ('finished', 'failed', 'stale') and excluded.status in ('working', 'needs_you') then agent_sessions.status_detail
              when excluded.last_event_at >= agent_sessions.last_event_at then excluded.status_detail else agent_sessions.status_detail end,
            last_seen_at = greatest(agent_sessions.last_seen_at, excluded.last_seen_at),
            started_at = least(agent_sessions.started_at, excluded.started_at),
            last_event_at = case
              when agent_sessions.last_event_at is null then excluded.last_event_at
              when excluded.last_event_at is null then agent_sessions.last_event_at
              when excluded.last_event_at >= agent_sessions.last_event_at then excluded.last_event_at
              else agent_sessions.last_event_at
            end,
            finished_at = case
              when agent_sessions.status in ('finished', 'failed', 'stale') and excluded.status in ('working', 'needs_you') then agent_sessions.finished_at
              when excluded.last_event_at >= agent_sessions.last_event_at then excluded.finished_at else agent_sessions.finished_at end,
            updated_at = now()
        `,
        sql`
          insert into agent_events (id, session_id, event_type, label, detail, tone, occurred_at)
          values (
            ${eventId}, ${sessionId}, ${eventType}, ${label},
            ${typeof body.detail === "string" ? body.detail : null}, ${tone},
            coalesce(${typeof body.occurredAt === "string" ? body.occurredAt : null}::timestamptz, now())
          )
          on conflict (id) do nothing
          returning id
        `,
        sql`
          insert into notification_deliveries (id, thread_id, kind, subscription_id, event_occurred_at, reply_preview, next_attempt_at)
          select ${notificationId} || ':' || subscription.id, ${typeof body.threadId === "string" ? body.threadId : null}, ${status}, subscription.id,
            ${typeof body.occurredAt === "string" ? body.occurredAt : null}::timestamptz,
            ${typeof body.replyPreview === "string" ? body.replyPreview : null},
            -- A permission hook can be auto-approved after ingestion; hold only attention pushes.
            case when ${status} = 'needs_you' then now() + interval '10 seconds' else now() end
          from push_subscriptions subscription
          where ${notificationId}::text is not null
            and notification_allowed(${typeof body.threadId === "string" ? body.threadId : null}, ${typeof body.occurredAt === "string" ? body.occurredAt : null}::timestamptz)
            and subscription.created_at <= ${typeof body.occurredAt === "string" ? body.occurredAt : null}::timestamptz
            and exists (select 1 from agent_sessions current_run where current_run.id = ${sessionId} and current_run.status = ${status})
          on conflict(id) do update set reply_preview = excluded.reply_preview
            where notification_deliveries.delivered_at is null
              and notification_deliveries.reply_preview is null
              and excluded.reply_preview is not null
        `,
        sql`insert into conversation_relationships(thread_id, parent_thread_id)
          select lower(${typeof body.threadId === 'string' ? body.threadId : null}), ${parentThreadId}::text
          where ${parentThreadId}::text is not null
          on conflict(thread_id) do update set parent_thread_id = excluded.parent_thread_id, reported_at = now()
          where conversation_relationships.parent_thread_id <> excluded.parent_thread_id`,
      ]);
      // Queue creation is atomic with ingestion. A failed push does not reject the accepted event.
      if (notificationId) { try { await drainNotifications(sql); } catch { /* Scheduled retry owns recovery. */ } }
      return json({ accepted: true, duplicate: inserted.length === 0 }, 202);
    } catch {
      return json({ error: "Event rejected or storage unavailable" }, 400);
    }
  }

  return json({ error: "Not found" }, 404);
}
