import type { Db } from '../db.js';
import { E } from '../shared/errors.js';

const camelKey = (k: string) => k.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());

/** snake_case row -> camelCase object (top-level keys only; jsonb payloads are left as stored). */
export function toCamel<T = any>(row: Record<string, unknown> | null | undefined): T {
  if (!row) return row as any;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(row)) out[camelKey(k)] = v;
  return out as T;
}
export const toCamelAll = <T = any>(rows: Record<string, unknown>[]): T[] => rows.map((r) => toCamel<T>(r));

export async function lockOne<T = any>(db: Db, sql: string, params: unknown[], what: string): Promise<T> {
  const r = await db.query(sql, params as any[]);
  if (!r.rows[0]) throw E.notFound(what);
  return r.rows[0] as T;
}

export function assertUuid(id: string, what = 'identifier') {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw E.badRequest('INVALID_ID', `That ${what} is not valid.`);
}

export const secondsBetween = (a: Date, b: Date) => Math.round((b.getTime() - a.getTime()) / 1000);
