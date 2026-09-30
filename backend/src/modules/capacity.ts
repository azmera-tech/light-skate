import type { Db, Queryable } from '../db.js';
import { one } from '../db.js';
import { OCCUPANCY_STATUSES } from './sessions-machine.js';

export async function getMaxCapacity(q: Queryable, venueId: string, at: Date): Promise<number> {
  const r = await one<{ max_capacity: number }>(q,
    `SELECT max_capacity FROM capacity_rules WHERE venue_id = $1 AND effective_from <= $2 ORDER BY effective_from DESC, created_at DESC LIMIT 1`,
    [venueId, at]);
  return r?.max_capacity ?? 0;
}

/** Occupancy is derived from session state — never a separately maintained counter. */
export async function countOccupancy(q: Queryable, venueId: string): Promise<number> {
  const r = await one<{ n: number }>(q, `SELECT count(*)::int AS n FROM sessions WHERE venue_id = $1 AND status = ANY($2)`, [venueId, OCCUPANCY_STATUSES]);
  return r?.n ?? 0;
}

/** Serialises every capacity-consuming operation for a venue. Always taken AFTER the session row lock. */
export async function lockVenue(db: Db, venueId: string) {
  await db.query('SELECT 1 FROM venues WHERE id = $1 FOR NO KEY UPDATE', [venueId]);
}

/*
 * LOCKING NOTE: every row lock in this codebase is FOR NO KEY UPDATE (never FOR UPDATE). Nearly every table has a
 * foreign key to venues/sessions/customers, and each INSERT takes a FOR KEY SHARE lock on the referenced row. A plain
 * FOR UPDATE conflicts with that, which deadlocks two transactions that both hold key-share and then both ask for the
 * lock. FOR NO KEY UPDATE serialises writers identically but does not conflict with key-share.
 */
