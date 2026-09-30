import type { Ctx } from '../shared/ctx.js';
import { assertCan } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit } from '../shared/events.js';
import { getVenue } from '../settings.js';
import { many, one } from '../db.js';
import { localDateIn, isValidDate } from '../shared/time.js';
import { dayBounds } from './dashboard.js';
import { toCamel, toCamelAll } from './util.js';

export async function dayClosePreview(ctx: Ctx, date?: string) {
  assertCan(ctx, 'dayclose.manage');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const d = date ?? localDateIn(venue.timezone, ctx.now);
  if (!isValidDate(d)) throw E.badRequest('INVALID_DATE', 'Use a date like 2026-09-30.');
  const { start, end } = await dayBounds(ctx, venue.timezone, d);
  const q = (sql: string, p: unknown[] = []) => one<any>(ctx.db, sql, [ctx.venueId, ...p]);
  const active = await q(`SELECT count(*)::int AS n FROM sessions WHERE venue_id=$1 AND status IN ('CHECKED_IN','ACTIVE','PAUSED','EXPIRING','EXPIRED')`);
  const unreturned = await q(`SELECT count(*)::int AS n FROM equipment_assignments WHERE venue_id=$1 AND returned_at IS NULL`);
  const incidents = await q(`SELECT count(*)::int AS n FROM incidents WHERE venue_id=$1 AND status <> 'CLOSED'`);
  const unpaid = await q(`SELECT count(*)::int AS n FROM sessions WHERE venue_id=$1 AND status IN ('CREATED','PAYMENT_PENDING') AND created_at >= $2 AND created_at < $3`, [start, end]);
  const pending = await q(`SELECT count(*)::int AS n FROM payments WHERE venue_id=$1 AND status IN ('PENDING','AUTHORIZED')`);
  const cash = await q(
    `SELECT COALESCE(SUM(CASE WHEN type='CHARGE' THEN amount_minor ELSE -amount_minor END),0)::bigint AS minor FROM payment_transactions
      WHERE venue_id=$1 AND method='CASH' AND created_at >= $2 AND created_at < $3`, [start, end]);
  const closed = await q('SELECT id, closed_at FROM day_closes WHERE venue_id=$1 AND local_date=$2::date', [d]);
  const checks = { activeSessions: active.n, unreturnedSkates: unreturned.n, unresolvedIncidents: incidents.n, unpaidSessions: unpaid.n, pendingPayments: pending.n };
  const blockers = [
    active.n && `${active.n} active session(s)`, unreturned.n && `${unreturned.n} unreturned item(s)`, unpaid.n && `${unpaid.n} unpaid session(s)`, pending.n && `${pending.n} pending payment(s)`,
  ].filter(Boolean) as string[];
  return { date: d, checks, expectedCashMinor: cash.minor, blockers, warnings: incidents.n ? [`${incidents.n} unresolved incident(s)`] : [], alreadyClosed: !!closed, closedAt: closed?.closed_at ?? null };
}

export async function closeDay(ctx: Ctx, input: { date?: string; countedCashMinor: number; notes?: string | null; acknowledgeWarnings?: boolean }) {
  assertCan(ctx, 'dayclose.manage');
  const prev = await dayClosePreview(ctx, input.date);
  if (prev.alreadyClosed) throw E.conflict('DAY_ALREADY_CLOSED', `${prev.date} has already been closed.`);
  if (prev.blockers.length) throw E.conflict('DAY_CLOSE_BLOCKED', `The day cannot be closed yet: ${prev.blockers.join(', ')}.`, prev);
  if (prev.warnings.length && !input.acknowledgeWarnings) throw E.conflict('DAY_CLOSE_WARNINGS', `Please confirm to close with: ${prev.warnings.join(', ')}.`, prev);
  const diff = input.countedCashMinor - prev.expectedCashMinor;
  if (diff !== 0 && !input.notes?.trim()) throw E.unprocessable('NOTES_REQUIRED', 'Explain the cash difference in the notes before closing.');
  const r = await ctx.db.query(
    `INSERT INTO day_closes (venue_id, local_date, expected_cash_minor, counted_cash_minor, difference_minor, checks, notes, closed_by, closed_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *`,
    [ctx.venueId, prev.date, prev.expectedCashMinor, input.countedCashMinor, diff, JSON.stringify(prev.checks), input.notes ?? null, ctx.user?.id ?? null, ctx.now]);
  await audit(ctx, { action: 'day.closed', entityType: 'day_close', entityId: r.rows[0].id, after: { date: prev.date, expectedCashMinor: prev.expectedCashMinor, countedCashMinor: input.countedCashMinor, differenceMinor: diff }, reason: input.notes ?? null });
  await emit(ctx, 'DAY_CLOSED', 'venue', ctx.venueId, { date: prev.date, differenceMinor: diff });
  return toCamel(r.rows[0]);
}

export async function listDayCloses(ctx: Ctx) {
  assertCan(ctx, 'dayclose.manage');
  return toCamelAll(await many(ctx.db, 'SELECT * FROM day_closes WHERE venue_id=$1 ORDER BY local_date DESC LIMIT 60', [ctx.venueId]));
}
