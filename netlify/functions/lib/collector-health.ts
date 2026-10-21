import { getStore } from '@netlify/blobs';
import type { CollectorHealth } from '../../../src/collector-health.js';

const store = () => getStore({ name: 'watchr-collector-health-v1', consistency: 'strong' });

export async function saveCollectorHealth(body: Record<string, unknown>) {
  await store().setJSON('mac', {
    source_available: body.sourceAvailable,
    hook_trust: body.hookTrust,
    queued: body.queued,
    last_hook_at: typeof body.lastHookAt === 'string' ? body.lastHookAt : null,
    received_at: new Date().toISOString(),
  });
}

export async function loadCollectorHealth(): Promise<CollectorHealth | null> {
  return await store().get('mac', { type: 'json' }) as CollectorHealth | null;
}
