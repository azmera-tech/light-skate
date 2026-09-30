import type { Ctx } from '../shared/ctx.js';
import { assertCan } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { getSettings, getVenue } from '../settings.js';
import { many, one } from '../db.js';
import { addDaysToDate, isValidDate, localDateIn, localWeekdayIn } from '../shared/time.js';
import { dayBounds } from './dashboard.js';
import { getMaxCapacity } from './capacity.js';

/**
 * Reports are read-only views over the transactional tables. Nothing here alters operational data.
 * "Day" always means the venue-local calendar day.
 */
export async function dailyReport(ctx: Ctx, date?: string) {
  assertCan(ctx, 'reports.read');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const d = date ?? localDateIn(venue.timezone, ctx.now);
  if (!isValidDate(d)) throw E.badRequest('INVALID_DATE', 'Use a date like 2026-09-30.');
  const settings = await getSettings(ctx.db, ctx.venueId);
  const { start, end } = await dayBounds(ctx, venue.timezone, d);
  const q = (sql: string, extra: unknown[] = []) => one<any>(ctx.db, sql, [ctx.venueId, start, end, ...extra]);

  const visits = await q(`SELECT count(*) FILTER (WHERE checked_in_at IS NOT NULL)::int AS visitors, count(*)::int AS created FROM visits WHERE venue_id=$1 AND local_date = $4::date`, [d]);
  const newCustomers = await q(`SELECT count(*)::int AS n FROM customers WHERE venue_id=$1 AND registered_at >= $2 AND registered_at < $3`);
  const sess = await q(
    `SELECT count(*) FILTER (WHERE started_at >= $2 AND started_at < $3)::int AS started,
            count(*) FILTER (WHERE started_at >= $2 AND started_at < $3 AND status IN ('COMPLETED','EARLY_EXIT'))::int AS completed,
            count(*) FILTER (WHERE started_at >= $2 AND started_at < $3 AND status = 'EARLY_EXIT')::int AS early_exits,
            count(*) FILTER (WHERE started_at >= $2 AND started_at < $3 AND status IN ('ACTIVE','PAUSED','EXPIRING','EXPIRED'))::int AS active,
            count(*) FILTER (WHERE created_at >= $2 AND created_at < $3 AND status = 'CANCELLED')::int AS cancelled,
            count(*) FILTER (WHERE created_at >= $2 AND created_at < $3 AND status = 'NO_SHOW')::int AS no_shows,
            COALESCE(SUM(discount_minor) FILTER (WHERE started_at >= $2 AND started_at < $3),0)::bigint AS discounts_minor,
            COALESCE(AVG(EXTRACT(EPOCH FROM (actual_end_at - started_at)) - CASE WHEN pause_counts_toward_time THEN 0 ELSE total_paused_seconds END)
                     FILTER (WHERE started_at >= $2 AND started_at < $3 AND actual_end_at IS NOT NULL),0)::bigint AS avg_seconds,
            (SELECT count(*)::int FROM session_extensions x WHERE x.venue_id=$1 AND x.created_at >= $2 AND x.created_at < $3) AS extensions
       FROM sessions WHERE venue_id=$1`);
  const money = await q(
    `SELECT COALESCE(SUM(amount_minor) FILTER (WHERE type='CHARGE'),0)::bigint AS charges,
            COALESCE(SUM(amount_minor) FILTER (WHERE type='REFUND'),0)::bigint AS refunds
       FROM payment_transactions WHERE venue_id=$1 AND created_at >= $2 AND created_at < $3`);
  const byMethod = await many<any>(ctx.db,
    `SELECT method, COALESCE(SUM(amount_minor) FILTER (WHERE type='CHARGE'),0)::bigint AS charges, COALESCE(SUM(amount_minor) FILTER (WHERE type='REFUND'),0)::bigint AS refunds, count(*) FILTER (WHERE type='CHARGE')::int AS count
       FROM payment_transactions WHERE venue_id=$1 AND created_at >= $2 AND created_at < $3 GROUP BY method ORDER BY method`, [ctx.venueId, start, end]);
  const eq = await q(`SELECT count(*)::int AS issues, count(DISTINCT equipment_id)::int AS units FROM equipment_events WHERE venue_id=$1 AND occurred_at >= $2 AND occurred_at < $3 AND event_type='ISSUED'`);
  const inc = await many<any>(ctx.db, `SELECT severity, count(*)::int AS n FROM incidents WHERE venue_id=$1 AND occurred_at >= $2 AND occurred_at < $3 GROUP BY severity`, [ctx.venueId, start, end]);
  const hourly = await many<any>(ctx.db,
    `SELECT EXTRACT(HOUR FROM (started_at AT TIME ZONE $4))::int AS hour, count(*)::int AS n FROM sessions
      WHERE venue_id=$1 AND started_at >= $2 AND started_at < $3 GROUP BY 1 ORDER BY 1`, [ctx.venueId, start, end, venue.timezone]);

  // Capacity utilisation = occupied person-seconds / (capacity x opening seconds)
  const occ = await q(
    `SELECT COALESCE(SUM(EXTRACT(EPOCH FROM (LEAST(COALESCE(actual_end_at, $4::timestamptz), $3::timestamptz) - GREATEST(started_at, $2::timestamptz)))),0)::bigint AS person_seconds
       FROM sessions WHERE venue_id=$1 AND started_at IS NOT NULL AND started_at < $3 AND COALESCE(actual_end_at, $4::timestamptz) > $2`, [ctx.now]);
  const hrs = settings.operatingHours[String(localWeekdayIn(venue.timezone, new Date(start.getTime() + 12 * 3600_000)))];
  const toMin = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3));
  const openSeconds = hrs ? (toMin(hrs.close) - toMin(hrs.open)) * 60 : 12 * 3600;
  const max = await getMaxCapacity(ctx.db, ctx.venueId, end);
  const utilization = max > 0 && openSeconds > 0 ? Math.round((occ.person_seconds / (max * openSeconds)) * 1000) / 10 : 0;

  return {
    date: d, timezone: venue.timezone, currency: venue.currency,
    visitors: visits.visitors, newCustomers: newCustomers.n,
    sessions: { started: sess.started, completed: sess.completed, earlyExits: sess.early_exits, active: sess.active, cancelled: sess.cancelled, noShows: sess.no_shows, extensions: sess.extensions },
    revenue: { chargesMinor: money.charges, refundsMinor: money.refunds, netMinor: money.charges - money.refunds, discountsMinor: sess.discounts_minor,
      byMethod: byMethod.map((m) => ({ method: m.method, chargesMinor: m.charges, refundsMinor: m.refunds, count: m.count })) },
    equipment: { issues: eq.issues, distinctUnits: eq.units },
    incidents: { total: inc.reduce((a, r) => a + r.n, 0), bySeverity: Object.fromEntries(inc.map((r) => [r.severity, r.n])) },
    averageSessionSeconds: sess.avg_seconds,
    capacityUtilizationPercent: utilization, maxCapacity: max,
    hourlyStarts: hourly.map((h) => ({ hour: h.hour, sessions: h.n })),
  };
}

export async function rangeReport(ctx: Ctx, opts: { from: string; to: string; group: 'day' | 'week' | 'month' }) {
  assertCan(ctx, 'reports.read');
  if (!isValidDate(opts.from) || !isValidDate(opts.to) || opts.from > opts.to) throw E.badRequest('INVALID_RANGE', 'Choose a valid date range.');
  if (addDaysToDate(opts.from, 400) < opts.to) throw E.badRequest('RANGE_TOO_LARGE', 'Please choose a range of 400 days or less.');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const a = await dayBounds(ctx, venue.timezone, opts.from);
  const b = await dayBounds(ctx, venue.timezone, opts.to);
  const unit = opts.group;
  const sessions = await many<any>(ctx.db,
    `SELECT date_trunc('${unit}', (started_at AT TIME ZONE $4))::date::text AS period,
            count(*)::int AS started,
            count(*) FILTER (WHERE status IN ('COMPLETED','EARLY_EXIT'))::int AS completed,
            count(DISTINCT customer_id)::int AS unique_customers,
            COALESCE(SUM(discount_minor),0)::bigint AS discounts_minor,
            COALESCE(AVG(EXTRACT(EPOCH FROM (actual_end_at - started_at)) - CASE WHEN pause_counts_toward_time THEN 0 ELSE total_paused_seconds END)
                     FILTER (WHERE actual_end_at IS NOT NULL),0)::bigint AS avg_seconds
       FROM sessions WHERE venue_id=$1 AND started_at >= $2 AND started_at < $3 GROUP BY 1`, [ctx.venueId, a.start, b.end, venue.timezone]);
  const money = await many<any>(ctx.db,
    `SELECT date_trunc('${unit}', (created_at AT TIME ZONE $4))::date::text AS period,
            COALESCE(SUM(amount_minor) FILTER (WHERE type='CHARGE'),0)::bigint AS charges, COALESCE(SUM(amount_minor) FILTER (WHERE type='REFUND'),0)::bigint AS refunds
       FROM payment_transactions WHERE venue_id=$1 AND created_at >= $2 AND created_at < $3 GROUP BY 1`, [ctx.venueId, a.start, b.end, venue.timezone]);
  const periods = new Map<string, any>();
  const row = (p: string) => { if (!periods.has(p)) periods.set(p, { period: p, sessionsStarted: 0, sessionsCompleted: 0, uniqueCustomers: 0, revenueMinor: 0, refundsMinor: 0, discountsMinor: 0, averageSessionSeconds: 0 }); return periods.get(p); };
  for (const s of sessions) Object.assign(row(s.period), { sessionsStarted: s.started, sessionsCompleted: s.completed, uniqueCustomers: s.unique_customers, discountsMinor: s.discounts_minor, averageSessionSeconds: s.avg_seconds });
  for (const m of money) Object.assign(row(m.period), { revenueMinor: m.charges - m.refunds, refundsMinor: m.refunds });
  const rows = [...periods.values()].sort((x, y) => x.period.localeCompare(y.period));
  const totals = rows.reduce((t, r) => ({ sessionsStarted: t.sessionsStarted + r.sessionsStarted, sessionsCompleted: t.sessionsCompleted + r.sessionsCompleted,
    revenueMinor: t.revenueMinor + r.revenueMinor, refundsMinor: t.refundsMinor + r.refundsMinor, discountsMinor: t.discountsMinor + r.discountsMinor }),
    { sessionsStarted: 0, sessionsCompleted: 0, revenueMinor: 0, refundsMinor: 0, discountsMinor: 0 });
  return { from: opts.from, to: opts.to, group: unit, currency: venue.currency, rows, totals };
}
