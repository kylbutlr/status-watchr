import { randomUUID } from 'node:crypto';
import { getStore } from '@netlify/blobs';
import { drainNotifications, sendPush, type SQL } from './notifications.js';

type Wake = { key: string; notificationId: string; dueAt: number };
const store = () => getStore({ name: 'watchr-notification-wakes-v1', consistency: 'strong' });
const prefix = 'wakes/';
const pendingQuery = (sql: SQL, notificationId: string | null) => sql`
  select split_part(id, ':', 1) as notification_id,
    min(greatest(next_attempt_at, coalesce(lease_until, next_attempt_at))) as next_at
  from notification_deliveries
  where delivered_at is null and expires_at > now() and attempts < 8
    and (${notificationId}::text is null or split_part(id, ':', 1) = ${notificationId})
  group by split_part(id, ':', 1)
`;

// A distinct receipt belongs to this invocation. Clearing it cannot erase a concurrent producer's wake.
// Persist before the SQL transaction. A killed request is recovered after the synchronous API's
// execution window, even if it committed before it could finish bookkeeping.
export async function prepareNotificationWake(notificationId: string): Promise<Wake> {
  const wake = { key: `${prefix}${randomUUID()}`, notificationId, dueAt: Date.now() + 120_000 };
  await store().setJSON(wake.key, wake);
  return wake;
}

export async function settleNotificationWake(sql: SQL, wake: Wake) {
  const pending = await pendingQuery(sql, wake.notificationId);
  if (!pending.length) {
    await store().delete(wake.key);
  } else {
    const dueAt = new Date(String(pending[0].next_at)).getTime();
    await store().setJSON(wake.key, { ...wake, dueAt: Math.max(Date.now() + 1_000, dueAt) });
  }
}

// One bootstrap recovers jobs created by the previous deployment, which had no wake receipts.
// If it fails, do not mark it complete. The next tick retries without losing existing jobs.
async function recoverLegacyJobs(sql: SQL) {
  const pending = await pendingQuery(sql, null);
  for (const row of pending) {
    const wake = await prepareNotificationWake(String(row.notification_id));
    await store().setJSON(wake.key, { ...wake, dueAt: new Date(String(row.next_at)).getTime() });
  }
  await store().setJSON('initialized', true);
}

export async function retryNotificationWakes(database: () => SQL, send = sendPush) {
  const blobs = store();
  let sql: SQL | undefined;
  if (!await blobs.get('initialized', { type: 'json' })) {
    sql = database();
    await recoverLegacyJobs(sql);
  }
  let processed = 0;
  for await (const page of blobs.list({ prefix, paginate: true })) {
    for (const { key } of page.blobs) {
      const wake = await blobs.get(key, { type: 'json' }) as Wake | null;
      if (!wake || wake.dueAt > Date.now()) continue;
      sql ??= database();
      await drainNotifications(sql, send, wake.notificationId);
      await settleNotificationWake(sql, { ...wake, key });
      if (++processed >= 50) return;
    }
  }
}
