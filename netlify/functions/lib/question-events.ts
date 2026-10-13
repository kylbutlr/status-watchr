import { digest, type SQL } from './notifications.js';

export function questionIdentity(body: Record<string, unknown>) {
  return digest(JSON.stringify([body.threadId, body.attentionId]));
}

export async function ingestQuestion(sql: SQL, body: Record<string, unknown>, now = Date.now()) {
  const id = questionIdentity(body);
  const resolved = body.eventType === 'local/question/answered';
  const occurred = Date.parse(String(body.occurredAt));
  const eligible = !resolved && body.notificationEligible !== false &&
    Number.isFinite(occurred) && now - occurred <= 600_000 && occurred <= now + 60_000;
  await sql.transaction([
    sql`insert into question_requests(id, thread_id, attention_id, turn_id, title, opened_at, resolved_at, expires_at)
      values (${id}, ${body.threadId}, ${body.attentionId}, ${body.turnId}, ${body.title},
        ${resolved ? null : body.occurredAt}::timestamptz, ${resolved ? body.occurredAt : null}::timestamptz,
        ${body.occurredAt}::timestamptz + interval '1 hour')
      on conflict(id) do update set
        opened_at = coalesce(question_requests.opened_at, excluded.opened_at),
        resolved_at = coalesce(question_requests.resolved_at, excluded.resolved_at)`,
    // Answers arriving before opens create tombstones, so delayed/retried opens stay quiet.
    sql`delete from notification_deliveries where question_request_id = ${id}
      and delivered_at is null and exists(select 1 from question_requests where id = ${id} and resolved_at is not null)`,
    sql`insert into notification_deliveries(id, thread_id, kind, subscription_id, event_occurred_at, question_request_id, next_attempt_at)
      select ${id} || ':' || subscription.id, ${body.threadId}, 'question', subscription.id,
        ${body.occurredAt}::timestamptz, ${id}, greatest(now(), ${body.occurredAt}::timestamptz + interval '5 seconds')
      from push_subscriptions subscription
      where ${eligible} and notification_allowed(${body.threadId}, ${body.occurredAt}::timestamptz)
        and subscription.created_at <= ${body.occurredAt}::timestamptz
        and not exists(select 1 from internal_review_threads where thread_id = lower(${body.threadId}))
        and exists(select 1 from question_requests where id = ${id} and resolved_at is null and expires_at > now())
      on conflict(id) do nothing`
  ]);
}
