import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit } from '../shared/events.js';
import { one, many } from '../db.js';
import { toCamel, toCamelAll, lockOne } from './util.js';
import { nextCounter } from './customers.js';
import { newStorageKey, storage } from '../storage/index.js';
import { validateImage } from '../storage/image.js';
import { LATEST_PHOTO_SQL } from './photos.js';
import * as incidents from './incidents.js';

export type ShoeClaimStatus = 'STORED' | 'RETURN_PENDING' | 'RETURNED' | 'MISSING' | 'DISPUTED';

/** Short, speakable, searchable claim number ("LS-4827"). Loops on the rare chance a wrapped
 *  counter collides with another still-active claim (enforced again by a DB unique index). */
async function genClaimNumber(ctx: Ctx): Promise<string> {
  for (let i = 0; i < 20; i++) {
    const n = await nextCounter(ctx, 'shoe');
    const candidate = `LS-${String(n % 10000).padStart(4, '0')}`;
    const clash = await one(ctx.db, `SELECT 1 FROM shoe_claims WHERE venue_id=$1 AND claim_number=$2 AND status <> 'RETURNED'`, [ctx.venueId, candidate]);
    if (!clash) return candidate;
  }
  throw E.conflict('CLAIM_NUMBER_EXHAUSTED', 'Could not generate a free claim number. Please try again.');
}

export interface CreateShoeClaimInput { customerId: string; visitId: string; sessionId?: string | null }

/** Photo + claim creation happens atomically, same pattern as a customer photo upload. */
export async function createShoeClaim(ctx: Ctx, input: CreateShoeClaimInput, bytes: Buffer, written: { keys: string[] }) {
  assertCan(ctx, 'shoeclaim.manage');
  const cust = await one<any>(ctx.db, 'SELECT id, full_name FROM customers WHERE id=$1 AND venue_id=$2', [input.customerId, ctx.venueId]);
  if (!cust) throw E.notFound('Customer');
  const visit = await one<any>(ctx.db, 'SELECT id FROM visits WHERE id=$1 AND venue_id=$2', [input.visitId, ctx.venueId]);
  if (!visit) throw E.notFound('Visit');
  if (input.sessionId) {
    const s = await one(ctx.db, 'SELECT 1 FROM sessions WHERE id=$1 AND venue_id=$2', [input.sessionId, ctx.venueId]);
    if (!s) throw E.notFound('Session');
  }
  const img = validateImage(bytes);
  const key = newStorageKey(ctx.venueId, 'shoe', img.ext);
  await storage.put(key, img.bytes);
  written.keys.push(key);
  const claimNumber = await genClaimNumber(ctx);
  const r = await ctx.db.query(
    `INSERT INTO shoe_claims (venue_id, claim_number, customer_id, visit_id, session_id, photo_key, photo_mime, status, created_by, device_id, created_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,'STORED',$8,$9,$10,$10) RETURNING *`,
    [ctx.venueId, claimNumber, input.customerId, input.visitId, input.sessionId ?? null, key, img.mime, ctx.user?.id ?? null, ctx.deviceId, ctx.now]);
  const claim = r.rows[0];
  await audit(ctx, { action: 'shoe_claim.created', entityType: 'shoe_claim', entityId: claim.id, after: { claimNumber, customerId: input.customerId, visitId: input.visitId } });
  await emit(ctx, 'SHOE_CLAIM_CREATED', 'shoe_claim', claim.id, { claimId: claim.id, claimNumber, customerId: input.customerId, visitId: input.visitId });
  return toCamel(claim);
}

/** Lets a session created after the shoe photo (the usual check-in order) be linked back to its claim. */
export async function attachSessionToClaim(ctx: Ctx, claimId: string, sessionId: string) {
  await ctx.db.query(`UPDATE shoe_claims SET session_id=$2, updated_at=$3 WHERE id=$1 AND venue_id=$4 AND session_id IS NULL`, [claimId, sessionId, ctx.now, ctx.venueId]);
}

const CLAIM_VIEW_SQL = (canPhotos: boolean) => `
  SELECT sc.*, c.full_name AS customer_name, ${canPhotos ? LATEST_PHOTO_SQL : 'NULL::uuid'} AS customer_photo_id,
         v.visit_number, s.status AS session_status, s.scheduled_end_at AS session_scheduled_end_at,
         COALESCE((SELECT string_agg(e.code, ', ' ORDER BY e.code) FROM equipment_assignments ea JOIN equipment e ON e.id=ea.equipment_id WHERE ea.session_id=sc.session_id AND ea.returned_at IS NULL), '') AS equipment
    FROM shoe_claims sc JOIN customers c ON c.id=sc.customer_id JOIN visits v ON v.id=sc.visit_id LEFT JOIN sessions s ON s.id=sc.session_id`;

export async function listShoeClaims(ctx: Ctx, opts: { active?: boolean } = {}) {
  assertCan(ctx, 'shoeclaim.manage');
  const where = opts.active === false ? 'sc.venue_id=$1' : `sc.venue_id=$1 AND sc.status <> 'RETURNED'`;
  const rows = await many<any>(ctx.db, `${CLAIM_VIEW_SQL(can(ctx, 'customer.read'))} WHERE ${where} ORDER BY sc.created_at DESC LIMIT 500`, [ctx.venueId]);
  return { items: toCamelAll(rows), onShelf: rows.filter((r) => r.status !== 'RETURNED').length };
}

export async function getShoeClaim(ctx: Ctx, id: string) {
  assertCan(ctx, 'shoeclaim.manage');
  const r = await one<any>(ctx.db, `${CLAIM_VIEW_SQL(can(ctx, 'customer.read'))} WHERE sc.id=$1 AND sc.venue_id=$2`, [id, ctx.venueId]);
  if (!r) throw E.notFound('Shoe claim');
  return toCamel(r);
}

/** Staff type in the claim number verbally or from memory ("LS-4827") to pull up the return screen. */
export async function findShoeClaimByNumber(ctx: Ctx, claimNumber: string) {
  assertCan(ctx, 'shoeclaim.manage');
  const normalized = claimNumber.trim().toUpperCase().replace(/^LS-?/, 'LS-');
  const r = await one<any>(ctx.db, `${CLAIM_VIEW_SQL(can(ctx, 'customer.read'))} WHERE sc.venue_id=$1 AND sc.claim_number=$2 ORDER BY sc.created_at DESC LIMIT 1`, [ctx.venueId, normalized]);
  if (!r) throw E.notFound('Shoe claim');
  return toCamel(r);
}

export async function returnShoeClaim(ctx: Ctx, id: string) {
  assertCan(ctx, 'shoeclaim.manage');
  const claim = await lockOne<any>(ctx.db, 'SELECT * FROM shoe_claims WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Shoe claim');
  if (claim.status === 'RETURNED') throw E.conflict('ALREADY_RETURNED', 'These shoes were already returned.');
  if (claim.status === 'MISSING') throw E.conflict('CLAIM_MISSING', 'This claim is marked missing. Resolve the incident first.');
  const r = await ctx.db.query(`UPDATE shoe_claims SET status='RETURNED', returned_at=$2, returned_by=$3, updated_at=$2 WHERE id=$1 RETURNING *`, [id, ctx.now, ctx.user?.id ?? null]);
  await audit(ctx, { action: 'shoe_claim.returned', entityType: 'shoe_claim', entityId: id, after: { claimNumber: claim.claim_number } });
  await emit(ctx, 'SHOE_CLAIM_RETURNED', 'shoe_claim', id, { claimId: id, claimNumber: claim.claim_number, customerId: claim.customer_id });
  return toCamel(r.rows[0]);
}

export interface ReportShoeIssueInput {
  type: 'SHOE_MISMATCH' | 'SHOE_MISSING' | 'SHOE_DAMAGED' | 'OTHER';
  description: string;
}

/** An operational alert, never an automatic accusation: this opens an ordinary incident for a
 *  manager to look into, it does not by itself declare theft or close the claim. */
export async function reportShoeIssue(ctx: Ctx, id: string, input: ReportShoeIssueInput) {
  assertCan(ctx, 'shoeclaim.manage');
  const claim = await lockOne<any>(ctx.db, 'SELECT * FROM shoe_claims WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Shoe claim');
  const inc = await incidents.createIncident(ctx, {
    customerId: claim.customer_id, sessionId: claim.session_id,
    incidentType: input.type, severity: input.type === 'SHOE_MISSING' ? 'SERIOUS' : 'MODERATE',
    description: input.description, shoeClaimId: id,
  } as any);
  const newStatus: ShoeClaimStatus = input.type === 'SHOE_MISSING' ? 'MISSING' : 'DISPUTED';
  await ctx.db.query(`UPDATE shoe_claims SET status=$2, updated_at=$3 WHERE id=$1`, [id, newStatus, ctx.now]);
  await audit(ctx, { action: `shoe_claim.${input.type.toLowerCase()}_reported`, entityType: 'shoe_claim', entityId: id, after: { incidentId: (inc as any).id, status: newStatus } });
  return { claimId: id, status: newStatus, incidentId: (inc as any).id, incidentNumber: (inc as any).incidentNumber };
}
