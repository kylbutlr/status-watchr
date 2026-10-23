import { afterEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { localDatabase } from '../server/database';
import { watchrStore } from '../netlify/functions/lib/runtime-store';
import { createHandler } from '../netlify/functions/api.mts';

const directories: string[] = [];
afterEach(async () => { vi.unstubAllEnvs(); for (const dir of directories.splice(0)) await rm(dir, { recursive: true, force: true }); });
async function folder() { const dir = await mkdtemp(join(tmpdir(), 'watchr-public-test-')); directories.push(dir); return dir; }

describe('standalone persistence and authentication', () => {
  it('tracks migrations and preserves data when the embedded database reopens', async () => {
    const path = join(await folder(), 'database');
    let db = await localDatabase(path, resolve('database/migrations'));
    await db.sql`insert into conversation_watches(thread_id, enabled) values ('fictional-conversation', true)`;
    await db.close();
    db = await localDatabase(path, resolve('database/migrations'));
    try {
      expect((await db.sql`select thread_id from conversation_watches`)[0].thread_id).toBe('fictional-conversation');
      expect(Number((await db.sql`select count(*) as count from watchr_schema_migrations`)[0].count)).toBe(9);
    } finally { await db.close(); }
  }, 120_000);

  it('retains retry receipts locally with owner-only file permissions', async () => {
    const dir = await folder(); vi.stubEnv('WATCHR_RUNTIME', 'standalone'); vi.stubEnv('WATCHR_DATA_DIR', dir);
    const store = watchrStore('public-test');
    await store.setJSON('wakes/fictional', { dueAt: 100, notificationId: 'example' });
    const reopened = watchrStore('public-test');
    expect(await reopened.get('wakes/fictional', { type: 'json' })).toEqual({ dueAt: 100, notificationId: 'example' });
    expect((await stat(join(dir, 'receipts/public-test', Buffer.from('wakes/fictional').toString('base64url') + '.json'))).mode & 0o777).toBe(0o600);
    await reopened.delete('wakes/fictional');
    expect(await store.get('wakes/fictional', { type: 'json' })).toBeNull();
  });

  it('does not let standalone environment variables bypass hosted-handler authentication', async () => {
    vi.stubEnv('WATCHR_AUTH_MODE', 'none'); vi.stubEnv('WATCHR_RUNTIME', 'standalone'); vi.stubEnv('WATCHR_SESSION_SECRET', '');
    const hosted = createHandler();
    const response = await hosted(new Request('https://watchr.example/api/work-state'));
    expect(response.status).toBe(401);
    const local = createHandler({ hasSession: () => true, secureCookies: false });
    expect((await (await local(new Request('http://127.0.0.1:4288/api/auth/session'))).json()).authenticated).toBe(true);
    // Dashboard passwordless access cannot authorize native ingestion.
    expect((await local(new Request('http://127.0.0.1:4288/api/events', { method: 'POST', body: '{}' }))).status).toBe(401);
  });
});
