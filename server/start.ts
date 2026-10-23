import { createServer } from 'node:http';
import { open, unlink } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { configuration } from './config.js';
import { localDatabase } from './database.js';
import { application } from './application.js';
import { createHandler } from '../netlify/functions/api.mjs';
import { hasValidSession } from '../netlify/functions/lib/auth.js';
import { runRetention } from '../netlify/functions/retention-scheduled.mjs';
import { retryNotificationWakes } from '../netlify/functions/lib/notification-wakes.js';
import { sendPush } from '../netlify/functions/lib/notifications.js';

async function main() {
  const config = await configuration();
  const lockPath = join(config.directory, 'server.lock');
  const lock = await open(lockPath, 'wx', 0o600).catch(() => { throw new Error('This data directory is locked. Stop its existing server before reusing it.'); });
  let database: Awaited<ReturnType<typeof localDatabase>> | undefined;
  let stopping = false;
  let stopServer: (() => void) | undefined;
  const stop = () => { stopping = true; stopServer?.(); };
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  try {
    await lock.writeFile(String(process.pid));
    database = await localDatabase(join(config.directory, 'database'), resolve('database/migrations'));
    if (stopping) return;
    const sql = database.sql;
    const api = createHandler({ database: () => sql, databaseConfigured: true, hasSession: (request) => config.authMode === 'none' || hasValidSession(request), secureCookies: config.secure });
    const server = createServer(application({ origin: config.origin, assets: resolve('dist'), api }));
    server.requestTimeout = 20_000; server.headersTimeout = 15_000;
    let active = false, retainedAt = Date.now();
    const send: typeof sendPush = async (...args) => { if (stopping) throw new Error('Server stopping; retain the pending delivery.'); await sendPush(...args); };
    const retry = async () => {
      if (active || stopping) return;
      active = true;
      try {
        await retryNotificationWakes(() => sql, send);
        if (!stopping && Date.now() - retainedAt >= 6 * 60 * 60_000) { await runRetention(sql); retainedAt = Date.now(); }
      } catch { console.error('Notification retry is unavailable; pending receipts are retained.'); }
      finally { active = false; }
    };
    await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(config.port, '127.0.0.1', resolve); });
    const timer = setInterval(() => { void retry(); }, 10_000);
    console.log(`Status Watchr: ${config.origin}\n${config.authMode === 'none' ? 'Local access without a password.' : 'Password-protected dashboard.'}\nNative pairing token: ${join(config.directory, 'server-secrets.json')} (ingestToken).\nCtrl+C stops this server.`);
    await new Promise<void>((resolve) => {
      let closing = false;
      stopServer = () => { if (closing) return; closing = true; clearInterval(timer); server.close(() => resolve()); server.closeIdleConnections(); };
      if (stopping) stopServer();
    });
    while (active) await new Promise((resolve) => setTimeout(resolve, 25));
  } finally {
    process.removeListener('SIGINT', stop); process.removeListener('SIGTERM', stop);
    await database?.close(); await lock.close(); await unlink(lockPath);
  }
}
await main();
