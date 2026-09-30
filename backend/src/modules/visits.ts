import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { getVenue } from '../settings.js';
import { many, one } from '../db.js';
import { localDateIn, isValidDate } from '../shared/time.js';
import { toCamel, toCamelAll, lockOne } from './util.js';
import { nextCounter, customerNumber } from './customers.js';
import { LATEST_PHOTO_SQL } from './photos.js';
import { emit } from '../shared/events.js';

/** Start a visit for a customer. Re-uses an empty open visit instead of creating junk records. */
export async function createVisit(ctx: Ctx, input: { customerId: string }) {
  assertCan(ctx, 'session.create');
  const c = await lockOne<any>(ctx.db, 'SELECT id, status FROM customers WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [input.customerId, ctx.venueId], 'Customer');
  if (c.status === 'BLOCKED') throw E.conflict('CUSTOMER_BLOCKED', 'This customer is blocked. Please speak to a manager.');
  if (c.status !== 'ACTIVE') throw E.conflict('CUSTOMER_INACTIVE', 'This customer record is not active.');
  const reusable = await one<any>(ctx.db,
    `SELECT v.id, v.visit_number FROM visits v
      WHERE v.customer_id=$1 AND v.status='OPEN' AND v.created_at > $2
        AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.visit_id=v.id AND s.status NOT IN ('CANCELLED','NO_SHOW'))
      ORDER BY v.created_at DESC LIMIT 1`, [input.customerId, new Date(ctx.now.getTime() - 12 * 3600_000)]);
  if (reusable) return { id: reusable.id, visitNumber: reusable.visit_number, reused: true };
  const venue = await getVenue(ctx.db, ctx.venueId);
  const localDate = localDateIn(venue.timezone, ctx.now);
  const n = await nextCounter(ctx, 'visit:' + localDate);
  const visitNumber = `LS-${localDate.replace(/-/g, '')}-${String(n).padStart(5, '0')}`;
  const r = await ctx.db.query(
    `INSERT INTO visits (venue_id, visit_number, customer_id, local_date, created_by, device_id, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
    [ctx.venueId, visitNumber, input.customerId, localDate, ctx.user?.id ?? null, ctx.deviceId, ctx.now]);
  await audit(ctx, { action: 'visit.created', entityType: 'visit', entityId: r.rows[0].id, after: { visitNumber, customerId: input.customerId } });
  await emit(ctx, 'VISIT_CREATED', 'visit', r.rows[0].id, { visitId: r.rows[0].id });
  return { id: r.rows[0].id, visitNumber, reused: false };
}

/** Closes the visit once its session has ended and all equipment is back. */
export async function completeVisitIfDone(ctx: Ctx, visitId: string): Promise<boolean> {
  const r = await ctx.db.query(
    `UPDATE visits v SET status='COMPLETED', closed_at=$2
      WHERE v.id=$1 AND v.status='OPEN'
        AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.visit_id=v.id AND s.status NOT IN ('COMPLETED','EARLY_EXIT','CANCELLED','NO_SHOW'))
        AND EXISTS (SELECT 1 FROM sessions s WHERE s.visit_id=v.id AND s.status IN ('COMPLETED','EARLY_EXIT'))
        AND NOT EXISTS (SELECT 1 FROM equipment_assignments ea JOIN sessions s ON s.id=ea.session_id WHERE s.visit_id=v.id AND ea.returned_at IS NULL)
      RETURNING v.id`, [visitId, ctx.now]);
  return r.rowCount === 1;
}

export type HistoryFilter = 'all' | 'completed' | 'active' | 'cancelled' | 'expired' | 'payment_issues' | 'incidents';

const FILTER_SQL: Record<HistoryFilter, string> = {
  all: 'true',
  completed: `s.status IN ('COMPLETED','EARLY_EXIT')`,
  active: `s.status IN ('CHECKED_IN','ACTIVE','PAUSED','EXPIRING','EXPIRED')`,
  cancelled: `(s.status IN ('CANCELLED','NO_SHOW') OR v.status = 'CANCELLED')`,
  expired: `(s.status = 'EXPIRED' OR (s.actual_end_at IS NOT NULL AND s.actual_end_at > s.scheduled_end_at + interval '1 minute'))`,
  payment_issues: `(COALESCE(s.price_minor - s.discount_minor,0) > paid.minor
        OR EXISTS (SELECT 1 FROM payments p WHERE p.visit_id=v.id AND p.status IN ('PENDING','FAILED')))`,
  incidents: `EXISTS (SELECT 1 FROM incidents i WHERE i.visit_id = v.id)`,
};

/** Daily history: a view over the real visit/session/payment records (no separate history table). */
export async function listVisits(ctx: Ctx, opts: { date?: string; filter?: HistoryFilter; limit?: number; offset?: number; customerId?: string }) {
  assertCan(ctx, 'visit.read');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const date = opts.date ?? localDateIn(venue.timezone, ctx.now);
  if (!isValidDate(date)) throw E.badRequest('INVALID_DATE', 'Use a date like 2026-09-30.');
  const filter = FILTER_SQL[opts.filter ?? 'all'];
  if (!filter) throw E.badRequest('INVALID_FILTER', 'Unknown history filter.');
  const canPhotos = can(ctx, 'customer.read');
  const canPay = can(ctx, 'payment.read');
  const params: unknown[] = [ctx.venueId, date, opts.limit ?? 200, opts.offset ?? 0];
  let extra = '';
  if (opts.customerId) { params.push(opts.customerId); extra = ` AND v.customer_id = $${params.length}`; }
  const rows = await many<any>(ctx.db,
    `SELECT v.id AS visit_id, v.visit_number, v.status AS visit_status, v.created_at, v.checked_in_at, v.local_date,
            c.id AS customer_id, c.customer_no, c.full_name, c.phone_e164,
            ${canPhotos ? LATEST_PHOTO_SQL : 'NULL::uuid'} AS photo_id,
            s.id AS session_id, s.status AS session_status, s.product_name, s.started_at, s.scheduled_end_at, s.actual_end_at,
            s.current_duration_seconds, s.wristband, s.price_minor, s.discount_minor,
            ${canPay ? 'paid.minor' : 'NULL::bigint'} AS paid_minor, ${canPay ? 'paid.methods' : 'NULL::text'} AS payment_methods,
            COALESCE(u.full_name, cu.full_name) AS staff_name,
            COALESCE((SELECT string_agg(e.code, ', ' ORDER BY e.code) FROM equipment_assignments ea JOIN equipment e ON e.id=ea.equipment_id WHERE ea.session_id = s.id),'') AS equipment,
            EXISTS (SELECT 1 FROM incidents i WHERE i.visit_id = v.id) AS has_incident
       FROM visits v
       JOIN customers c ON c.id = v.customer_id
       LEFT JOIN LATERAL (SELECT * FROM sessions s2 WHERE s2.visit_id = v.id ORDER BY s2.created_at DESC LIMIT 1) s ON true
       LEFT JOIN users u ON u.id = s.started_by
       LEFT JOIN users cu ON cu.id = v.created_by
       LEFT JOIN LATERAL (SELECT COALESCE(SUM(p.amount_minor - p.refunded_minor) FILTER (WHERE p.status IN ('PAID','PARTIALLY_REFUNDED','REFUNDED')),0)::bigint AS minor,
                                 string_agg(DISTINCT p.method, ', ') AS methods
                            FROM payments p WHERE p.visit_id = v.id) paid ON true
      WHERE v.venue_id = $1 AND v.local_date = $2 AND ${filter}${extra}
      ORDER BY v.created_at DESC LIMIT $3 OFFSET $4`, params);
  return {
    date, timezone: venue.timezone,
    visits: rows.map((r) => ({ ...toCamel(r), customerCode: customerNumber(r.customer_no) })),
  };
}

/** Full timeline of one visit, assembled from immutable event tables. */
export async function getVisit(ctx: Ctx, id: string) {
  assertCan(ctx, 'visit.read');
  const v = await one<any>(ctx.db,
    `SELECT v.*, c.full_name, c.phone_e164, c.customer_no, ${can(ctx, 'customer.read') ? LATEST_PHOTO_SQL : 'NULL::uuid'} AS photo_id
       FROM visits v JOIN customers c ON c.id = v.customer_id WHERE v.id=$1 AND v.venue_id=$2`, [id, ctx.venueId]);
  if (!v) throw E.notFound('Visit');
  const sessions = await many<any>(ctx.db, 'SELECT * FROM sessions WHERE visit_id=$1 ORDER BY created_at', [id]);
  const sessionIds = sessions.map((s) => s.id);
  const events = await many<any>(ctx.db,
    `SELECT 'session' AS source, e.event_type, e.occurred_at, e.metadata, e.actor_user_id, u.full_name AS actor_name, e.device_id, d.name AS device_name, e.session_id AS ref_id
       FROM session_events e LEFT JOIN users u ON u.id=e.actor_user_id LEFT JOIN devices d ON d.id=e.device_id WHERE e.visit_id=$1
     UNION ALL
     SELECT 'payment', pe.event_type, pe.occurred_at, pe.metadata, pe.actor_user_id, u.full_name, pe.device_id, d.name, pe.payment_id
       FROM payment_events pe JOIN payments p ON p.id=pe.payment_id LEFT JOIN users u ON u.id=pe.actor_user_id LEFT JOIN devices d ON d.id=pe.device_id WHERE p.visit_id=$1
     UNION ALL
     SELECT 'equipment', ee.event_type, ee.occurred_at, ee.metadata || jsonb_build_object('code', e.code), ee.actor_user_id, u.full_name, ee.device_id, d.name, ee.equipment_id
       FROM equipment_events ee JOIN equipment e ON e.id=ee.equipment_id LEFT JOIN users u ON u.id=ee.actor_user_id LEFT JOIN devices d ON d.id=ee.device_id
      WHERE ee.session_id = ANY($2)
     UNION ALL
     SELECT 'incident', ie.event_type, ie.occurred_at, '{}'::jsonb, ie.actor_user_id, u.full_name, ie.device_id, d.name, ie.incident_id
       FROM incident_events ie JOIN incidents i ON i.id=ie.incident_id LEFT JOIN users u ON u.id=ie.actor_user_id LEFT JOIN devices d ON d.id=ie.device_id
      WHERE i.visit_id=$1 AND ${can(ctx, 'incident.read') ? 'true' : 'false'}
     ORDER BY occurred_at, source`, [id, sessionIds]);
  const payments = can(ctx, 'payment.read')
    ? await many<any>(ctx.db, 'SELECT id, session_id, amount_minor, refunded_minor, currency, method, status, purpose, provider_reference, created_at FROM payments WHERE visit_id=$1 ORDER BY created_at', [id]) : [];
  const equipment = await many<any>(ctx.db,
    `SELECT ea.id, e.code, ea.assigned_at, ea.returned_at, ea.return_condition FROM equipment_assignments ea JOIN equipment e ON e.id=ea.equipment_id WHERE ea.session_id = ANY($1) ORDER BY ea.assigned_at`, [sessionIds]);
  return {
    visit: { ...toCamel(v), customerCode: customerNumber(v.customer_no) },
    sessions: toCamelAll(sessions), payments: toCamelAll(payments), equipment: toCamelAll(equipment),
    timeline: events.map((e) => ({ ...toCamel(e) })),
  };
}
