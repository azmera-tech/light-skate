import { withTx, pool } from '../db.js';
import { config } from '../config.js';
import { clock } from '../shared/clock.js';

export const REALTIME_CHANNEL = 'ls_realtime';

interface OutboxRow { id: number; venue_id: string; event_type: string; aggregate_type: string; aggregate_id: string | null; payload: any; attempt_count: number }

/** Notification rules: which domain events become durable, acknowledge-able operational alerts. */
function notificationFor(e: OutboxRow): { type: string; severity: 'INFO' | 'WARNING' | 'CRITICAL'; title: string; body?: string; entityType: string; entityId: string | null } | null {
  const p = e.payload ?? {};
  switch (e.event_type) {
    case 'SESSION_EXPIRED': return { type: 'SESSION_EXPIRED', severity: 'CRITICAL', title: 'Session expired', body: 'A skater is past their paid time.', entityType: 'session', entityId: e.aggregate_id };
    case 'SESSION_WARNING': return p.level === 'RED' || p.minutes <= 1
      ? { type: 'SESSION_WARNING', severity: 'WARNING', title: `${p.minutes} minute${p.minutes === 1 ? '' : 's'} remaining`, entityType: 'session', entityId: e.aggregate_id } : null;
    case 'CAPACITY_FULL': return { type: 'CAPACITY_FULL', severity: 'WARNING', title: 'Venue is full', body: `${p.occupancy} / ${p.max}`, entityType: 'venue', entityId: e.aggregate_id };
    case 'EQUIPMENT_DAMAGED': return { type: 'EQUIPMENT_DAMAGED', severity: 'WARNING', title: `${p.code ?? 'Equipment'} reported damaged`, entityType: 'equipment', entityId: e.aggregate_id };
    case 'INCIDENT_REPORTED': return { type: 'INCIDENT_REPORTED', severity: ['SERIOUS', 'CRITICAL'].includes(p.severity) ? 'CRITICAL' : 'INFO',
      title: `Incident ${p.incidentNumber ?? ''} (${String(p.severity ?? '').toLowerCase()})`, entityType: 'incident', entityId: e.aggregate_id };
    case 'SESSION_NO_SHOW': return { type: 'SESSION_NO_SHOW', severity: 'INFO', title: 'Paid session marked as no-show', entityType: 'session', entityId: e.aggregate_id };
    default: return null;
  }
}

/** Events that clear earlier alerts about the same entity. */
const RESOLVES: Record<string, string[]> = {
  SESSION_ENDED: ['SESSION_EXPIRED', 'SESSION_WARNING'],
  SESSION_EXTENDED: ['SESSION_EXPIRED', 'SESSION_WARNING'],
  SESSION_CANCELLED: ['SESSION_EXPIRED', 'SESSION_WARNING'],
};

// Fields that may travel over the realtime channel. Deliberately no names, phones, photos or money.
const SAFE_FIELDS = ['sessionId', 'customerId', 'equipmentId', 'visitId', 'paymentId', 'incidentId', 'status', 'occupancy', 'max', 'scheduledEndAt', 'startedAt', 'minutes', 'level', 'code', 'outcome', 'keys', 'notificationId', 'severity'];

/** Test seam: lets failure-recovery tests simulate a downstream (notification/realtime) outage. */
export const outboxHooks: { beforeDispatch?: (e: { id: number; event_type: string }) => void } = {};

async function dispatch(db: import('../db.js').Db, e: OutboxRow) {
  outboxHooks.beforeDispatch?.(e);
  const n = notificationFor(e);
  if (n) {
    const r = await db.query(
      `INSERT INTO notifications (venue_id, outbox_event_id, type, severity, title, body, entity_type, entity_id, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT (outbox_event_id) DO NOTHING RETURNING id`,
      [e.venue_id, e.id, n.type, n.severity, n.title, n.body ?? null, n.entityType, n.entityId, clock.now()]);
    if (r.rows[0]) {
      await db.query(`INSERT INTO notification_deliveries (notification_id, channel, status, attempts, sent_at) VALUES ($1,'IN_APP','SENT',1,$2)`, [r.rows[0].id, clock.now()]);
      // TODO(phase 2): PUSH / SMS delivery channels with their own retry state.
    }
  }
  const resolves = RESOLVES[e.event_type];
  if (resolves && e.aggregate_id) {
    await db.query(`UPDATE notifications SET status='RESOLVED', resolved_at=$4 WHERE venue_id=$1 AND entity_id=$2 AND type = ANY($3) AND status <> 'RESOLVED'`, [e.venue_id, e.aggregate_id, resolves, clock.now()]);
  }
  if (e.event_type === 'CAPACITY_CHANGED' && e.payload.occupancy < e.payload.max) {
    await db.query(`UPDATE notifications SET status='RESOLVED', resolved_at=$2 WHERE venue_id=$1 AND type='CAPACITY_FULL' AND status <> 'RESOLVED'`, [e.venue_id, clock.now()]);
  }
  const safe: Record<string, unknown> = {};
  for (const k of SAFE_FIELDS) if (e.payload?.[k] !== undefined) safe[k] = e.payload[k];
  const msg = JSON.stringify({ venueId: e.venue_id, id: e.id, type: e.event_type, aggregateType: e.aggregate_type, aggregateId: e.aggregate_id, payload: safe, at: e.payload?.at });
  // NOTIFY is transactional: it is delivered only if this transaction commits, i.e. exactly when the event is marked processed.
  await db.query('SELECT pg_notify($1, $2)', [REALTIME_CHANNEL, msg]);
}

/** Process pending outbox rows. Safe to run from several workers (SKIP LOCKED); at-least-once, effectively exactly-once for DB effects. */
export async function processOutbox(limit = config.worker.outboxBatch): Promise<number> {
  return withTx(async (db) => {
    const rows = (await db.query<OutboxRow>(
      `SELECT id, venue_id, event_type, aggregate_type, aggregate_id, payload, attempt_count FROM outbox_events
        WHERE processed_at IS NULL AND available_at <= $1 ORDER BY id LIMIT $2 FOR NO KEY UPDATE SKIP LOCKED`, [clock.now(), limit])).rows;
    let done = 0;
    for (const e of rows) {
      await db.query('SAVEPOINT ev');
      try {
        await dispatch(db, e);
        await db.query('UPDATE outbox_events SET processed_at=$2, attempt_count=attempt_count+1, last_error=NULL WHERE id=$1', [e.id, clock.now()]);
        await db.query('RELEASE SAVEPOINT ev');
        done++;
      } catch (err) {
        await db.query('ROLLBACK TO SAVEPOINT ev');
        const attempts = e.attempt_count + 1;
        const backoff = Math.min(300, 2 ** attempts) * 1000;
        await db.query('UPDATE outbox_events SET attempt_count=$2, last_error=$3, available_at=$4 WHERE id=$1',
          [e.id, attempts, String((err as Error).message).slice(0, 500), new Date(clock.now().getTime() + (attempts >= config.worker.outboxMaxAttempts ? 24 * 3600_000 : backoff))]);
        await db.query('RELEASE SAVEPOINT ev');
      }
    }
    return done;
  });
}

export async function outboxBacklog() {
  const r = await pool.query(`SELECT count(*)::int AS pending, COALESCE(EXTRACT(EPOCH FROM (now() - min(created_at))),0)::int AS oldest_seconds,
     count(*) FILTER (WHERE attempt_count >= 3)::int AS failing FROM outbox_events WHERE processed_at IS NULL`);
  return r.rows[0] as { pending: number; oldest_seconds: number; failing: number };
}
