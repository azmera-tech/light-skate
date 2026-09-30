import type { Ctx } from '../shared/ctx.js';
import { assertCan } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { getSettings } from '../settings.js';
import { newStorageKey, storage, signFileToken, verifyFileToken } from '../storage/index.js';
import { validateImage } from '../storage/image.js';
import { config } from '../config.js';
import { pool, one } from '../db.js';
import { toCamel } from './util.js';
import { clock } from '../shared/clock.js';

export interface StoredPhoto { id: string; storageKey: string }

/** Validate + store a customer photo; metadata row is written in the caller's transaction. */
export async function storeCustomerPhoto(
  ctx: Ctx,
  input: { customerId: string; visitId?: string | null; purpose: 'PROFILE' | 'VISIT'; bytes: Buffer },
  written: { keys: string[] },
) {
  if (!(ctx.user!.permissions.has('customer.create') || ctx.user!.permissions.has('customer.update'))) {
    assertCan(ctx, 'customer.update');
  }
  const cust = await ctx.db.query(`SELECT id, status FROM customers WHERE id=$1 AND venue_id=$2 FOR KEY SHARE`, [input.customerId, ctx.venueId]);
  if (!cust.rows[0]) throw E.notFound('Customer');
  if (cust.rows[0].status === 'ERASED') throw E.conflict('CUSTOMER_ERASED', 'This customer record has been erased.');
  if (input.visitId) {
    const v = await ctx.db.query('SELECT 1 FROM visits WHERE id=$1 AND venue_id=$2 AND customer_id=$3', [input.visitId, ctx.venueId, input.customerId]);
    if (!v.rowCount) throw E.notFound('Visit');
  }
  const img = validateImage(input.bytes);
  const key = newStorageKey(ctx.venueId, 'customer', img.ext);
  await storage.put(key, img.bytes);
  written.keys.push(key);

  const settings = await getSettings(ctx.db, ctx.venueId);
  const days = input.purpose === 'PROFILE' ? settings.retention.profilePhotoDays : settings.retention.visitPhotoDays;
  const retentionUntil = days ? new Date(ctx.now.getTime() + days * 86400_000) : null;
  const r = await ctx.db.query(
    `INSERT INTO customer_photos (venue_id, customer_id, visit_id, purpose, storage_key, mime_type, size_bytes, width, height, sha256,
        captured_at, captured_by, device_id, retention_until)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
     RETURNING id, customer_id, visit_id, purpose, mime_type, size_bytes, width, height, captured_at, retention_until`,
    [ctx.venueId, input.customerId, input.visitId ?? null, input.purpose, key, img.mime, img.size, img.width, img.height, img.sha256,
      ctx.now, ctx.user?.id ?? null, ctx.deviceId, retentionUntil],
  );
  const photo = r.rows[0];
  await audit(ctx, {
    action: 'photo.captured', entityType: 'customer_photo', entityId: photo.id,
    after: { customerId: input.customerId, visitId: input.visitId ?? null, purpose: input.purpose, sizeBytes: img.size, retentionUntil },
  });
  return toCamel(photo);
}

export async function loadPhotoForUser(ctx: { venueId: string; userId: string; requestId: string; ip: string | null; deviceId: string | null }, photoId: string) {
  const p = await one<any>(pool, `SELECT id, venue_id, customer_id, storage_key, mime_type, status FROM customer_photos WHERE id=$1`, [photoId]);
  // Cross-venue access is indistinguishable from "not found".
  if (!p || p.venue_id !== ctx.venueId || p.status !== 'ACTIVE') throw E.notFound('Photo');
  const bytes = await storage.get(p.storage_key).catch(() => null);
  if (!bytes) throw E.notFound('Photo');
  // Sensitive-data access is audited, at most once per user+photo per 10 minutes to keep list screens quiet.
  await pool.query(
    `INSERT INTO audit_logs (venue_id, actor_user_id, action, entity_type, entity_id, device_id, request_id, ip)
     SELECT $1,$2,'photo.viewed','customer_photo',$3,$4,$5,$6
      WHERE NOT EXISTS (SELECT 1 FROM audit_logs WHERE actor_user_id=$2 AND action='photo.viewed' AND entity_id=$3 AND created_at > $7)`,
    [ctx.venueId, ctx.userId, photoId, ctx.deviceId, ctx.requestId, ctx.ip, new Date(clock.now().getTime() - 10 * 60_000)],
  );
  return { bytes, mime: p.mime_type as string };
}

export function issueSignedUrl(venueId: string, photoId: string) {
  const exp = Math.floor(Date.now() / 1000) + config.storage.signedUrlTtlSeconds;
  const sig = signFileToken(photoId, venueId, exp);
  return { url: `/api/v1/photos/${photoId}/signed?exp=${exp}&sig=${sig}`, expiresAt: new Date(exp * 1000).toISOString() };
}

export async function loadPhotoBySignature(photoId: string, exp: number, sig: string) {
  const p = await one<any>(pool, `SELECT id, venue_id, storage_key, mime_type, status FROM customer_photos WHERE id=$1`, [photoId]);
  if (!p || p.status !== 'ACTIVE' || !verifyFileToken(photoId, p.venue_id, exp, sig)) throw E.notFound('Photo');
  const bytes = await storage.get(p.storage_key).catch(() => null);
  if (!bytes) throw E.notFound('Photo');
  return { bytes, mime: p.mime_type as string };
}

/** Current profile photo id (latest active) for a customer, used by list screens. */
export const LATEST_PHOTO_SQL = `(SELECT cp.id FROM customer_photos cp WHERE cp.customer_id = c.id AND cp.status='ACTIVE'
   ORDER BY (cp.purpose='VISIT') DESC, cp.captured_at DESC LIMIT 1)`;
