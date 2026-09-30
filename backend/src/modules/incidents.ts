import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { AppError, E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit, recordIncidentEvent } from '../shared/events.js';
import { getVenue } from '../settings.js';
import { many, one } from '../db.js';
import { localDateIn } from '../shared/time.js';
import { toCamel, toCamelAll, lockOne } from './util.js';
import { nextCounter } from './customers.js';
import { newStorageKey, storage } from '../storage/index.js';
import { validateImage } from '../storage/image.js';

export type IncidentStatus = 'REPORTED' | 'ACKNOWLEDGED' | 'ACTION_TAKEN' | 'UNDER_REVIEW' | 'CLOSED';
const FLOW: Record<IncidentStatus, IncidentStatus[]> = {
  REPORTED: ['ACKNOWLEDGED', 'ACTION_TAKEN', 'UNDER_REVIEW'],
  ACKNOWLEDGED: ['ACTION_TAKEN', 'UNDER_REVIEW', 'CLOSED'],
  ACTION_TAKEN: ['UNDER_REVIEW', 'CLOSED'],
  UNDER_REVIEW: ['ACTION_TAKEN', 'CLOSED'],
  CLOSED: [],
};

export interface CreateIncidentInput {
  customerId?: string | null; sessionId?: string | null; occurredAt?: Date | null; location?: string | null;
  incidentType: string; severity: 'MINOR' | 'MODERATE' | 'SERIOUS' | 'CRITICAL'; description: string; actionTaken?: string | null; managerNotified?: boolean;
}

export async function createIncident(ctx: Ctx, i: CreateIncidentInput) {
  assertCan(ctx, 'incident.create');
  let customerId = i.customerId ?? null, visitId: string | null = null, sessionId = i.sessionId ?? null;
  if (sessionId) {
    const s = await one<any>(ctx.db, 'SELECT id, visit_id, customer_id FROM sessions WHERE id=$1 AND venue_id=$2', [sessionId, ctx.venueId]);
    if (!s) throw E.notFound('Session');
    visitId = s.visit_id; customerId = customerId ?? s.customer_id;
  }
  if (customerId) {
    const c = await one(ctx.db, 'SELECT 1 FROM customers WHERE id=$1 AND venue_id=$2', [customerId, ctx.venueId]);
    if (!c) throw E.notFound('Customer');
  }
  const occurred = i.occurredAt && i.occurredAt <= ctx.now ? i.occurredAt : ctx.now;
  const venue = await getVenue(ctx.db, ctx.venueId);
  const date = localDateIn(venue.timezone, ctx.now);
  const n = await nextCounter(ctx, 'incident:' + date);
  const number = `INC-${date.replace(/-/g, '')}-${String(n).padStart(3, '0')}`;
  const r = await ctx.db.query(
    `INSERT INTO incidents (venue_id, incident_number, customer_id, visit_id, session_id, occurred_at, location, incident_type, severity, description, action_taken,
        manager_notified, reported_by, device_id, created_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$15) RETURNING *`,
    [ctx.venueId, number, customerId, visitId, sessionId, occurred, i.location ?? null, i.incidentType, i.severity, i.description.trim(), i.actionTaken?.trim() ?? null,
      !!i.managerNotified, ctx.user?.id ?? null, ctx.deviceId, ctx.now]);
  const inc = r.rows[0];
  await recordIncidentEvent(ctx, inc.id, 'INCIDENT_REPORTED', { to: 'REPORTED', meta: { severity: i.severity, type: i.incidentType } });
  await audit(ctx, { action: 'incident.created', entityType: 'incident', entityId: inc.id, after: { incidentNumber: number, severity: i.severity, type: i.incidentType, customerId } });
  await emit(ctx, 'INCIDENT_REPORTED', 'incident', inc.id, { incidentId: inc.id, incidentNumber: number, severity: i.severity });
  return toCamel(inc);
}

const LIMITED_COLS = 'i.id, i.incident_number, i.occurred_at, i.incident_type, i.severity, i.status, i.location, i.created_at';

export async function listIncidents(ctx: Ctx, opts: { open?: boolean; limit?: number }) {
  const full = can(ctx, 'incident.read');
  if (!full && !can(ctx, 'incident.create')) assertCan(ctx, 'incident.read');
  const params: unknown[] = [ctx.venueId, opts.limit ?? 200];
  let where = 'i.venue_id=$1';
  if (opts.open) where += ` AND i.status <> 'CLOSED'`;
  // Ordinary staff see only a redacted row for incidents they reported themselves.
  if (!full) { params.push(ctx.user!.id); where += ` AND i.reported_by = $${params.length}`; }
  const rows = await many<any>(ctx.db,
    full
      ? `SELECT i.*, c.full_name AS customer_name, u.full_name AS reported_by_name FROM incidents i LEFT JOIN customers c ON c.id=i.customer_id LEFT JOIN users u ON u.id=i.reported_by WHERE ${where} ORDER BY i.occurred_at DESC LIMIT $2`
      : `SELECT ${LIMITED_COLS} FROM incidents i WHERE ${where} ORDER BY i.occurred_at DESC LIMIT $2`, params);
  return { redacted: !full, incidents: toCamelAll(rows) };
}

export async function getIncident(ctx: Ctx, id: string) {
  const full = can(ctx, 'incident.read');
  const inc = await one<any>(ctx.db,
    `SELECT i.*, c.full_name AS customer_name, u.full_name AS reported_by_name FROM incidents i LEFT JOIN customers c ON c.id=i.customer_id LEFT JOIN users u ON u.id=i.reported_by WHERE i.id=$1 AND i.venue_id=$2`, [id, ctx.venueId]);
  if (!inc) throw E.notFound('Incident');
  if (!full) {
    if (inc.reported_by !== ctx.user?.id) throw E.forbidden("You don't have permission to view incident details.");
    return { redacted: true, incident: toCamel({ id: inc.id, incident_number: inc.incident_number, occurred_at: inc.occurred_at, incident_type: inc.incident_type, severity: inc.severity, status: inc.status, location: inc.location }) };
  }
  const events = await many<any>(ctx.db, `SELECT ie.event_type, ie.from_status, ie.to_status, ie.occurred_at, ie.metadata, u.full_name AS actor_name FROM incident_events ie LEFT JOIN users u ON u.id=ie.actor_user_id WHERE ie.incident_id=$1 ORDER BY ie.id`, [id]);
  const att = await many<any>(ctx.db, `SELECT id, mime_type, size_bytes, uploaded_at FROM incident_attachments WHERE incident_id=$1 AND status='ACTIVE' ORDER BY uploaded_at`, [id]);
  return { redacted: false, incident: toCamel(inc), events: toCamelAll(events), attachments: toCamelAll(att) };
}

export async function transitionIncident(ctx: Ctx, id: string, input: { to: IncidentStatus; note?: string | null; actionTaken?: string | null }) {
  assertCan(ctx, 'incident.manage');
  const inc = await lockOne<any>(ctx.db, 'SELECT * FROM incidents WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Incident');
  if (!FLOW[inc.status as IncidentStatus].includes(input.to)) {
    throw new AppError(409, 'INCIDENT_INVALID_TRANSITION', `An incident that is ${inc.status.toLowerCase().replace('_', ' ')} cannot move to ${input.to.toLowerCase().replace('_', ' ')}.`);
  }
  if (input.to === 'CLOSED' && ['SERIOUS', 'CRITICAL'].includes(inc.severity) && !input.note?.trim()) {
    throw E.unprocessable('NOTE_REQUIRED', 'A closing note is required for serious or critical incidents.');
  }
  await ctx.db.query('UPDATE incidents SET status=$2, action_taken=COALESCE($3, action_taken), updated_at=$4 WHERE id=$1', [id, input.to, input.actionTaken?.trim() ?? null, ctx.now]);
  await recordIncidentEvent(ctx, id, `INCIDENT_${input.to}`, { from: inc.status, to: input.to, meta: { note: input.note ?? null } });
  await audit(ctx, { action: 'incident.status_changed', entityType: 'incident', entityId: id, before: { status: inc.status }, after: { status: input.to }, reason: input.note ?? null });
  await emit(ctx, 'INCIDENT_UPDATED', 'incident', id, { incidentId: id, status: input.to });
  return { id, status: input.to };
}

export async function attachIncidentPhoto(ctx: Ctx, incidentId: string, bytes: Buffer, written: { keys: string[] }) {
  if (!can(ctx, 'incident.create') && !can(ctx, 'incident.manage')) assertCan(ctx, 'incident.create');
  const inc = await lockOne<any>(ctx.db, 'SELECT id, reported_by FROM incidents WHERE id=$1 AND venue_id=$2 FOR KEY SHARE', [incidentId, ctx.venueId], 'Incident');
  if (!can(ctx, 'incident.manage') && inc.reported_by !== ctx.user?.id) throw E.forbidden("You can only add photos to incidents you reported.");
  const img = validateImage(bytes);
  const key = newStorageKey(ctx.venueId, 'incident', img.ext);
  await storage.put(key, img.bytes);
  written.keys.push(key);
  const r = await ctx.db.query(
    `INSERT INTO incident_attachments (venue_id, incident_id, storage_key, mime_type, size_bytes, width, height, sha256, uploaded_by, uploaded_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id`, [ctx.venueId, incidentId, key, img.mime, img.size, img.width, img.height, img.sha256, ctx.user?.id ?? null, ctx.now]);
  await recordIncidentEvent(ctx, incidentId, 'ATTACHMENT_ADDED', { meta: { attachmentId: r.rows[0].id } });
  await audit(ctx, { action: 'incident.attachment_added', entityType: 'incident', entityId: incidentId, after: { attachmentId: r.rows[0].id, sizeBytes: img.size } });
  return { id: r.rows[0].id };
}

export async function loadIncidentAttachment(ctx: Ctx, attachmentId: string) {
  assertCan(ctx, 'incident.read');
  const a = await one<any>(ctx.db, `SELECT storage_key, mime_type FROM incident_attachments WHERE id=$1 AND venue_id=$2 AND status='ACTIVE'`, [attachmentId, ctx.venueId]);
  if (!a) throw E.notFound('Attachment');
  return { bytes: await storage.get(a.storage_key), mime: a.mime_type as string };
}
