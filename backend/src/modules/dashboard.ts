import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { getVenue } from '../settings.js';
import { one, many } from '../db.js';
import { localDateIn } from '../shared/time.js';
import { countOccupancy, getMaxCapacity } from './capacity.js';
import { listSessions } from './sessions.js';
import { OCCUPANCY_STATUSES } from './sessions-machine.js';

/** Start/end instants (UTC) of a venue-local calendar date. */
export async function dayBounds(ctx: Pick<Ctx, 'db'>, tz: string, date: string): Promise<{ start: Date; end: Date }> {
  const r = await one<{ s: Date; e: Date }>(ctx.db as any,
    `SELECT ($1::date::timestamp AT TIME ZONE $2) AS s, (($1::date + 1)::timestamp AT TIME ZONE $2) AS e`, [date, tz]);
  return { start: r!.s, end: r!.e };
}

export async function getDashboard(ctx: Ctx) {
  assertCan(ctx, 'session.read');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const today = localDateIn(venue.timezone, ctx.now);
  const { start, end } = await dayBounds(ctx, venue.timezone, today);
  const occupancy = await countOccupancy(ctx.db, ctx.venueId);
  const max = await getMaxCapacity(ctx.db, ctx.venueId, ctx.now);
  const counts = await one<any>(ctx.db,
    `SELECT count(*) FILTER (WHERE status IN ('ACTIVE','PAUSED'))::int AS normal,
            count(*) FILTER (WHERE status = 'EXPIRING')::int AS expiring,
            count(*) FILTER (WHERE status = 'EXPIRED')::int AS expired,
            count(*) FILTER (WHERE status IN ('READY','CHECKED_IN'))::int AS waiting,
            count(*) FILTER (WHERE status = 'PAYMENT_PENDING')::int AS awaiting_payment
       FROM sessions WHERE venue_id=$1 AND status = ANY($2)`, [ctx.venueId, [...OCCUPANCY_STATUSES, 'READY', 'CHECKED_IN', 'PAYMENT_PENDING']]);
  const visitors = await one<any>(ctx.db, `SELECT count(*)::int AS n FROM visits WHERE venue_id=$1 AND local_date=$2 AND checked_in_at IS NOT NULL`, [ctx.venueId, today]);
  const revenue = can(ctx, 'payment.read') || can(ctx, 'reports.read')
    ? await one<any>(ctx.db,
        `SELECT COALESCE(SUM(CASE WHEN type='CHARGE' THEN amount_minor ELSE -amount_minor END),0)::bigint AS minor
           FROM payment_transactions WHERE venue_id=$1 AND created_at >= $2 AND created_at < $3`, [ctx.venueId, start, end])
    : null;
  const equipmentOut = await one<any>(ctx.db, `SELECT count(*)::int AS n FROM equipment_assignments WHERE venue_id=$1 AND returned_at IS NULL`, [ctx.venueId]);
  const equipmentIssues = await one<any>(ctx.db, `SELECT count(*)::int AS n FROM equipment WHERE venue_id=$1 AND status IN ('DAMAGED','MAINTENANCE','OUT_OF_SERVICE','RETURNED')`, [ctx.venueId]);
  const incidents = can(ctx, 'incident.read') ? await one<any>(ctx.db, `SELECT count(*)::int AS n FROM incidents WHERE venue_id=$1 AND status <> 'CLOSED'`, [ctx.venueId]) : null;
  const shoes = can(ctx, 'shoeclaim.manage')
    ? await one<any>(ctx.db, `SELECT count(*)::int AS on_shelf FROM shoe_claims WHERE venue_id=$1 AND status <> 'RETURNED'`, [ctx.venueId])
    : null;
  const cleaning = can(ctx, 'equipment.cleaning')
    ? await one<any>(ctx.db, `SELECT count(*) FILTER (WHERE status='NEEDS_CLEANING')::int AS needs_cleaning,
            count(*) FILTER (WHERE cleaning_due_at IS NOT NULL AND cleaning_due_at < $2)::int AS overdue
         FROM equipment WHERE venue_id=$1`, [ctx.venueId, ctx.now])
    : null;
  const alerts = await many<any>(ctx.db,
    `SELECT id, type, severity, title, body, entity_type, entity_id, status, created_at FROM notifications WHERE venue_id=$1 AND status='OPEN' ORDER BY created_at DESC LIMIT 20`, [ctx.venueId]);
  const live = await listSessions(ctx, { group: 'live' });
  return {
    serverTime: ctx.now.toISOString(), localDate: today, timezone: venue.timezone, currency: venue.currency,
    capacity: { occupancy, max, available: Math.max(0, max - occupancy), full: occupancy >= max },
    today: { visitors: visitors.n, revenueMinor: revenue ? revenue.minor : null },
    rink: { normal: counts.normal, expiring: counts.expiring, expired: counts.expired },
    waiting: counts.waiting, awaitingPayment: counts.awaiting_payment,
    equipment: { out: equipmentOut.n, needsAttention: equipmentIssues.n },
    openIncidents: incidents ? incidents.n : null,
    shoes: shoes ? { onShelf: shoes.on_shelf } : null,
    cleaning: cleaning ? { needsCleaning: cleaning.needs_cleaning, overdue: cleaning.overdue } : null,
    alerts: alerts.map((a) => ({ id: a.id, type: a.type, severity: a.severity, title: a.title, body: a.body, entityType: a.entity_type, entityId: a.entity_id, createdAt: a.created_at })),
    liveSessions: live.sessions,
  };
}
