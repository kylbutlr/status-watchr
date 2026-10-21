import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync, writeFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";
import { resetBlobs, getStore, blobFailure } from './blob-fixture';
import { prepareNotificationWake, retryNotificationWakes, settleNotificationWake } from '../netlify/functions/lib/notification-wakes';
import type { SQL } from "../netlify/functions/lib/notifications";
const mock = vi.hoisted(() => ({ sql: undefined as unknown }));
vi.mock("@neondatabase/serverless", () => ({ neon: () => mock.sql }));
vi.mock('@netlify/blobs', () => import('./blob-fixture'));
import handler from "../netlify/functions/api.mts";
import maintenance from "../netlify/functions/retention-scheduled.mts";
import { createSessionValue } from "../netlify/functions/lib/auth";
import { drainNotifications, notificationIdentity } from "../netlify/functions/lib/notifications";
import { normalizedIngestEvent } from '../netlify/functions/lib/ingest-event';
import { mapLiveEvents } from '../src/domain';

const db = new PGlite();
type Query = { text: string; values: unknown[] };
const sql = Object.assign((strings: TemplateStringsArray, ...values: unknown[]) => {
  const query: Query = { text: strings.reduce((text, part, index) => text + (index ? `$${index}` : "") + part, ""), values };
  return { query, then: (resolve: (value: unknown) => unknown, reject: (error: unknown) => unknown) => db.query(query.text, query.values).then((result) => result.rows).then(resolve, reject) };
}, { transaction: (queries: { query: Query }[]) => db.transaction(async (tx) => {
  const result = [];
  for (const { query } of queries) result.push((await tx.query(query.text, query.values)).rows);
  return result;
}) });

let cookie: string;
const sourceTime = () => new Date(Date.now() - 1000).toISOString();
const event = (patch: Record<string, unknown> = {}) => ({ sessionId: "thread:turn:run", threadId: "thread", turnId: "run", eventId: "event", eventType: "local/task/completed", title: "Private title", status: "finished", occurredAt: sourceTime(), ...patch });
const request = (path: string, method = "GET", body?: unknown, headers: Record<string, string> = {}) => new Request(`https://watchr.test/api${path}`, { method, headers: { "content-type": "application/json", origin: "https://watchr.test", cookie, ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
const ingest = (body: unknown) => handler(request("/events", "POST", body, { authorization: "Bearer ingest-test" }));

beforeAll(async () => {
  mock.sql = sql;
  vi.stubEnv("DATABASE_URL", "postgres://test-only");
  vi.stubEnv("WATCHR_SESSION_SECRET", "test-session-secret");
  vi.stubEnv("WATCHR_INGEST_TOKEN", "ingest-test");
  for (const migration of ["001_initial_schema", "002_turn_aware_status", "003_feed_performance", "004_personal_notifications", "005_temporary_notifications", "006_notification_reply_preview", "007_internal_review_exclusions", "008_conversation_relationships", "009_question_requests"]) await db.exec(readFileSync(new URL(`../database/migrations/${migration}.sql`, import.meta.url), "utf8"));
  cookie = `status_watchr_session=${createSessionValue()}`;
}, 120_000);
beforeEach(async () => {
  resetBlobs();
  vi.stubEnv("WATCHR_VAPID_PUBLIC_KEY", "");
  vi.stubEnv("WATCHR_QUESTION_ALERTS_ENABLED", "true");
  await db.exec("update notification_preferences set all_since = null, all_until = null");
  await db.exec("truncate notification_deliveries, question_requests, push_subscriptions, conversation_watches, collector_health, agent_events, agent_sessions, internal_review_threads, conversation_relationships cascade");
  await db.query("insert into conversation_watches(thread_id, enabled, enabled_since) values ('thread', true, now() - interval '1 minute')");
  await db.query("insert into push_subscriptions(id, subscription, created_at) values ('device', $1::jsonb, now() - interval '1 minute')", [JSON.stringify({ endpoint: "https://web.push.apple.com/test", keys: { p256dh: "a".repeat(87), auth: "b".repeat(22) } })]);
});
afterAll(async () => { await db.close(); vi.unstubAllEnvs(); });

describe("private ingestion and notifications with embedded PostgreSQL", () => {
  const wakeStore = () => getStore({ name: 'watchr-notification-wakes-v1' });

  it('does not accept a notification-producing event without durable retry intent', async () => {
    blobFailure.writes = true;
    expect((await ingest(event())).status).toBe(400);
    expect((await db.query('select id from agent_sessions')).rows).toEqual([]);
    expect((await db.query('select id from notification_deliveries')).rows).toEqual([]);
    blobFailure.writes = false;
    expect((await ingest(event())).status).toBe(202);
    expect((await db.query('select id from notification_deliveries')).rows).toHaveLength(1);
  });

  it('bootstraps legacy deliveries once, then leaves an empty retry tick off Neon', async () => {
    await ingest(event());
    resetBlobs(); // Simulate a delivery created by the previous deployment.
    const open = vi.fn(() => sql as unknown as SQL);
    const send = vi.fn().mockResolvedValue(undefined);
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_PRIVATE_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_SUBJECT', 'mailto:test@example.com');
    await retryNotificationWakes(open, send);
    expect(send).toHaveBeenCalledOnce();
    expect(open).toHaveBeenCalledOnce();
    open.mockClear();
    await retryNotificationWakes(open, send);
    expect(open).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledOnce();
  });

  it('recovers a commit whose request died before finalizing its wake receipt', async () => {
    await wakeStore().setJSON('initialized', true);
    const id = notificationIdentity(event())!;
    const interrupted = await prepareNotificationWake(id);
    await ingest(event());
    const open = vi.fn(() => sql as unknown as SQL);
    await retryNotificationWakes(open);
    expect(open).not.toHaveBeenCalled(); // Neither the staged receipt nor the normal short deferral is due.
    await wakeStore().setJSON(interrupted.key, { ...interrupted, dueAt: 0 });
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_PRIVATE_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_SUBJECT', 'mailto:test@example.com');
    const send = vi.fn().mockResolvedValue(undefined);
    await retryNotificationWakes(open, send);
    expect(send).toHaveBeenCalledOnce();
    expect(await wakeStore().get(interrupted.key)).toBeNull();
  });

  it('keeps independent producer receipts and honors delayed retries without idle preflights', async () => {
    await wakeStore().setJSON('initialized', true);
    await ingest(event());
    const firstId = notificationIdentity(event())!;
    const first = await prepareNotificationWake(firstId);
    const second = await prepareNotificationWake('other-notification');
    await db.exec("update notification_deliveries set next_attempt_at = now() + interval '5 minutes'");
    await settleNotificationWake(sql as unknown as SQL, first);
    const saved = await wakeStore().get(first.key) as { dueAt: number };
    expect(saved.dueAt).toBeGreaterThan(Date.now() + 290_000);
    expect(await wakeStore().get(second.key)).not.toBeNull();
    // Remove only the API's own ready receipt to isolate the future deadline.
    for await (const page of wakeStore().list({ prefix: 'wakes/' })) {
      for (const { key } of page.blobs) if (key !== first.key && key !== second.key) await wakeStore().delete(key);
    }
    const open = vi.fn(() => sql as unknown as SQL);
    await retryNotificationWakes(open);
    expect(open).not.toHaveBeenCalled();
    await db.exec('delete from notification_deliveries');
    await settleNotificationWake(sql as unknown as SQL, first);
    expect(await wakeStore().get(first.key)).toBeNull();
    expect(await wakeStore().get(second.key)).not.toBeNull();
  });

  it('keeps question alerts independent of work and completion, deduplicates, and cancels matching answers', async () => {
    const question = event({ status: 'working', eventType: 'local/question/opened', attentionId: 'call_fixture:0', eventId: 'question', occurredAt: new Date(Date.now() - 6000).toISOString() });
    await ingest(event({status: 'working', eventType: 'local/task/started', eventId: 'start'}));
    expect((await ingest(question)).status).toBe(202);
    expect((await ingest(question)).status).toBe(202);
    await ingest(event({status: 'working', eventType: 'local/task/heartbeat', eventId: 'heartbeat'}));
    await ingest(event({notificationEligible: false}));
    expect((await db.query("select kind from notification_deliveries")).rows).toEqual([{kind: 'question'}]);
    expect((await db.query("select status from agent_sessions")).rows).toEqual([{status: 'finished'}]);
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', 'test');
    vi.stubEnv('WATCHR_VAPID_PRIVATE_KEY', 'test');
    vi.stubEnv('WATCHR_VAPID_SUBJECT', 'mailto:test@example.com');
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][2]).toBe('question');
    await ingest(question);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', '');
    const other = {...question, attentionId: 'call_other:0', eventId: 'question2'};
    await ingest(other);
    await ingest({...other, eventType: 'local/question/answered', eventId: 'answer', occurredAt: sourceTime()});
    expect((await db.query('select kind from notification_deliveries where delivered_at is null')).rows).toEqual([]);
  });
  it('suppresses quick answers, out-of-order opens, disabled trials and historical questions', async () => {
    const question = event({status: 'working', eventType: 'local/question/opened', attentionId: 'call_fixture:0', eventId: 'question'});
    await ingest(question);
    expect((await db.query('select id from notification_deliveries where next_attempt_at <= now()')).rows).toHaveLength(0);
    await ingest({...question, eventType: 'local/question/answered', eventId: 'answer'});
    await ingest(question);
    const other = {...question, attentionId: 'call_other:0'};
    await ingest({...other, eventType: 'local/question/answered', eventId: 'answer-first'});
    await ingest({...other, eventId: 'open-late'});
    await ingest({...question, attentionId: 'call_old:0', eventId: 'old', occurredAt: new Date(Date.now()-700_000).toISOString()});
    expect((await db.query('select id from notification_deliveries')).rows).toEqual([]);
    vi.stubEnv('WATCHR_QUESTION_ALERTS_ENABLED', 'false');
    await ingest({...question, attentionId: 'call_disabled:0'});
    expect((await db.query("select id from question_requests where attention_id='call_disabled:0'")).rows).toEqual([]);
    for (const patch of [{attentionId: null}, {attentionId: 'call_fixture:64'}, {status: 'needs_you'}, {replyPreview: 'PRIVATE'}, {prompt: 'PRIVATE'}]) {
      expect((await ingest({...question, ...patch})).status).toBe(400);
    }
  });
  it('preserves question titles before run discovery and rechecks mute, expiry and review exclusions', async () => {
    const question = event({status: 'working', eventType: 'local/question/opened', attentionId: 'call_fixture:0', eventId: 'question', title: 'Known question title', occurredAt: new Date(Date.now()-6000).toISOString()});
    await ingest(question);
    expect((await db.query('select id from agent_sessions')).rows).toEqual([]);
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_PRIVATE_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_SUBJECT', 'mailto:test@example.com');
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][4]).toBe('Known question title');
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', '');
    await ingest({...question, attentionId: 'call_expired:0'});
    await db.exec("update question_requests set expires_at = now() - interval '1 second' where attention_id='call_expired:0'");
    await ingest({...question, attentionId: 'call_muted:0'});
    await db.exec("update conversation_watches set enabled=false where thread_id='thread'");
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', 'test');
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect((await db.query('select id from notification_deliveries where delivered_at is null')).rows).toEqual([]);
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', '');
    await db.exec("insert into internal_review_threads(thread_id) values ('thread')");
    expect((await ingest({...question, attentionId: 'call_review:0'})).status).toBe(202);
    expect((await db.query("select id from question_requests where attention_id='call_review:0'")).rows).toEqual([]);
  });
  it('supports 32 parent links and preserves visibility beyond that bound', async () => {
    const ids = Array.from({length: 34}, (_, n) => `00000000-0000-4000-8000-${String(n + 1).padStart(12, '0')}`);
    for (const n of [0, 32]) await ingest(event({sessionId: `run-${n}`, threadId: ids[n], eventId: `event-${n}`}));
    const links = ids.slice(0, 32).map((id, n) => ({threadId: id, parentThreadId: ids[n + 1]}));
    const report = (rows: typeof links) => event({sessionId: 'relationships', threadId: null, turnId: null, eventType: 'local/threads/relationships', status: 'stale', threadRelationships: rows});
    expect((await ingest(report(links))).status).toBe(202);
    expect((await db.query('select root_thread_id from conversation_roots where thread_id = $1', [ids[0]])).rows).toEqual([{root_thread_id: ids[32]}]);
    await ingest(event({sessionId: 'run-33', threadId: ids[33], eventId: 'event-33'}));
    expect((await ingest(report([{threadId: ids[32], parentThreadId: ids[33]}]))).status).toBe(202);
    expect((await db.query('select root_thread_id from conversation_roots where thread_id = $1', [ids[0]])).rows).toEqual([{root_thread_id: ids[0]}]);
    expect((await (await handler(request('/sessions'))).json()).sessions).toHaveLength(2);
  });
  it('keeps orphaned and cyclic subtasks visible and regroups when their parent arrives', async () => {
    const ids = Array.from({ length: 5 }, (_, n) => `00000000-0000-4000-8000-${String(n + 1).padStart(12, '0')}`);
    for (const [n, id] of ids.entries()) if (n !== 1) await ingest(event({ sessionId: `run-${n}`, threadId: id, eventId: `e-${n}` }));
    const report = event({ sessionId: 'relationships', threadId: null, turnId: null, eventId: 'links', eventType: 'local/threads/relationships', status: 'stale', threadRelationships: [{ threadId: ids[0], parentThreadId: ids[1] }, { threadId: ids[2], parentThreadId: ids[3] }, { threadId: ids[3], parentThreadId: ids[2] }, { threadId: ids[4], parentThreadId: ids[2] }] });
    expect((await ingest(report)).status).toBe(202);
    const orphan = await (await handler(request('/sessions'))).json();
    expect(orphan.sessions).toHaveLength(4);
    await ingest(event({ sessionId: 'parent', threadId: ids[1], title: 'Renamed parent', status: 'working', eventId: 'parent' }));
    const regrouped = await (await handler(request('/sessions'))).json();
    expect(regrouped.sessions).toHaveLength(4);
    expect(regrouped.groupingRevision).not.toBe(orphan.groupingRevision);
    expect(regrouped.sessions.map((row: {thread_id: string}) => row.thread_id)).not.toContain(ids[0]);
    expect(regrouped.sessions[0].title).toBe('Renamed parent');
    await db.query('delete from conversation_relationships where thread_id = $1', [ids[0]]);
    expect(() => normalizedIngestEvent(event({ threadId: ids[0], parentThreadId: ids[1] }))).not.toThrow();
    expect((await ingest(event({ sessionId: 'run-0-new', turnId: 'resumed-run', threadId: ids[0], parentThreadId: ids[1], eventId: 'resumed', notificationEligible: false }))).status).toBe(202);
    expect((await (await handler(request('/sessions'))).json()).sessions).toHaveLength(4);
  });
  it('groups retained subtasks by parent identity before counts and pagination, preserving their log', async () => {
    const parent = '00000000-0000-4000-8000-000000000001';
    const child = '00000000-0000-4000-8000-000000000002';
    const grandchild = '00000000-0000-4000-8000-000000000003';
    await ingest(event({ sessionId: 'parent-run', threadId: parent, title: 'Project', status: 'working', eventType: 'local/task/started', eventId: 'parent' }));
    await ingest(event({ sessionId: 'child-run', threadId: child, title: 'Project: review', eventId: 'child' }));
    await ingest(event({ sessionId: 'nested-run', threadId: grandchild, title: 'Project: nested review', eventId: 'nested' }));
    // A matching name is never evidence of a relationship.
    for (let n = 0; n < 10; n++) await ingest(event({ sessionId: `independent-${n}`, threadId: `independent-${n}`, title: n === 0 ? 'Project' : `Independent ${n}`, eventId: `independent-${n}` }));
    const before = await (await handler(request('/sessions'))).json();
    const report = event({ sessionId: 'relationships', threadId: null, turnId: null, eventId: 'relationships', eventType: 'local/threads/relationships', status: 'stale', threadRelationships: [{ threadId: child, parentThreadId: parent }, { threadId: grandchild, parentThreadId: child }] });
    expect((await ingest(report)).status).toBe(202);
    expect((await ingest(report)).status).toBe(202);
    const first = await (await handler(request(`/sessions?since=${encodeURIComponent(before.revision)}`))).json();
    expect(first.sessions).toHaveLength(10);
    expect(first.sessions[0]).toMatchObject({ id: 'parent-run', thread_id: parent, status: 'working', title: 'Project' });
    expect(first.counts).toMatchObject({ working: 1, finished: 10 });
    expect(first.groupingRevision).not.toBe(before.groupingRevision);
    const second = await (await handler(request(`/sessions?cursor=${encodeURIComponent(first.nextCursor)}`))).json();
    expect(second.sessions).toHaveLength(1);
    expect(new Set([...first.sessions, ...second.sessions].map((row: {thread_id: string}) => row.thread_id)).size).toBe(11);
    const finished = await (await handler(request('/sessions?status=finished'))).json();
    expect(finished.sessions).toHaveLength(10);
    expect(finished.sessions.every((row: {thread_id: string}) => row.thread_id.startsWith('independent-'))).toBe(true);
    const timeline = await (await handler(request('/sessions/parent-run/events'))).json();
    expect(timeline.events.map((row: {id: string}) => row.id).sort()).toEqual(['child', 'nested', 'parent']);
    expect(timeline.events.find((row: {id: string}) => row.id === 'child').subtask_title).toBe('Project: review');
    expect(mapLiveEvents(timeline).find(row => row.id === 'child')?.label).toContain('Project: review');
    if (process.env.WATCHR_QA_SNAPSHOT_FILE) writeFileSync(process.env.WATCHR_QA_SNAPSHOT_FILE, JSON.stringify({first, second, finished, timeline}));
    expect((await db.query('select id from agent_events')).rows).toHaveLength(13);
    expect((await db.query('select id from notification_deliveries')).rows).toHaveLength(0);
    expect((await handler(request('/events', 'POST', report, { authorization: '' }))).status).toBe(401);
    for (const patch of [{ threadRelationships: [] }, { threadRelationships: [{ threadId: child, parentThreadId: child }] }, { threadRelationships: [{ threadId: child, parentThreadId: parent, prompt: 'SECRET' }] }, { eventType: 'local/task/completed' }]) {
      expect((await ingest({ ...report, ...patch })).status).toBe(400);
    }
  });
  it('repairs retained finished titles without replaying runs or reviving active or expired history', async () => {
    const id = '00000000-0000-4000-8000-000000000001';
    await ingest(event({ sessionId: 'old-child', threadId: id, title: 'Untitled task' }));
    await db.exec('update notification_deliveries set delivered_at = now()');
    expect((await ingest(event({ sessionId: 'active-child', threadId: id, turnId: 'active', title: 'Untitled task', status: 'working', eventId: 'active' }))).status).toBe(202);
    expect((await ingest(event({ sessionId: 'expired-child', threadId: id, turnId: 'expired', title: 'Untitled task', eventId: 'expired' }))).status).toBe(202);
    await db.exec("update agent_sessions set updated_at=now()-interval '31 days' where id='expired-child'");
    const report = event({ sessionId: 'title-repairs', threadId: null, turnId: null, eventId: 'repair', eventType: 'local/threads/titles', status: 'stale', threadTitles: [{ threadId: id, title: 'Project: performance review' }] });
    expect((await ingest(report)).status).toBe(202);
    expect((await ingest(report)).status).toBe(202);
    expect((await db.query('select id, title from agent_sessions order by id')).rows).toEqual([
      { id: 'active-child', title: 'Untitled task' }, { id: 'expired-child', title: 'Untitled task' }, { id: 'old-child', title: 'Project: performance review' },
    ]);
    expect((await db.query('select id from agent_events')).rows).toHaveLength(3);
    expect((await db.query('select id from notification_deliveries where delivered_at is null')).rows).toHaveLength(0);
    expect((await handler(request('/events', 'POST', report, { authorization: '' }))).status).toBe(401);
    for (const patch of [{ threadTitles: [] }, { threadTitles: [{ threadId: id, title: '', prompt: 'SECRET' }] }, { eventType: 'local/task/completed' }, { threadTitles: Array(101).fill({ threadId: id, title: 'Task' }) }]) {
      expect((await ingest({ ...report, ...patch })).status).toBe(400);
    }
  });
  it('preserves a known title across titleless replay and new turns', async () => {
    expect((await ingest(event())).status).toBe(202);
    for (const title of ['Untitled task', 'Codex task', 'Codex task 01a12bfb', 'Codex subagent 01a1298c', 'Subagent 01a1298c']) {
      expect((await ingest(event({ title, eventId: `fallback-${title.replaceAll(' ', '-')}` }))).status).toBe(202);
      expect((await db.query('select title from agent_sessions')).rows).toEqual([{ title: 'Private title' }]);
    }
    await ingest(event({ sessionId: 'thread:turn:next', turnId: 'next', eventId: 'next', title: 'Untitled task' }));
    expect((await handler(request('/sessions')).then(r => r.json())).sessions[0].title).toBe('Private title');
  });
  it('repairs a completed title with the same event identity without adding history or alerts', async () => {
    await ingest(event({ title: 'Untitled task' }));
    await db.exec('update notification_deliveries set delivered_at = now()');
    await ingest(event({ title: 'Project: performance review' }));
    expect((await handler(request('/sessions')).then(r => r.json())).sessions[0].title).toBe('Project: performance review');
    expect((await handler(request('/notifications')).then(r => r.json())).watches[0].session.title).toBe('Project: performance review');
    expect((await db.query('select id from agent_events')).rows).toHaveLength(1);
    expect((await db.query('select id from notification_deliveries where delivered_at is null')).rows).toHaveLength(0);
  });
  it('hides classified reviews from feed, counts, timelines and watches while preserving history', async () => {
    const review = '00000000-0000-4000-8000-000000000001';
    await enableAll();
    await db.query('insert into conversation_watches(thread_id, enabled, enabled_since) values ($1, true, now() - interval \'1 minute\')', [review]);
    await ingest(event({ sessionId: review, threadId: review, eventId: 'review-event', status: 'failed', title: 'Guardian review' }));
    await ingest(event({ title: 'Guardian review' }));
    expect((await db.query('select id from notification_deliveries')).rows).toHaveLength(2);
    const before = await handler(request('/sessions')).then(r => r.json());
    const exclusion = event({ sessionId: 'internal-reviews', threadId: null, turnId: null, eventId: 'exclude-reviews', eventType: 'local/threads/excluded', status: 'stale', excludedThreadIds: [review] });
    expect((await ingest(exclusion)).status).toBe(202);
    expect((await ingest(exclusion)).status).toBe(202);
    expect((await db.query('select thread_id from notification_deliveries')).rows).toEqual([{ thread_id: 'thread' }]);
    const after = await handler(request('/sessions')).then(r => r.json());
    expect(after.sessions).toEqual([expect.objectContaining({ thread_id: 'thread', title: 'Guardian review' })]);
    expect(after.revision).not.toBe(before.revision);
    expect(after.counts.failed).toBe(0);
    expect(after.counts.finished).toBe(1);
    expect(await handler(request(`/sessions/${review}/events`)).then(r => r.json())).toEqual({ events: [] });
    expect((await handler(request('/notifications')).then(r => r.json())).watches.map((w: { thread_id: string }) => w.thread_id)).toEqual(['thread']);
    expect((await handler(request('/notifications/watch', 'PUT', { threadId: review, enabled: true }))).status).toBe(404);
    expect((await db.query('select id from agent_sessions')).rows).toHaveLength(2);
    expect((await db.query('select id from agent_events')).rows).toHaveLength(2);
    expect((await ingest(event({ sessionId: review, threadId: review, eventId: 'late-review' }))).status).toBe(202);
    expect((await db.query('select id from agent_events')).rows).toHaveLength(2);
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_PRIVATE_KEY', 'test'); vi.stubEnv('WATCHR_VAPID_SUBJECT', 'mailto:test@example.com');
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][2]).toBe('finished');
    expect((await db.query('select id from notification_deliveries where thread_id = $1', [review])).rows).toHaveLength(0);
  });
  it('requires authenticated, bounded ID-only exclusion reports', async () => {
    const ids = ['00000000-0000-4000-8000-000000000001'];
    const report = event({ threadId: null, turnId: null, eventType: 'local/threads/excluded', status: 'stale', excludedThreadIds: ids });
    expect((await handler(request('/events', 'POST', report, { authorization: '' }))).status).toBe(401);
    for (const patch of [{ excludedThreadIds: [] }, { excludedThreadIds: ['not-a-uuid'] }, { excludedThreadIds: Array(101).fill(ids[0]) }, { excludedThreadIds: ids, eventType: 'local/task/completed' }, { prompt: 'SECRET' }]) {
      expect((await ingest({ ...report, ...patch })).status).toBe(400);
    }
    expect((await db.query('select * from internal_review_threads')).rows).toHaveLength(0);
  });
  it('keeps expired-history watches visible and allows muting without recreating history', async () => {
    const response = await handler(request('/notifications'));
    expect(response.status).toBe(200);
    const settings = await response.json();
    expect(settings.watches).toEqual([{ thread_id: 'thread', enabled: true, session: null }]);
    expect((await handler(request('/notifications/watch', 'PUT', { threadId: 'thread', enabled: false }))).status).toBe(200);
    expect((await db.query('select enabled from conversation_watches where thread_id = $1', ['thread'])).rows).toEqual([{ enabled: false }]);
    expect((await handler(request('/notifications/watch', 'PUT', { threadId: 'thread', enabled: true }))).status).toBe(404);
  });
  it('returns the latest retained metadata for watches outside the recent feed window', async () => {
    await db.exec("insert into agent_sessions(id, thread_id, turn_id, title, status, last_seen_at, last_event_at) values ('older', 'thread', 'turn-old', 'Old title', 'finished', now() - interval '20 days', now() - interval '20 days'), ('newer', 'thread', 'turn-new', 'Watched older conversation', 'finished', now() - interval '10 days', now() - interval '10 days')");
    const settings = await (await handler(request('/notifications'))).json();
    expect(settings.watches).toHaveLength(1);
    expect(settings.watches[0].session.id).toBe('newer');
    expect(settings.watches[0].session.title).toBe('Watched older conversation');
  });
  const enableAll = async () => {
    expect((await handler(request("/notifications/all", "PUT", { minutes: 15 }))).status).toBe(200);
    // Model activation before the event, without slow wall-clock waits.
    await db.exec("update notification_preferences set all_since = now() - interval '30 seconds'");
  };
  const pushReady = () => {
    vi.stubEnv("WATCHR_VAPID_PUBLIC_KEY", "test"); vi.stubEnv("WATCHR_VAPID_PRIVATE_KEY", "test"); vi.stubEnv("WATCHR_VAPID_SUBJECT", "mailto:test@example.com");
  };
  it("defaults all-alerts off, validates duration and requires authenticated same-origin requests", async () => {
    expect(await handler(request('/notifications')).then(r => r.json())).toMatchObject({ allUntil: null });
    for (const minutes of [-1, 1, 1440, '60', null]) expect((await handler(request('/notifications/all', 'PUT', { minutes }))).status).toBe(400);
    expect((await handler(request('/notifications/all', 'PUT', { minutes: 60 }, { cookie: '' }))).status).toBe(401);
    expect((await handler(request('/notifications/all', 'PUT', { minutes: 60 }, { origin: 'https://attacker.test' }))).status).toBe(403);
    for (const minutes of [15, 60, 240]) {
      expect((await handler(request('/notifications/all', 'PUT', { minutes }))).status).toBe(200);
      const settings = await handler(request('/notifications')).then(r => r.json());
      expect(Date.parse(settings.allUntil) - Date.parse(settings.serverNow)).toBeGreaterThan(minutes * 60_000 - 2000);
    }
  });
  it("covers new conversations, deduplicates overlapping watches, and skips pre-activation history", async () => {
    await enableAll();
    await ingest(event()); await ingest(event({ eventId: 'same-completion' }));
    await ingest(event({ threadId: 'new', sessionId: 'new:turn:run', eventId: 'new' }));
    await ingest(event({ threadId: 'history', sessionId: 'history:turn:run', eventId: 'history', occurredAt: new Date(Date.now() - 60_000).toISOString() }));
    expect((await db.query('select * from notification_deliveries')).rows).toHaveLength(2);
    expect((await db.query('select * from conversation_watches')).rows).toHaveLength(1);
  });
  it("stores a standby-recovered completion without queuing a phone alert", async () => {
    const response = await ingest(event({ notificationEligible: false }));
    expect(response.status).toBe(202);
    expect((await db.query("select status from agent_sessions where id = 'thread:turn:run'")).rows).toEqual([{ status: 'finished' }]);
    expect((await db.query('select id from notification_deliveries')).rows).toHaveLength(0);
  });
  it('persists Always on, keeps finite push TTL, and cancels global jobs without losing watches', async () => {
    expect((await handler(request('/notifications/all', 'PUT', { mode: 'always' }))).status).toBe(200);
    expect(await handler(request('/notifications')).then(r => r.json())).toMatchObject({ allAlways: true, allUntil: null });
    await db.exec("update notification_preferences set all_since = now() - interval '30 seconds'");
    await ingest(event({ threadId: 'new', sessionId: 'new:turn:run', eventId: 'new' }));
    await ingest(event({ threadId: 'old', sessionId: 'old:turn:run', eventId: 'old', occurredAt: new Date(Date.now() - 60_000).toISOString() }));
    pushReady(); const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1); expect(send.mock.calls[0][3]).toBe(3600);
    vi.stubEnv('WATCHR_VAPID_PUBLIC_KEY', '');
    await ingest(event());
    await ingest(event({ threadId: 'another', sessionId: 'another:turn:run', eventId: 'another' }));
    expect((await handler(request('/notifications/all', 'PUT', { minutes: 0 }))).status).toBe(200);
    expect(await handler(request('/notifications')).then(r => r.json())).toMatchObject({ allAlways: false, allUntil: null });
    expect((await db.query('select thread_id from notification_deliveries where delivered_at is null')).rows).toEqual([{ thread_id: 'thread' }]);
  });
  it('accepts a bounded midnight deadline, rejects malformed modes, and can switch away from Always on', async () => {
    for (const body of [{ mode: 'unknown' }, { mode: 'always', minutes: 60 }, { mode: 'midnight', until: 'infinity' }, { mode: 'midnight', until: new Date(Date.now() - 1000).toISOString() }, { mode: 'midnight', until: new Date(Date.now() + 27 * 3600_000).toISOString() }]) {
      expect((await handler(request('/notifications/all', 'PUT', body))).status).toBe(400);
    }
    await handler(request('/notifications/all', 'PUT', { mode: 'always' }));
    const until = new Date(Date.now() + 25 * 3600_000).toISOString();
    expect((await handler(request('/notifications/all', 'PUT', { mode: 'midnight', until }))).status).toBe(200);
    const settings = await handler(request('/notifications')).then(r => r.json());
    expect(settings.allAlways).toBe(false); expect(Date.parse(settings.allUntil)).toBe(Date.parse(until));
    await db.exec("update notification_preferences set all_since = now() - interval '2 days', all_until = now() - interval '1 second'");
    expect((await db.query("select notification_allowed('unwatched', now()) as allowed")).rows).toEqual([{ allowed: false }]);
  });
  it("stops global queued deliveries on cancellation but preserves individual watches and their jobs", async () => {
    await enableAll(); await ingest(event());
    await ingest(event({ threadId: 'new', sessionId: 'new:turn:run', eventId: 'new' }));
    await handler(request('/notifications/all', 'PUT', { minutes: 0 }));
    expect((await db.query('select thread_id from notification_deliveries')).rows).toEqual([{ thread_id: 'thread' }]);
    expect((await db.query('select enabled from conversation_watches')).rows).toEqual([{ enabled: true }]);
  });
  it("enforces expiry at dispatch and does not revive old global jobs on reactivation", async () => {
    await enableAll(); await ingest(event());
    await ingest(event({ threadId: 'new', sessionId: 'new:turn:run', eventId: 'new' }));
    await db.exec("update notification_preferences set all_since = now() - interval '1 hour', all_until = now() - interval '1 second'");
    await handler(request('/notifications/all', 'PUT', { minutes: 60 }));
    pushReady(); const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect((await db.query('select thread_id from notification_deliveries')).rows).toEqual([{ thread_id: 'thread' }]);
  });
  it("does not dispatch an expired global-only job even when the browser never reconnects", async () => {
    await enableAll();
    await ingest(event({ threadId: 'new', sessionId: 'new:turn:run', eventId: 'new' }));
    await db.exec("update notification_preferences set all_since = now() - interval '1 hour', all_until = now() - interval '1 second'");
    pushReady(); const send = vi.fn(); await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();
    expect((await db.query('select * from notification_deliveries')).rows).toHaveLength(0);
  });
  it("keeps temporary coverage after muting one conversation and limits provider TTL to the window", async () => {
    await enableAll(); await ingest(event());
    await handler(request('/notifications/watch', 'PUT', { threadId: 'thread', enabled: false }));
    expect((await db.query('select * from notification_deliveries')).rows).toHaveLength(1);
    pushReady(); const send = vi.fn().mockResolvedValue(undefined); await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][3]).toBeGreaterThan(0);
    expect(send.mock.calls[0][3]).toBeLessThanOrEqual(900);
  });
  it("atomically ingests, deduplicates recovery versus hook completion, and stores generic text", async () => {
    const first = await ingest(event({ detail: "SECRET_SENTINEL" }));
    expect(first.status).toBe(202);
    expect(await ingest(event()).then((response) => response.json())).toMatchObject({ duplicate: true });
    expect((await ingest(event({ eventId: "hook", eventType: "codex/hook/Stop" }))).status).toBe(202);
    expect((await db.query("select * from notification_deliveries")).rows).toHaveLength(1);
    expect(JSON.stringify((await db.query("select * from agent_events")).rows)).not.toContain("SECRET_SENTINEL");
  });
  it("keeps a bounded final reply only in the pending delivery and upgrades a duplicate before dispatch", async () => {
    expect((await ingest(event())).status).toBe(202);
    expect((await db.query<{ reply_preview: string | null }>("select reply_preview from notification_deliveries")).rows[0].reply_preview).toBeNull();
    expect((await ingest(event({ eventId: "same-run-with-reply", replyPreview: "A concise final answer." }))).status).toBe(202);
    expect((await db.query<{ reply_preview: string | null }>("select reply_preview from notification_deliveries")).rows[0].reply_preview).toBe("A concise final answer.");
    expect(JSON.stringify((await db.query("select * from agent_sessions")).rows)).not.toContain("A concise final answer.");
    expect(JSON.stringify((await db.query("select * from agent_events")).rows)).not.toContain("A concise final answer.");
    pushReady(); const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send.mock.calls[0][5]).toBe("A concise final answer.");
    expect((await db.query<{ reply_preview: string | null }>("select reply_preview from notification_deliveries")).rows[0].reply_preview).toBeNull();
  });
  it("does not replay older state over a completion, even with a new observation timestamp", async () => {
    await ingest(event());
    await ingest(event({ eventId: "old", status: "working", occurredAt: new Date(Date.now() - 60_000).toISOString(), observedAt: new Date().toISOString() }));
    expect((await db.query<{ status: string }>("select status from agent_sessions")).rows[0].status).toBe("finished");
  });
  it("keeps a newer run selected when an older run is observed later", async () => {
    await ingest(event({ sessionId: "thread:turn:new", turnId: "new", status: "working", observedAt: new Date(Date.now() - 1000).toISOString() }));
    await ingest(event({ eventId: "older", occurredAt: new Date(Date.now() - 60_000).toISOString(), observedAt: new Date().toISOString() }));
    const response = await handler(request("/sessions"));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ sessions: [{ id: "thread:turn:new", status: "working" }] });
  });
  it("does not reopen a terminal run from a delayed hook received after completion", async () => {
    await ingest(event());
    await ingest(event({ eventId: "delayed-hook", status: "needs_you", attentionId: "late", occurredAt: new Date().toISOString() }));
    expect((await db.query<{ status: string }>("select status from agent_sessions")).rows[0].status).toBe("finished");
    expect((await db.query("select * from notification_deliveries")).rows).toHaveLength(1);
  });
  it("gives each request one attention alert and each future run its own completion", async () => {
    await ingest(event({ status: "needs_you", attentionId: "request-1" }));
    await ingest(event({ status: "needs_you", attentionId: "request-1", eventId: "duplicate" }));
    await ingest(event({ status: "needs_you", attentionId: "request-2", eventId: "another" }));
    await ingest(event({ eventId: "finished" }));
    await ingest(event({ sessionId: "thread:turn:next", turnId: "next", eventId: "next" }));
    expect((await db.query("select * from notification_deliveries")).rows).toHaveLength(4);
  });
  it("drops a queued completion when the conversation has started a newer run", async () => {
    await ingest(event());
    await ingest(event({ sessionId: "thread:turn:next", turnId: "next", eventId: "next-started", status: "working", occurredAt: new Date().toISOString() }));
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();
    expect((await db.query("select id from notification_deliveries")).rows).toHaveLength(0);
  });
  it("drops an old queued completion when its follow-up starts in the same source second", async () => {
    const transition = sourceTime();
    await ingest(event({ occurredAt: transition }));
    await ingest(event({ sessionId: "thread:turn:next", turnId: "next", eventId: "same-second-start", status: "working", occurredAt: transition }));
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();
    expect((await db.query("select id from notification_deliveries")).rows).toHaveLength(0);
  });
  it("drops a delayed Stop completion even when the next run started before that Stop timestamp", async () => {
    const startedAt = new Date(Date.now() - 60_000).toISOString();
    await ingest(event({ eventId: "old-start", status: "working", occurredAt: startedAt }));
    await ingest(event({ sessionId: "thread:turn:next", turnId: "next", eventId: "next-start", status: "working", occurredAt: new Date(Date.now() - 10_000).toISOString() }));
    await ingest(event({ eventId: "late-stop", occurredAt: sourceTime() }));
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();
  });
  it("keeps an idle zero-duration completion eligible rather than superseding itself", async () => {
    await ingest(event()); // Ingestion has only this completion, so start and finish share a timestamp.
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
  });
  it("drops a late completion with no recovered start using Codex run identity", async () => {
    const oldTurn = "01900000-0000-7000-8000-000000000002";
    const nextTurn = "01900000-0001-7000-8000-000000000001";
    await ingest(event({ sessionId: `thread:turn:${nextTurn}`, turnId: nextTurn, eventId: "uuid-next", status: "working", occurredAt: new Date(Date.now() - 10_000).toISOString() }));
    await ingest(event({ sessionId: `thread:turn:${oldTurn}`, turnId: oldTurn, eventId: "uuid-late-stop" }));
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();
  });
  it("sends only the latest Codex completion when both runs finish in the same source second", async () => {
    const transition = sourceTime();
    const oldTurn = "01900000-0000-7000-8000-000000000002";
    const nextTurn = "01900000-0001-7000-8000-000000000001";
    await ingest(event({ sessionId: `thread:turn:${oldTurn}`, turnId: oldTurn, eventId: "uuid-old-finished", occurredAt: transition }));
    const latest = event({ sessionId: `thread:turn:${nextTurn}`, turnId: nextTurn, eventId: "uuid-next-finished", occurredAt: transition });
    await ingest(latest);
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][1]).toBe(`${notificationIdentity(latest)}:device`);
  });
  it("uses precise source starts when UUID timestamps tie rather than ordering their random tails", async () => {
    const base = Math.floor(Date.now() / 1000) * 1000 - 2000;
    const oldTurn = "01900000-0000-7000-8000-000000000002";
    const nextTurn = "01900000-0000-7000-8000-000000000001";
    await ingest(event({ sessionId: `thread:turn:${oldTurn}`, turnId: oldTurn, eventId: "tied-old-start", status: "working", occurredAt: new Date(base + 100).toISOString() }));
    await ingest(event({ sessionId: `thread:turn:${nextTurn}`, turnId: nextTurn, eventId: "tied-next-start", status: "working", occurredAt: new Date(base + 200).toISOString() }));
    await ingest(event({ sessionId: `thread:turn:${oldTurn}`, turnId: oldTurn, eventId: "tied-old-stop", occurredAt: new Date(base + 300).toISOString() }));
    const latest = event({ sessionId: `thread:turn:${nextTurn}`, turnId: nextTurn, eventId: "tied-next-stop", occurredAt: new Date(base + 400).toISOString() });
    await ingest(latest);
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][1]).toBe(`${notificationIdentity(latest)}:device`);
  });
  it("sends only the latest completion when the follow-up also finished before delivery", async () => {
    await ingest(event());
    const latest = event({ sessionId: "thread:turn:next", turnId: "next", eventId: "next-finished", occurredAt: new Date().toISOString() });
    await ingest(latest);
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][1]).toBe(`${notificationIdentity(latest)}:device`);
  });
  it("keeps a completion eligible when only an older run is recovered later", async () => {
    await ingest(event());
    await ingest(event({ sessionId: "thread:turn:old", turnId: "old", eventId: "old-recovered", status: "working", occurredAt: new Date(Date.now() - 60_000).toISOString(), observedAt: new Date().toISOString() }));
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
  });
  it("does not push a transient approval that resolves while auto-approval continues the run", async () => {
    const requestedAt = new Date(Date.now() - 3000).toISOString();
    const response = await ingest(event({
      status: "needs_you", eventId: "approval-request", eventType: "codex/hook/PermissionRequest",
      attentionId: "request-1", occurredAt: requestedAt,
    }));
    expect(response.status).toBe(202);

    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();

    await ingest(event({ status: "working", eventId: "approval-resolved", eventType: "local/attention/resolved" }));
    await db.exec("update notification_deliveries set next_attempt_at = now()");
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();
    expect((await db.query("select id from notification_deliveries")).rows).toHaveLength(0);
  });
  it("sends an attention alert once when the request remains unresolved", async () => {
    await ingest(event({ status: "needs_you", eventId: "approval-request", attentionId: "request-1" }));
    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).not.toHaveBeenCalled();

    await db.exec("update notification_deliveries set next_attempt_at = now()");
    await drainNotifications(sql as unknown as SQL, send);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][2]).toBe("needs_you");
  });
  it("does not send an old request after a newer request replaces it", async () => {
    await ingest(event({ status: "needs_you", eventId: "first-request", attentionId: "request-1", occurredAt: new Date(Date.now() - 3000).toISOString() }));
    await ingest(event({ status: "working", eventId: "first-resolved", eventType: "local/attention/resolved", occurredAt: new Date(Date.now() - 2000).toISOString() }));
    const second = event({ status: "needs_you", eventId: "second-request", attentionId: "request-2", occurredAt: new Date(Date.now() - 1000).toISOString() });
    await ingest(second);

    pushReady();
    const send = vi.fn().mockResolvedValue(undefined);
    await db.exec("update notification_deliveries set next_attempt_at = now()");
    await drainNotifications(sql as unknown as SQL, send);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][1]).toBe(`${notificationIdentity(second)}:device`);
    expect((await db.query("select kind from notification_deliveries where delivered_at is null")).rows).toHaveLength(0);
  });
  it("does not alert on history, pre-watch activity, or unwatched conversations", async () => {
    await ingest(event({ occurredAt: new Date(Date.now() - 700_000).toISOString() }));
    await db.exec("update conversation_watches set enabled_since = now()");
    await ingest(event({ eventId: "recent-before-watch" }));
    await db.exec("update conversation_watches set enabled = false");
    await ingest(event({ eventId: "muted", occurredAt: new Date().toISOString() }));
    expect((await db.query("select * from notification_deliveries")).rows).toHaveLength(0);
  });
  it("requires authentication and same-origin mutations, including malformed cookie handling", async () => {
    expect((await handler(request("/notifications", "GET", undefined, { cookie: "" }))).status).toBe(401);
    expect((await handler(request("/notifications", "GET", undefined, { cookie: "status_watchr_session=%ZZ" }))).status).toBe(401);
    expect((await handler(request("/notifications/watch", "PUT", { threadId: "thread", enabled: true }, { origin: "https://attacker.test" }))).status).toBe(403);
    expect((await handler(request("/events", "POST", event(), { authorization: "Bearer revoked" }))).status).toBe(401);
  });
  it("mutes queued deliveries and revokes subscriptions with cascading deletion", async () => {
    await ingest(event());
    expect((await handler(request("/notifications/watch", "PUT", { threadId: "thread", enabled: false }))).status).toBe(200);
    expect((await db.query("select * from notification_deliveries")).rows).toHaveLength(0);
    expect((await handler(request("/notifications/unsubscribe", "POST", { id: "device" }))).status).toBe(200);
    expect((await db.query("select * from push_subscriptions")).rows).toHaveLength(0);
  });
  it("rejects malformed events without storing sensitive fields", async () => {
    expect((await ingest(event({ prompt: "secret" }))).status).toBe(400);
    expect((await ingest(event({ status: "invalid" }))).status).toBe(400);
    expect((await db.query("select * from agent_events")).rows).toHaveLength(0);
  });
  it("retries transient push failures, marks accepted delivery, and revokes gone devices", async () => {
    await ingest(event());
    vi.stubEnv("WATCHR_VAPID_PUBLIC_KEY", "test"); vi.stubEnv("WATCHR_VAPID_PRIVATE_KEY", "test"); vi.stubEnv("WATCHR_VAPID_SUBJECT", "mailto:test@example.com");
    const send = vi.fn().mockRejectedValueOnce({ statusCode: 503, body: "SECRET_ENDPOINT" }).mockResolvedValue(undefined);
    await drainNotifications(sql as unknown as SQL, send);
    expect(send.mock.calls[0][4]).toBe("Private title");
    expect((await db.query<{ attempts: number }>("select attempts from notification_deliveries")).rows[0].attempts).toBe(1);
    await db.exec("update notification_deliveries set next_attempt_at = now()");
    await drainNotifications(sql as unknown as SQL, send);
    expect((await db.query<{ delivered_at: string }>("select delivered_at from notification_deliveries")).rows[0].delivered_at).toBeTruthy();
    await db.exec("update notification_deliveries set delivered_at = null, next_attempt_at = now()");
    await drainNotifications(sql as unknown as SQL, vi.fn().mockRejectedValue({ statusCode: 410 }));
    expect((await db.query("select * from push_subscriptions")).rows).toHaveLength(0);
  });
  it("physically expires retained event/session history", async () => {
    await ingest(event({ occurredAt: new Date(Date.now() - 31 * 86_400_000).toISOString() }));
    await maintenance();
    expect((await db.query("select * from agent_events")).rows).toHaveLength(0);
    expect((await db.query("select * from agent_sessions")).rows).toHaveLength(0);
  });
  it('retains review exclusions through stored history and the offline replay grace period', async () => {
    await ingest(event());
    await db.exec("insert into internal_review_threads(thread_id, reported_at) values ('thread', now() - interval '38 days'), ('expired-orphan', now() - interval '38 days'), ('recent-orphan', now() - interval '36 days')");
    await db.exec("insert into conversation_relationships(thread_id, parent_thread_id, reported_at) values ('thread', 'parent', now()-interval '38 days'), ('parent', 'grandparent', now()-interval '38 days'), ('expired', 'missing', now()-interval '38 days'), ('recent', 'missing', now()-interval '36 days')");
    await maintenance();
    expect((await db.query('select thread_id from internal_review_threads order by thread_id')).rows).toEqual([{ thread_id: 'recent-orphan' }, { thread_id: 'thread' }]);
    expect((await db.query('select thread_id from conversation_relationships order by thread_id')).rows).toEqual([{thread_id: 'parent'}, {thread_id: 'recent'}, {thread_id: 'thread'}]);
  });
});
