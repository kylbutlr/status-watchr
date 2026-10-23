import { getStore } from '@netlify/blobs';
import { mkdir, readFile, rename, unlink, readdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

// Standalone storage has no Netlify account or network dependency. Only generated
// keys are mapped to filenames, and a completed rename publishes each receipt.
export function watchrStore(name: string) {
  if (process.env.WATCHR_RUNTIME !== 'standalone') return getStore({ name, consistency: 'strong' });
  const directory = join(resolve(process.env.WATCHR_DATA_DIR || 'data'), 'receipts', name);
  const file = (key: string) => join(directory, Buffer.from(key).toString('base64url') + '.json');
  return {
    async get(key: string, _options?: { type: string }) {
      try { return JSON.parse(await readFile(file(key), 'utf8')); }
      catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null; throw error; }
    },
    async setJSON(key: string, value: unknown) {
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const temporary = join(directory, randomUUID() + '.tmp');
      try { await writeFile(temporary, JSON.stringify(value), { flag: 'wx', mode: 0o600 }); await rename(temporary, file(key)); }
      finally { await unlink(temporary).catch(() => {}); }
    },
    async delete(key: string) { await unlink(file(key)).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'ENOENT') throw error; }); },
    async *list({ prefix = '' }: { prefix?: string; paginate?: boolean } = {}) {
      let files: string[];
      try { files = await readdir(directory); }
      catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return; throw error; }
      yield { blobs: files.filter((name) => name.endsWith('.json')).map((name) => ({ key: Buffer.from(name.slice(0, -5), 'base64url').toString() })).filter(({ key }) => key.startsWith(prefix)) };
    },
  };
}
