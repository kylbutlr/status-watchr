import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const mock = vi.hoisted(() => ({
  open: vi.fn(),
  records: new Map<string, unknown>(),
}));
vi.mock('@neondatabase/serverless', () => ({ neon: mock.open }));
vi.mock('@netlify/blobs', () => ({ getStore: () => ({
  get: async (key: string) => mock.records.get(key) ?? null,
  setJSON: async (key: string, value: unknown) => { mock.records.set(key, value); },
  delete: async (key: string) => { mock.records.delete(key); },
  list: async function* ({ prefix = '' } = {}) { yield { blobs: [...mock.records.keys()].filter(key => key.startsWith(prefix)).map(key => ({ key })) }; },
}) }));

import retry from '../netlify/functions/notification-retry.mts';
import handler from '../netlify/functions/api.mts';
import { createSessionValue } from '../netlify/functions/lib/auth';

beforeEach(() => {
  mock.records.clear();
  mock.records.set('initialized', true);
  mock.open.mockReturnValue(vi.fn(async () => []));
  vi.stubEnv('DATABASE_URL', 'postgres://unused');
  vi.stubEnv('APP_SWITCHR_URL', '');
  vi.stubEnv('APP_SWITCHR_READER_TOKEN', '');
  vi.stubEnv('WATCHR_SESSION_SECRET', 'test-session-secret');
  vi.stubEnv('WATCHR_INGEST_TOKEN', 'ingest-test');
});
afterEach(() => { vi.unstubAllEnvs(); vi.clearAllMocks(); });

it('does not open Neon for an empty notification retry tick', async () => {
  await retry();
  expect(mock.open).not.toHaveBeenCalled();
});

it('stores and reads authenticated Mac check-ins without opening Neon', async () => {
  const response = await handler(new Request('https://watchr.test/api/collector', {
    method: 'POST', headers: { authorization: 'Bearer ingest-test' },
    body: JSON.stringify({ sourceAvailable: true, hookTrust: 'trusted', queued: 0 }),
  }));
  expect(response.status).toBe(202);
  const read = await handler(new Request('https://watchr.test/api/collector', {
    headers: { cookie: `status_watchr_session=${createSessionValue()}` },
  }));
  expect(read.status).toBe(200);
  expect((await read.json()).collector).toMatchObject({ source_available: true, queued: 0 });
  expect(mock.open).not.toHaveBeenCalled();
});

it('rejects unauthenticated health reads and writes before storage or Neon', async () => {
  expect((await handler(new Request('https://watchr.test/api/collector'))).status).toBe(401);
  expect((await handler(new Request('https://watchr.test/api/collector', { method: 'POST', body: '{}' }))).status).toBe(401);
  expect(mock.open).not.toHaveBeenCalled();
  expect(mock.records.size).toBe(1); // Only the initialized retry-state fixture.
});
