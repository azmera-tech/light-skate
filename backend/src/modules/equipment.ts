import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { AppError, E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit, recordEquipmentEvent } from '../shared/events.js';
import { getSettings } from '../settings.js';
import { many, one } from '../db.js';
import { toCamel, toCamelAll, lockOne } from './util.js';
import { EQUIPMENT_HOLDING_STATUSES, TERMINAL_STATUSES } from './sessions-machine.js';
import { completeVisitIfDone } from './visits.js';
import { newStorageKey, storage } from '../storage/index.js';
import { validateImage } from '../storage/image.js';

export type EquipmentStatus = 'AVAILABLE' | 'RESERVED' | 'ISSUED' | 'IN_USE' | 'RETURNED' | 'DAMAGED' | 'MAINTENANCE' | 'OUT_OF_SERVICE';

const EQ_TRANSITIONS: Record<EquipmentStatus, EquipmentStatus[]> = {
  AVAILABLE: ['ISSUED', 'RESERVED', 'DAMAGED', 'MAINTENANCE', 'OUT_OF_SERVICE'],
  RESERVED: ['ISSUED', 'AVAILABLE'],
  ISSUED: ['AVAILABLE', 'RETURNED', 'DAMAGED', 'MAINTENANCE'],
  IN_USE: ['AVAILABLE', 'RETURNED', 'DAMAGED'],
  RETURNED: ['AVAILABLE', 'DAMAGED', 'MAINTENANCE', 'OUT_OF_SERVICE'],
  DAMAGED: ['MAINTENANCE', 'OUT_OF_SERVICE'],
  MAINTENANCE: ['AVAILABLE', 'OUT_OF_SERVICE'],
  OUT_OF_SERVICE: ['MAINTENANCE', 'AVAILABLE'],
};

function assertEqTransition(e: { code: string; status: EquipmentStatus }, to: EquipmentStatus, verb: string) {
  if (!EQ_TRANSITIONS[e.status]?.includes(to)) {
    throw new AppError(409, 'EQUIPMENT_INVALID_TRANSITION', `${e.code} cannot ${verb} while it is ${e.status.toLowerCase().replace('_', ' ')}.`, { from: e.status, to });
  }
}

async function setStatus(ctx: Ctx, e: any, to: EquipmentStatus, eventType: string, meta: Record<string, unknown> = {}, sessionId: string | null = null) {
  await ctx.db.query('UPDATE equipment SET status=$2, updated_at=$3 WHERE id=$1', [e.id, to, ctx.now]);
  await recordEquipmentEvent(ctx, e.id, eventType, { from: e.status, to, sessionId, meta });
  e.status = to;
}

export async function listEquipment(ctx: Ctx, opts: { status?: string; q?: string; limit?: number }) {
  assertCan(ctx, 'equipment.read');
  const params: unknown[] = [ctx.venueId];
  let where = 'e.venue_id = $1';
  if (opts.status) { params.push(opts.status); where += ` AND e.status = $${params.length}`; }
  if (opts.q) { params.push('%' + opts.q.replace(/[%_\\]/g, (m) => '\\' + m) + '%'); where += ` AND (e.code ILIKE $${params.length} OR e.size ILIKE $${params.length})`; }
  params.push(Math.min(opts.limit ?? 500, 1000));
  const showCustomer = can(ctx, 'customer.read');
  const rows = await many<any>(ctx.db,
    `SELECT e.*, ea.session_id AS issued_session_id, ea.assigned_at AS issued_at,
            ${showCustomer ? 'c.full_name' : 'NULL::text'} AS issued_to, s.scheduled_end_at AS issued_until
       FROM equipment e
       LEFT JOIN equipment_assignments ea ON ea.equipment_id = e.id AND ea.returned_at IS NULL
       LEFT JOIN customers c ON c.id = ea.customer_id
       LEFT JOIN sessions s ON s.id = ea.session_id
      WHERE ${where} ORDER BY e.code LIMIT $${params.length}`, params);
  const summary = await many<any>(ctx.db, 'SELECT status, count(*)::int AS n FROM equipment WHERE venue_id=$1 GROUP BY status', [ctx.venueId]);
  return { items: toCamelAll(rows), summary: Object.fromEntries(summary.map((r) => [r.status, r.n])) };
}

export async function getEquipment(ctx: Ctx, id: string) {
  assertCan(ctx, 'equipment.read');
  const e = await one<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2', [id, ctx.venueId]);
  if (!e) throw E.notFound('Equipment');
  const events = await many<any>(ctx.db,
    `SELECT ee.event_type, ee.from_status, ee.to_status, ee.occurred_at, ee.metadata, u.full_name AS actor_name
       FROM equipment_events ee LEFT JOIN users u ON u.id=ee.actor_user_id WHERE ee.equipment_id=$1 ORDER BY ee.id DESC LIMIT 200`, [id]);
  const maint = await many<any>(ctx.db,
    `SELECT id, issue, status, reported_at, started_at, completed_at, resolution, (photo_key IS NOT NULL) AS has_photo FROM maintenance_records WHERE equipment_id=$1 ORDER BY reported_at DESC`, [id]);
  const usage = await one<any>(ctx.db,
    `SELECT count(*) FILTER (WHERE event_type='ISSUED')::int AS times_issued,
            count(*) FILTER (WHERE event_type='MAINTENANCE_COMPLETED')::int AS times_repaired FROM equipment_events WHERE equipment_id=$1`, [id]);
  return { ...toCamel(e), events: toCamelAll(events), maintenance: toCamelAll(maint), usage: toCamel(usage) };
}

export async function createEquipment(ctx: Ctx, i: { code: string; category?: string; size?: string | null; condition?: 'NEW' | 'GOOD' | 'FAIR' | 'POOR'; location?: string | null }) {
  assertCan(ctx, 'equipment.manage');
  const r = await ctx.db.query(
    `INSERT INTO equipment (venue_id, code, category, size, condition, location, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$7) RETURNING *`,
    [ctx.venueId, i.code.trim().toUpperCase(), i.category ?? 'SKATE', i.size ?? null, i.condition ?? 'GOOD', i.location ?? null, ctx.now]);
  await recordEquipmentEvent(ctx, r.rows[0].id, 'CREATED', { to: 'AVAILABLE' });
  await audit(ctx, { action: 'equipment.created', entityType: 'equipment', entityId: r.rows[0].id, after: { code: r.rows[0].code } });
  return toCamel(r.rows[0]);
}

/** Lock + issue units to a session. Caller must already hold the session row lock (order: session -> equipment). */
export async function assignEquipmentTx(ctx: Ctx, session: any, equipmentIds: string[]) {
  const ids = [...new Set(equipmentIds)].sort();
  const issued: { id: string; code: string }[] = [];
  for (const id of ids) {
    const e = await one<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId]);
    if (!e) throw E.notFound('Equipment');
    if (e.status !== 'AVAILABLE') {
      const why = e.status === 'ISSUED' ? 'is no longer available.' : `is not available (${e.status.toLowerCase().replace('_', ' ')}).`;
      throw E.conflict('EQUIPMENT_UNAVAILABLE', `${e.code} ${why}`, { equipmentId: id, status: e.status });
    }
    await ctx.db.query(
      `INSERT INTO equipment_assignments (venue_id, equipment_id, session_id, customer_id, assigned_by, assigned_at, device_id) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [ctx.venueId, id, session.id, session.customer_id, ctx.user?.id ?? null, ctx.now, ctx.deviceId]);
    await setStatus(ctx, e, 'ISSUED', 'ISSUED', { sessionId: session.id }, session.id);
    await emit(ctx, 'EQUIPMENT_ASSIGNED', 'equipment', id, { equipmentId: id, code: e.code, sessionId: session.id });
    await audit(ctx, { action: 'equipment.assigned', entityType: 'equipment', entityId: id, after: { code: e.code, sessionId: session.id, customerId: session.customer_id } });
    issued.push({ id, code: e.code });
  }
  return issued;
}

export async function assignEquipment(ctx: Ctx, equipmentId: string, sessionId: string) {
  assertCan(ctx, 'equipment.assign');
  const s = await lockOne<any>(ctx.db, 'SELECT * FROM sessions WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [sessionId, ctx.venueId], 'Session');
  if (!EQUIPMENT_HOLDING_STATUSES.includes(s.status)) {
    throw E.conflict('SESSION_NOT_ELIGIBLE', `Equipment can only be issued to a checked-in or active session (this one is ${s.status.toLowerCase().replace('_', ' ')}).`);
  }
  const [issued] = await assignEquipmentTx(ctx, s, [equipmentId]);
  return { equipmentId, code: issued.code, sessionId };
}

export async function returnEquipment(ctx: Ctx, equipmentId: string, input: { condition: 'GOOD' | 'DAMAGED'; note?: string | null }) {
  assertCan(ctx, 'equipment.return');
  const a0 = await one<any>(ctx.db, 'SELECT session_id FROM equipment_assignments WHERE equipment_id=$1 AND returned_at IS NULL', [equipmentId]);
  if (!a0) {
    const e0 = await one<any>(ctx.db, 'SELECT code FROM equipment WHERE id=$1 AND venue_id=$2', [equipmentId, ctx.venueId]);
    if (!e0) throw E.notFound('Equipment');
    throw E.conflict('EQUIPMENT_NOT_ISSUED', `${e0.code} is not currently issued to anyone.`);
  }
  const s = await lockOne<any>(ctx.db, 'SELECT * FROM sessions WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [a0.session_id, ctx.venueId], 'Session');
  const e = await lockOne<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [equipmentId, ctx.venueId], 'Equipment');
  const a = await one<any>(ctx.db, 'SELECT id FROM equipment_assignments WHERE equipment_id=$1 AND returned_at IS NULL FOR NO KEY UPDATE', [equipmentId]);
  if (!a) throw E.conflict('EQUIPMENT_NOT_ISSUED', `${e.code} was just returned by another staff member.`);
  const settings = await getSettings(ctx.db, ctx.venueId);
  await ctx.db.query(`UPDATE equipment_assignments SET returned_at=$2, returned_by=$3, return_condition=$4 WHERE id=$1`, [a.id, ctx.now, ctx.user?.id ?? null, input.condition]);
  await recordEquipmentEvent(ctx, equipmentId, 'RETURNED', { from: e.status, to: e.status, sessionId: s.id, meta: { condition: input.condition } });
  if (input.condition === 'DAMAGED') {
    await setStatus(ctx, e, 'DAMAGED', 'DAMAGED', { note: input.note ?? null, reportedOnReturn: true }, s.id);
    await ctx.db.query(`INSERT INTO maintenance_records (venue_id, equipment_id, issue, status, reported_by, reported_at) VALUES ($1,$2,$3,'OPEN',$4,$5)`,
      [ctx.venueId, equipmentId, input.note?.trim() || 'Damaged on return', ctx.user?.id ?? null, ctx.now]);
    await emit(ctx, 'EQUIPMENT_DAMAGED', 'equipment', equipmentId, { equipmentId, code: e.code });
  } else {
    await setStatus(ctx, e, settings.inspectOnReturn ? 'RETURNED' : 'AVAILABLE', settings.inspectOnReturn ? 'AWAITING_INSPECTION' : 'RETURNED_TO_STOCK', {}, s.id);
  }
  await emit(ctx, 'EQUIPMENT_RETURNED', 'equipment', equipmentId, { equipmentId, code: e.code, sessionId: s.id, condition: input.condition });
  await audit(ctx, { action: 'equipment.returned', entityType: 'equipment', entityId: equipmentId, after: { code: e.code, sessionId: s.id, condition: input.condition } });
  let visitCompleted = false;
  if (TERMINAL_STATUSES.includes(s.status) || ['COMPLETED', 'EARLY_EXIT'].includes(s.status)) visitCompleted = await completeVisitIfDone(ctx, s.visit_id);
  if (visitCompleted) {
    await ctx.db.query(`INSERT INTO session_events (venue_id, session_id, visit_id, event_type, actor_user_id, device_id, occurred_at, request_id)
      VALUES ($1,$2,$3,'VISIT_COMPLETED',$4,$5,$6,$7)`, [ctx.venueId, s.id, s.visit_id, ctx.user?.id ?? null, ctx.deviceId, ctx.now, ctx.requestId]);
    await emit(ctx, 'VISIT_COMPLETED', 'visit', s.visit_id, { visitId: s.visit_id });
  }
  return { equipmentId, code: e.code, status: e.status, visitCompleted };
}

export async function markInspected(ctx: Ctx, equipmentId: string) {
  assertCan(ctx, 'equipment.return');
  const e = await lockOne<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [equipmentId, ctx.venueId], 'Equipment');
  assertEqTransition(e, 'AVAILABLE', 'be marked available');
  if (e.status !== 'RETURNED') throw E.conflict('EQUIPMENT_INVALID_TRANSITION', `${e.code} is not waiting for inspection.`);
  await setStatus(ctx, e, 'AVAILABLE', 'INSPECTED');
  await emit(ctx, 'EQUIPMENT_STATUS_CHANGED', 'equipment', equipmentId, { equipmentId, status: 'AVAILABLE' });
  return { equipmentId, status: 'AVAILABLE' };
}

export async function reportDamage(ctx: Ctx, equipmentId: string, input: { issue: string; startMaintenance?: boolean }) {
  assertCan(ctx, 'equipment.maintenance');
  const e = await lockOne<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [equipmentId, ctx.venueId], 'Equipment');
  if (e.status === 'ISSUED') throw E.conflict('EQUIPMENT_ISSUED', `${e.code} is currently with a customer. Return it first and mark it as damaged on return.`);
  assertEqTransition(e, 'DAMAGED', 'be reported damaged');
  await setStatus(ctx, e, 'DAMAGED', 'DAMAGED', { issue: input.issue });
  const rec = (await ctx.db.query(`INSERT INTO maintenance_records (venue_id, equipment_id, issue, status, reported_by, reported_at) VALUES ($1,$2,$3,'OPEN',$4,$5) RETURNING id`,
    [ctx.venueId, equipmentId, input.issue.trim(), ctx.user?.id ?? null, ctx.now])).rows[0];
  if (input.startMaintenance !== false) {
    await setStatus(ctx, e, 'MAINTENANCE', 'MAINTENANCE_STARTED', { recordId: rec.id });
    await ctx.db.query(`UPDATE maintenance_records SET status='IN_PROGRESS', started_at=$2 WHERE id=$1`, [rec.id, ctx.now]);
  }
  await audit(ctx, { action: 'equipment.damage_reported', entityType: 'equipment', entityId: equipmentId, after: { code: e.code, issue: input.issue, status: e.status } });
  await emit(ctx, 'EQUIPMENT_DAMAGED', 'equipment', equipmentId, { equipmentId, code: e.code });
  return { equipmentId, status: e.status, maintenanceRecordId: rec.id };
}

export async function startMaintenance(ctx: Ctx, equipmentId: string) {
  assertCan(ctx, 'equipment.maintenance');
  const e = await lockOne<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [equipmentId, ctx.venueId], 'Equipment');
  assertEqTransition(e, 'MAINTENANCE', 'go to maintenance');
  await setStatus(ctx, e, 'MAINTENANCE', 'MAINTENANCE_STARTED');
  await ctx.db.query(`UPDATE maintenance_records SET status='IN_PROGRESS', started_at=$2 WHERE id = (SELECT id FROM maintenance_records WHERE equipment_id=$1 AND status='OPEN' ORDER BY reported_at DESC LIMIT 1)`, [equipmentId, ctx.now]);
  await audit(ctx, { action: 'equipment.maintenance_started', entityType: 'equipment', entityId: equipmentId, after: { code: e.code } });
  await emit(ctx, 'EQUIPMENT_STATUS_CHANGED', 'equipment', equipmentId, { equipmentId, status: 'MAINTENANCE' });
  return { equipmentId, status: 'MAINTENANCE' };
}

export async function completeMaintenance(ctx: Ctx, equipmentId: string, input: { resolution?: string | null }) {
  assertCan(ctx, 'equipment.maintenance');
  const e = await lockOne<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [equipmentId, ctx.venueId], 'Equipment');
  if (!['MAINTENANCE', 'OUT_OF_SERVICE'].includes(e.status)) {
    throw E.conflict('EQUIPMENT_INVALID_TRANSITION', `${e.code} is not in maintenance (it is ${e.status.toLowerCase().replace('_', ' ')}).`);
  }
  const from = e.status;
  await ctx.db.query(`UPDATE maintenance_records SET status='COMPLETED', completed_at=$2, completed_by=$3, resolution=$4 WHERE equipment_id=$1 AND status <> 'COMPLETED'`,
    [equipmentId, ctx.now, ctx.user?.id ?? null, input.resolution ?? null]);
  await setStatus(ctx, e, 'AVAILABLE', from === 'MAINTENANCE' ? 'MAINTENANCE_COMPLETED' : 'RETURNED_TO_SERVICE', { resolution: input.resolution ?? null });
  if (from === 'MAINTENANCE') await recordEquipmentEvent(ctx, equipmentId, 'RETURNED_TO_SERVICE', { from: 'MAINTENANCE', to: 'AVAILABLE' });
  await audit(ctx, { action: 'equipment.returned_to_service', entityType: 'equipment', entityId: equipmentId, after: { code: e.code, resolution: input.resolution ?? null } });
  await emit(ctx, 'EQUIPMENT_STATUS_CHANGED', 'equipment', equipmentId, { equipmentId, status: 'AVAILABLE' });
  return { equipmentId, status: 'AVAILABLE' };
}

export async function markOutOfService(ctx: Ctx, equipmentId: string, input: { reason: string }) {
  assertCan(ctx, 'equipment.maintenance');
  const e = await lockOne<any>(ctx.db, 'SELECT * FROM equipment WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [equipmentId, ctx.venueId], 'Equipment');
  if (e.status === 'ISSUED') throw E.conflict('EQUIPMENT_ISSUED', `${e.code} is currently with a customer. Return it first.`);
  assertEqTransition(e, 'OUT_OF_SERVICE', 'be taken out of service');
  await setStatus(ctx, e, 'OUT_OF_SERVICE', 'OUT_OF_SERVICE', { reason: input.reason });
  await audit(ctx, { action: 'equipment.out_of_service', entityType: 'equipment', entityId: equipmentId, reason: input.reason, after: { code: e.code } });
  await emit(ctx, 'EQUIPMENT_STATUS_CHANGED', 'equipment', equipmentId, { equipmentId, status: 'OUT_OF_SERVICE' });
  return { equipmentId, status: 'OUT_OF_SERVICE' };
}

export async function attachMaintenancePhoto(ctx: Ctx, equipmentId: string, recordId: string | null, bytes: Buffer, written: { keys: string[] }) {
  assertCan(ctx, 'equipment.maintenance');
  const rec = recordId
    ? await one<any>(ctx.db, 'SELECT id FROM maintenance_records WHERE id=$1 AND equipment_id=$2 AND venue_id=$3 FOR NO KEY UPDATE', [recordId, equipmentId, ctx.venueId])
    : await one<any>(ctx.db, `SELECT id FROM maintenance_records WHERE equipment_id=$1 AND venue_id=$2 AND status <> 'COMPLETED' ORDER BY reported_at DESC LIMIT 1 FOR NO KEY UPDATE`, [equipmentId, ctx.venueId]);
  if (!rec) throw E.notFound('Maintenance record');
  const img = validateImage(bytes);
  const key = newStorageKey(ctx.venueId, 'maintenance', img.ext);
  await storage.put(key, img.bytes);
  written.keys.push(key);
  await ctx.db.query('UPDATE maintenance_records SET photo_key=$2, photo_mime=$3 WHERE id=$1', [rec.id, key, img.mime]);
  await audit(ctx, { action: 'equipment.damage_photo_added', entityType: 'maintenance_record', entityId: rec.id, after: { sizeBytes: img.size } });
  return { recordId: rec.id };
}
