import { existsSync } from 'node:fs';
import { loadEnvFile } from 'node:process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { randomBytes } from 'node:crypto';
import webpush from 'web-push';

export async function configuration() {
  if (process.env.WATCHR_LOAD_ENV !== 'false' && existsSync('.env')) loadEnvFile('.env');
  const port = Number(process.env.WATCHR_PORT || 4288);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('WATCHR_PORT must be between 1024 and 65535.');
  const origin = process.env.WATCHR_ORIGIN || `http://127.0.0.1:${port}`;
  const parsed = new URL(origin);
  const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(parsed.hostname);
  if (parsed.origin !== origin || parsed.username || parsed.password || !(parsed.protocol === 'https:' || parsed.protocol === 'http:' && loopback)) throw new Error('Use an exact HTTPS origin, or HTTP on loopback.');
  const authMode = process.env.WATCHR_AUTH_MODE || 'password';
  if (!['password', 'none'].includes(authMode)) throw new Error('WATCHR_AUTH_MODE must be password or none.');
  if (authMode === 'none' && !loopback) throw new Error('Passwordless access is loopback-only. Use a password for a remote HTTPS origin.');
  const password = process.env.WATCHR_ACCESS_PASSWORD?.trim() || '';
  if (authMode === 'password' && (password.length < 16 || password.length > 256)) throw new Error('Set a password of 16 to 256 characters, or explicitly choose WATCHR_AUTH_MODE=none for local use.');
  if (authMode === 'none' && password) throw new Error('Remove WATCHR_ACCESS_PASSWORD or choose WATCHR_AUTH_MODE=password.');
  const directory = resolve(process.env.WATCHR_DATA_DIR || 'data');
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, 'server-secrets.json');
  let secrets: { sessionSecret: string; ingestToken: string; vapidPublicKey: string; vapidPrivateKey: string };
  try { secrets = JSON.parse(await readFile(path, 'utf8')); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw new Error('Local secrets could not be read. Preserve the data directory and inspect its configuration.');
    const keys = webpush.generateVAPIDKeys();
    secrets = { sessionSecret: randomBytes(32).toString('base64url'), ingestToken: randomBytes(32).toString('base64url'), vapidPublicKey: keys.publicKey, vapidPrivateKey: keys.privateKey };
    await writeFile(path, JSON.stringify(secrets, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  }
  if (!secrets.sessionSecret || !secrets.ingestToken || !secrets.vapidPublicKey || !secrets.vapidPrivateKey) throw new Error('Local secrets are incomplete. Preserve the data directory before repairing it.');
  process.env.WATCHR_RUNTIME = 'standalone';
  process.env.WATCHR_DATA_DIR = directory;
  process.env.WATCHR_SESSION_SECRET = process.env.WATCHR_SESSION_SECRET?.trim() || secrets.sessionSecret;
  process.env.WATCHR_INGEST_TOKEN = process.env.WATCHR_INGEST_TOKEN?.trim() || secrets.ingestToken;
  process.env.WATCHR_VAPID_PUBLIC_KEY = process.env.WATCHR_VAPID_PUBLIC_KEY?.trim() || secrets.vapidPublicKey;
  process.env.WATCHR_VAPID_PRIVATE_KEY = process.env.WATCHR_VAPID_PRIVATE_KEY?.trim() || secrets.vapidPrivateKey;
  process.env.WATCHR_VAPID_SUBJECT = process.env.WATCHR_VAPID_SUBJECT?.trim() || 'https://github.com/kylbutlr/status-watchr';
  return { port, origin, directory, authMode, secure: parsed.protocol === 'https:' };
}
