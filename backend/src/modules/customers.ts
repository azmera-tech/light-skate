import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { normalizePhone } from '../shared/phone.js';
import { getSettings } from '../settings.js';
import { many, one, type Queryable } from '../db.js';
import { toCamel, toCamelAll, lockOne } from './util.js';
import { LATEST_PHOTO_SQL } from './photos.js';
import { waiverStatus } from './waivers.js';
import { storage } from '../storage/index.js';
import { clock } from '../shared/clock.js';
import { LIVE_STATUSES } from './sessions-machine.js';

export function isMinor(dob: string | null, minorAge: number, at: Date = clock.now()): boolean {
  if (!dob) return false;
  const d = new Date(dob + 'T00:00:00Z');
  const cutoff = new Date(Date.UTC(at.getUTCFullYear() - minorAge, at.getUTCMonth(), at.getUTCDate()));
  return d > cutoff;
}

export const customerNumber = (n: number) => `LS-C${String(n).padStart(6, '0')}`;

export interface CreateCustomerInput {
  fullName: string;
  phone: string;
  email?: string | null;
  dateOfBirth?: string | null;
  notes?: string | null;
  emergencyContact?: { name: string; phone: string; relationship?: string | null; isGuardian?: boolean } | null;
  /** Staff confirmed this is a different person from the suggested duplicate(s). */
  confirmDistinct?: boolean;
}

export async function nextCounter(ctx: Ctx, scope: string): Promise<number> {
  const r = await ctx.db.query(
    `INSERT INTO counters (venue_id, scope, n) VALUES ($1,$2,1)
     ON CONFLICT (venue_id, scope) DO UPDATE SET n = counters.n + 1 RETURNING n`, [ctx.venueId, scope]);
  return r.rows[0].n;
}

export async function findPhoneMatches(q: Queryable, venueId: string, e164: string, canSeePhotos: boolean) {
  const rows = await many<any>(q,
    `SELECT c.id, c.customer_no, c.full_name, c.phone_e164,
            (SELECT max(v.created_at) FROM visits v WHERE v.customer_id = c.id) AS last_visit_at,
            ${canSeePhotos ? LATEST_PHOTO_SQL : 'NULL::uuid'} AS photo_id
       FROM customers c WHERE c.venue_id=$1 AND c.phone_e164=$2 AND c.status <> 'ERASED' ORDER BY c.registered_at LIMIT 10`, [venueId, e164]);
  return rows.map((r) => ({ ...toCamel(r), customerCode: customerNumber(r.customer_no) }));
}

export async function createCustomer(ctx: Ctx, input: CreateCustomerInput) {
  assertCan(ctx, 'customer.create');
  const e164 = normalizePhone(input.phone);
  if (!e164) throw E.unprocessable('INVALID_PHONE', 'That phone number is not valid. Use a format like 0912345678 or +251912345678.');
  if (input.emergencyContact && !normalizePhone(input.emergencyContact.phone)) {
    throw E.unprocessable('INVALID_PHONE', "The emergency contact's phone number is not valid.");
  }
  const settings = await getSettings(ctx.db, ctx.venueId);
  if (input.dateOfBirth && Date.parse(input.dateOfBirth) > ctx.now.getTime()) throw E.unprocessable('INVALID_DOB', 'Date of birth cannot be in the future.');

  // Serialise creation per phone so two tablets cannot both miss each other's new record.
  await ctx.db.query('SELECT pg_advisory_xact_lock(hashtext($1))', [ctx.venueId + ':' + e164]);
  if (!input.confirmDistinct) {
    const matches = await findPhoneMatches(ctx.db, ctx.venueId, e164, can(ctx, 'customer.read'));
    if (matches.length) {
      throw E.conflict('POSSIBLE_DUPLICATE', 'Possible existing customer found.', { candidates: matches });
    }
  }
  const no = await nextCounter(ctx, 'customer');
  const r = await ctx.db.query(
    `INSERT INTO customers (venue_id, customer_no, full_name, phone_e164, phone_raw, email, date_of_birth, notes, registered_at, created_by, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$9) RETURNING id`,
    [ctx.venueId, no, input.fullName.trim(), e164, input.phone.trim(), input.email?.trim() || null, input.dateOfBirth || null, input.notes?.trim() || null, ctx.now, ctx.user?.id ?? null]);
  const id = r.rows[0].id as string;
  if (input.emergencyContact) {
    const ec = input.emergencyContact;
    await ctx.db.query(`INSERT INTO emergency_contacts (customer_id, name, phone, relationship, is_guardian) VALUES ($1,$2,$3,$4,$5)`,
      [id, ec.name.trim(), normalizePhone(ec.phone), ec.relationship ?? null, !!ec.isGuardian]);
  }
  await audit(ctx, {
    action: 'customer.created', entityType: 'customer', entityId: id,
    after: { customerNo: no, fullName: input.fullName.trim(), phone: e164, minor: isMinor(input.dateOfBirth ?? null, settings.minorAgeYears), confirmedDistinct: !!input.confirmDistinct },
  });
  return { id, customerCode: customerNumber(no), phone: e164 };
}

export async function searchCustomers(ctx: Ctx | { db: Queryable; venueId: string; canSeePhotos: boolean }, query: string, limit = 20) {
  const q = query.trim();
  if (q.length < 2) return [];
  const db = (ctx as any).db as Queryable;
  const canPhotos = 'canSeePhotos' in ctx ? ctx.canSeePhotos : can(ctx as Ctx, 'customer.read');
  const conds: string[] = [];
  const params: unknown[] = [ctx.venueId];
  const digits = q.replace(/[^\d+]/g, '');
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(q)) {
    params.push(q); conds.push(`c.id = $${params.length}`);
  }
  const codeMatch = /^(?:LS-?)?C?0*(\d{1,9})$/i.exec(q);
  if (codeMatch && /^(LS-?)?C/i.test(q)) { params.push(Number(codeMatch[1])); conds.push(`c.customer_no = $${params.length}`); }
  if (digits.replace('+', '').length >= 3) {
    let d = digits.replace('+', '');
    if (d.startsWith('00251')) d = d.slice(5); else if (d.startsWith('251')) d = d.slice(3); else if (d.startsWith('0')) d = d.slice(1);
    params.push('%' + d + '%'); conds.push(`c.phone_e164 LIKE $${params.length}`);
  }
  if (/\D/.test(q.replace(/[\s+-]/g, ''))) { params.push('%' + q.replace(/[%_\\]/g, (m) => '\\' + m) + '%'); conds.push(`c.full_name ILIKE $${params.length}`); }
  if (!conds.length) return [];
  params.push(Math.min(limit, 50));
  const rows = await many<any>(db,
    `SELECT c.id, c.customer_no, c.full_name, c.phone_e164, c.status,
            (SELECT max(v.created_at) FROM visits v WHERE v.customer_id = c.id) AS last_visit_at,
            (SELECT count(*)::int FROM visits v WHERE v.customer_id = c.id) AS visit_count,
            EXISTS (SELECT 1 FROM sessions s WHERE s.customer_id=c.id AND s.status = ANY('{${LIVE_STATUSES.join(',')}}')) AS is_active,
            ${canPhotos ? LATEST_PHOTO_SQL : 'NULL::uuid'} AS photo_id
       FROM customers c WHERE c.venue_id = $1 AND c.status <> 'ERASED' AND (${conds.join(' OR ')})
      ORDER BY c.full_name LIMIT $${params.length}`, params);
  return rows.map((r) => ({ ...toCamel(r), customerCode: customerNumber(r.customer_no) }));
}

export async function listCustomers(ctx: Ctx, opts: { limit: number; offset: number }) {
  assertCan(ctx, 'customer.read');
  const rows = await many<any>(ctx.db,
    `SELECT c.id, c.customer_no, c.full_name, c.phone_e164, c.status, c.registered_at,
            (SELECT max(v.created_at) FROM visits v WHERE v.customer_id = c.id) AS last_visit_at,
            (SELECT count(*)::int FROM visits v WHERE v.customer_id = c.id) AS visit_count,
            ${LATEST_PHOTO_SQL} AS photo_id
       FROM customers c WHERE c.venue_id=$1 AND c.status <> 'ERASED' ORDER BY c.registered_at DESC LIMIT $2 OFFSET $3`,
    [ctx.venueId, opts.limit, opts.offset]);
  return rows.map((r) => ({ ...toCamel(r), customerCode: customerNumber(r.customer_no) }));
}

export async function getCustomer(ctx: Ctx, id: string) {
  assertCan(ctx, 'customer.read');
  const c = await one<any>(ctx.db, `SELECT * FROM customers WHERE id=$1 AND venue_id=$2`, [id, ctx.venueId]);
  if (!c) throw E.notFound('Customer');
  const settings = await getSettings(ctx.db, ctx.venueId);
  const agg = await one<any>(ctx.db,
    `SELECT
       (SELECT count(*)::int FROM visits v WHERE v.customer_id=$1) AS visit_count,
       (SELECT max(v.created_at) FROM visits v WHERE v.customer_id=$1) AS last_visit_at,
       (SELECT COALESCE(SUM(GREATEST(0, EXTRACT(EPOCH FROM (COALESCE(s.actual_end_at, LEAST($2::timestamptz, s.scheduled_end_at)) - s.started_at))
                - CASE WHEN s.pause_counts_toward_time THEN 0 ELSE s.total_paused_seconds END)),0)::bigint
          FROM sessions s WHERE s.customer_id=$1 AND s.started_at IS NOT NULL) AS total_skating_seconds,
       (SELECT COALESCE(SUM(p.amount_minor - p.refunded_minor),0)::bigint FROM payments p
          WHERE p.customer_id=$1 AND p.status IN ('PAID','PARTIALLY_REFUNDED','REFUNDED')) AS total_spent_minor,
       (SELECT count(*)::int FROM equipment_assignments ea WHERE ea.customer_id=$1) AS equipment_issued_count`, [id, ctx.now]);
  const contacts = await many<any>(ctx.db, 'SELECT id, name, phone, relationship, is_guardian FROM emergency_contacts WHERE customer_id=$1 ORDER BY created_at', [id]);
  const live = await one<any>(ctx.db,
    `SELECT s.id, s.status, s.started_at, s.scheduled_end_at FROM sessions s WHERE s.customer_id=$1 AND s.status = ANY($2) LIMIT 1`, [id, LIVE_STATUSES]);
  const photoRow = await one<any>(ctx.db, `SELECT ${LATEST_PHOTO_SQL} AS id FROM customers c WHERE c.id=$1`, [id]);
  return {
    ...toCamel(c), customerCode: customerNumber(c.customer_no),
    isMinor: isMinor(c.date_of_birth, settings.minorAgeYears),
    photoId: photoRow?.id ?? null,
    emergencyContacts: toCamelAll(contacts),
    stats: {
      visitCount: agg.visit_count, lastVisitAt: agg.last_visit_at, totalSkatingSeconds: agg.total_skating_seconds,
      totalSpentMinor: agg.total_spent_minor, equipmentIssuedCount: agg.equipment_issued_count,
    },
    waiver: await waiverStatus(ctx.db, ctx.venueId, id),
    currentSession: live ? toCamel(live) : null,
    membership: null, // TODO(phase 3): memberships
  };
}

export async function updateCustomer(
  ctx: Ctx, id: string,
  patch: { fullName?: string; phone?: string; email?: string | null; dateOfBirth?: string | null; notes?: string | null; status?: 'ACTIVE' | 'BLOCKED' | 'ARCHIVED';
    emergencyContact?: { name: string; phone: string; relationship?: string | null; isGuardian?: boolean } | null },
) {
  assertCan(ctx, 'customer.update');
  const before = await lockOne<any>(ctx.db, 'SELECT * FROM customers WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Customer');
  if (before.status === 'ERASED') throw E.conflict('CUSTOMER_ERASED', 'This customer record has been erased.');
  if (patch.status && patch.status !== before.status && !can(ctx, 'session.correct') && !can(ctx, 'staff.manage')) {
    throw E.forbidden("You don't have permission to block or archive customers.");
  }
  const set: string[] = []; const params: unknown[] = [id, ctx.venueId];
  const add = (col: string, v: unknown) => { params.push(v); set.push(`${col} = $${params.length}`); };
  if (patch.fullName !== undefined) add('full_name', patch.fullName.trim());
  if (patch.phone !== undefined) {
    const e164 = normalizePhone(patch.phone);
    if (!e164) throw E.unprocessable('INVALID_PHONE', 'That phone number is not valid.');
    add('phone_e164', e164); add('phone_raw', patch.phone.trim());
  }
  if (patch.email !== undefined) add('email', patch.email?.trim() || null);
  if (patch.dateOfBirth !== undefined) add('date_of_birth', patch.dateOfBirth || null);
  if (patch.notes !== undefined) add('notes', patch.notes?.trim() || null);
  if (patch.status !== undefined) add('status', patch.status);
  if (set.length) {
    add('updated_at', ctx.now);
    await ctx.db.query(`UPDATE customers SET ${set.join(', ')} WHERE id=$1 AND venue_id=$2`, params);
  }
  if (patch.emergencyContact) {
    const ec = patch.emergencyContact;
    if (!normalizePhone(ec.phone)) throw E.unprocessable('INVALID_PHONE', "The emergency contact's phone number is not valid.");
    await ctx.db.query('DELETE FROM emergency_contacts WHERE customer_id=$1', [id]);
    await ctx.db.query(`INSERT INTO emergency_contacts (customer_id, name, phone, relationship, is_guardian) VALUES ($1,$2,$3,$4,$5)`,
      [id, ec.name.trim(), normalizePhone(ec.phone), ec.relationship ?? null, !!ec.isGuardian]);
  }
  const after = await one<any>(ctx.db, 'SELECT full_name, phone_e164, email, date_of_birth, notes, status FROM customers WHERE id=$1', [id]);
  await audit(ctx, {
    action: 'customer.updated', entityType: 'customer', entityId: id,
    before: { fullName: before.full_name, phone: before.phone_e164, email: before.email, dateOfBirth: before.date_of_birth, notes: before.notes, status: before.status },
    after: { fullName: after.full_name, phone: after.phone_e164, email: after.email, dateOfBirth: after.date_of_birth, notes: after.notes, status: after.status },
  });
  return { id };
}

/** Customer visit/session/payment timeline, derived entirely from real records. */
export async function customerHistory(ctx: Ctx, id: string, limit = 50) {
  assertCan(ctx, 'customer.read');
  const c = await one(ctx.db, 'SELECT 1 FROM customers WHERE id=$1 AND venue_id=$2', [id, ctx.venueId]);
  if (!c) throw E.notFound('Customer');
  const rows = await many<any>(ctx.db,
    `SELECT v.id AS visit_id, v.visit_number, v.local_date, v.status AS visit_status, v.created_at,
            s.id AS session_id, s.status AS session_status, s.product_name, s.started_at, s.scheduled_end_at, s.actual_end_at,
            s.current_duration_seconds,
            COALESCE((SELECT SUM(p.amount_minor - p.refunded_minor) FROM payments p WHERE p.visit_id=v.id AND p.status IN ('PAID','PARTIALLY_REFUNDED','REFUNDED')),0)::bigint AS paid_minor,
            COALESCE((SELECT string_agg(e.code, ', ' ORDER BY e.code) FROM equipment_assignments ea JOIN equipment e ON e.id=ea.equipment_id WHERE ea.session_id = s.id),'') AS equipment
       FROM visits v
       LEFT JOIN LATERAL (SELECT * FROM sessions s2 WHERE s2.visit_id = v.id ORDER BY s2.created_at DESC LIMIT 1) s ON true
      WHERE v.customer_id=$1 AND v.venue_id=$2 ORDER BY v.created_at DESC LIMIT $3`, [id, ctx.venueId, limit]);
  return rows.map(toCamel);
}

/** Privacy request: personal data is erased/anonymised; financial + audit records are retained (policy layer). */
export async function eraseCustomer(ctx: Ctx, id: string, reason: string) {
  assertCan(ctx, 'customer.delete');
  const c = await lockOne<any>(ctx.db, 'SELECT * FROM customers WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Customer');
  if (c.status === 'ERASED') return { id, alreadyErased: true };
  const live = await one(ctx.db, `SELECT 1 FROM sessions WHERE customer_id=$1 AND status = ANY($2)`, [id, LIVE_STATUSES]);
  if (live) throw E.conflict('CUSTOMER_ACTIVE', 'This customer is currently skating. End their session before erasing their data.');
  const photos = await many<any>(ctx.db, `SELECT id, storage_key FROM customer_photos WHERE customer_id=$1 AND status='ACTIVE'`, [id]);
  for (const p of photos) await storage.delete(p.storage_key);
  await ctx.db.query(`UPDATE customer_photos SET status='DELETED', deleted_at=$2 WHERE customer_id=$1 AND status='ACTIVE'`, [id, ctx.now]);
  await ctx.db.query('DELETE FROM emergency_contacts WHERE customer_id=$1', [id]);
  await ctx.db.query(`UPDATE waiver_acceptances SET signature_data=NULL, guardian_name=NULL, guardian_phone=NULL WHERE customer_id=$1`, [id]);
  await ctx.db.query(
    `UPDATE customers SET full_name='Erased customer', phone_e164=NULL, phone_raw=NULL, email=NULL, date_of_birth=NULL, notes=NULL,
            status='ERASED', erased_at=$2, updated_at=$2 WHERE id=$1`, [id, ctx.now]);
  await audit(ctx, {
    action: 'customer.erased', entityType: 'customer', entityId: id, reason,
    after: { photosDeleted: photos.length, retained: ['visits', 'sessions', 'payments', 'audit_logs'] },
  });
  return { id, photosDeleted: photos.length, retained: ['visits', 'sessions', 'payments', 'audit_logs'] };
}
