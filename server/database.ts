import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import type { SQL } from '../netlify/functions/lib/notifications.js';

type Query = { text: string; values: unknown[] };
type Pending = PromiseLike<unknown[]> & { query: Query };
export async function localDatabase(directory: string, migrations: string) {
  const database = await PGlite.create(directory);
  try {
    await database.exec('create table if not exists watchr_schema_migrations (name text primary key)');
    for (const name of (await readdir(migrations)).filter((name) => /^\d+_[a-z_]+\.sql$/.test(name)).sort()) {
      await database.transaction(async (tx) => {
        const existing = await tx.query('select name from watchr_schema_migrations where name = $1', [name]);
        if (existing.rows.length) return;
        await tx.exec(await readFile(new URL(name, 'file://' + migrations.replace(/\/$/, '') + '/'), 'utf8'));
        await tx.query('insert into watchr_schema_migrations(name) values ($1)', [name]);
      });
    }
    const sql = Object.assign((strings: TemplateStringsArray, ...values: unknown[]): Pending => {
      const query = { text: strings.reduce((text, part, index) => text + (index ? `$${index}` : '') + part, ''), values };
      return { query, then: (resolve, reject) => database.query(query.text, query.values).then((result) => result.rows).then(resolve, reject) };
    }, { transaction: (queries: Pending[]) => database.transaction(async (tx) => {
      const result = [];
      for (const { query } of queries) result.push((await tx.query(query.text, query.values)).rows);
      return result;
    }) });
    return { sql: sql as unknown as SQL, close: () => database.close() };
  } catch (error) { await database.close(); throw error; }
}
