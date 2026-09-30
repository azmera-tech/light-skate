import pg from 'pg';
import { config } from './config.js';

// int8 (bigint) -> number. All money/counters fit comfortably in 2^53.
pg.types.setTypeParser(20, (v) => Number(v));
// numeric -> number for COUNT/SUM results cast to numeric in reports.
pg.types.setTypeParser(1700, (v) => Number(v));
// date -> plain 'YYYY-MM-DD' string (avoid JS timezone shifts)
pg.types.setTypeParser(1082, (v) => v);

export const pool = new pg.Pool({ connectionString: config.databaseUrl, max: config.dbPoolMax });
pool.on('error', (err) => {
  // idle client errors must not crash the process
  console.error('pg pool error', err.message);
});

export type Db = pg.PoolClient;
export type Queryable = pg.Pool | pg.PoolClient;

export async function withTx<T>(fn: (client: Db) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* connection already broken */
    }
    throw e;
  } finally {
    client.release();
  }
}

export async function one<T = any>(q: Queryable, sql: string, params: unknown[] = []): Promise<T | null> {
  const r = await q.query(sql, params as any[]);
  return (r.rows[0] as T) ?? null;
}

export async function many<T = any>(q: Queryable, sql: string, params: unknown[] = []): Promise<T[]> {
  const r = await q.query(sql, params as any[]);
  return r.rows as T[];
}

export async function closePool() {
  await pool.end();
}
