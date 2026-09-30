import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pool, closePool } from './db.js';

const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

export async function migrate(log: (m: string) => void = console.log): Promise<string[]> {
  const client = await pool.connect();
  const applied: string[] = [];
  try {
    // advisory lock: only one process migrates at a time
    await client.query('SELECT pg_advisory_lock(727001)');
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
    const done = new Set((await client.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name));
    const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
    for (const f of files) {
      if (done.has(f)) continue;
      log(`applying ${f}`);
      await client.query('BEGIN');
      try {
        await client.query(readFileSync(join(dir, f), 'utf8'));
        await client.query('INSERT INTO schema_migrations(name) VALUES ($1)', [f]);
        await client.query('COMMIT');
        applied.push(f);
      } catch (e) {
        await client.query('ROLLBACK');
        throw new Error(`Migration ${f} failed: ${(e as Error).message}`);
      }
    }
  } finally {
    await client.query('SELECT pg_advisory_unlock(727001)').catch(() => {});
    client.release();
  }
  return applied;
}

if (process.argv[1] && process.argv[1].endsWith('migrate.ts')) {
  migrate()
    .then((a) => console.log(a.length ? `applied ${a.length} migration(s)` : 'database is up to date'))
    .catch((e) => {
      console.error(e.message);
      process.exitCode = 1;
    })
    .finally(closePool);
}
