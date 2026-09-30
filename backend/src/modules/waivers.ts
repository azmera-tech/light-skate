import type { Ctx } from '../shared/ctx.js';
import { assertCan } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { getSettings } from '../settings.js';
import type { Queryable } from '../db.js';
import { many, one } from '../db.js';
import { toCamel, toCamelAll } from './util.js';
import { isMinor } from './customers.js';

export async function getCurrentWaiver(q: Queryable, venueId: string) {
  const v = await one<any>(q,
    `SELECT wv.id, wv.version, wv.title, wv.body, wv.language, wv.published_at, w.code
       FROM waiver_versions wv JOIN waivers w ON w.id = wv.waiver_id
      WHERE wv.venue_id = $1 AND wv.is_current AND w.code = 'STANDARD'`, [venueId]);
  return v ? toCamel(v) : null;
}

export async function listWaiverVersions(q: Queryable, venueId: string) {
  return toCamelAll(await many(q, `SELECT id, version, title, is_current, published_at FROM waiver_versions WHERE venue_id=$1 ORDER BY version DESC`, [venueId]));
}

/** Publishing never edits an old version: it inserts a new one and moves the `current` marker. */
export async function publishWaiverVersion(ctx: Ctx, input: { title: string; body: string; language?: string }) {
  assertCan(ctx, 'waiver.manage');
  let w = await one<any>(ctx.db, `SELECT id FROM waivers WHERE venue_id=$1 AND code='STANDARD' FOR NO KEY UPDATE`, [ctx.venueId]);
  if (!w) w = (await ctx.db.query(`INSERT INTO waivers (venue_id, code, name) VALUES ($1,'STANDARD','Skating rules & waiver') RETURNING id`, [ctx.venueId])).rows[0];
  const next = (await ctx.db.query('SELECT COALESCE(max(version),0)+1 AS v FROM waiver_versions WHERE waiver_id=$1', [w.id])).rows[0].v;
  await ctx.db.query('UPDATE waiver_versions SET is_current=false WHERE waiver_id=$1 AND is_current', [w.id]);
  const r = await ctx.db.query(
    `INSERT INTO waiver_versions (waiver_id, venue_id, version, language, title, body, is_current, published_at, published_by)
     VALUES ($1,$2,$3,$4,$5,$6,true,$7,$8) RETURNING id, version`,
    [w.id, ctx.venueId, next, input.language ?? 'en', input.title, input.body, ctx.now, ctx.user?.id ?? null]);
  await audit(ctx, { action: 'waiver.version_published', entityType: 'waiver_version', entityId: r.rows[0].id, after: { version: next, title: input.title } });
  return toCamel(r.rows[0]);
}

export async function waiverStatus(q: Queryable, venueId: string, customerId: string) {
  const settings = await getSettings(q, venueId);
  const current = await getCurrentWaiver(q, venueId);
  const cust = await one<any>(q, 'SELECT date_of_birth FROM customers WHERE id=$1 AND venue_id=$2', [customerId, venueId]);
  if (!cust) throw E.notFound('Customer');
  const minor = isMinor(cust.date_of_birth, settings.minorAgeYears);
  if (!settings.waiverRequired) return { required: false, currentVersionId: current?.id ?? null, accepted: true, acceptedAt: null, isMinor: minor, currentVersion: current?.version ?? null };
  if (!current) return { required: true, currentVersionId: null, accepted: false, acceptedAt: null, isMinor: minor, currentVersion: null };
  const acc = await one<any>(q,
    `SELECT accepted_at, for_minor, guardian_name FROM waiver_acceptances
      WHERE customer_id=$1 AND waiver_version_id=$2 AND status='ACCEPTED' ORDER BY accepted_at DESC LIMIT 1`, [customerId, current.id]);
  return {
    required: true, currentVersionId: current.id, currentVersion: current.version, isMinor: minor,
    accepted: !!acc && (!minor || (acc.for_minor && !!acc.guardian_name)),
    acceptedAt: acc?.accepted_at ?? null,
  };
}

export async function acceptWaiver(
  ctx: Ctx,
  customerId: string,
  input: { waiverVersionId?: string; visitId?: string | null; signatureData?: string | null; guardianName?: string | null; guardianPhone?: string | null },
) {
  const status = await waiverStatus(ctx.db, ctx.venueId, customerId);
  const current = await getCurrentWaiver(ctx.db, ctx.venueId);
  if (!current) throw E.conflict('NO_WAIVER', 'No waiver has been published for this venue yet.');
  if (input.waiverVersionId && input.waiverVersionId !== current.id) {
    throw E.conflict('WAIVER_OUTDATED', 'The waiver was updated. Please show the customer the latest version.');
  }
  if (status.isMinor && (!input.guardianName?.trim() || !input.guardianPhone?.trim())) {
    throw E.unprocessable('GUARDIAN_REQUIRED', 'This customer is a minor. A guardian name and phone number are required to accept the waiver.');
  }
  if (input.signatureData && input.signatureData.length > 200_000) throw E.badRequest('SIGNATURE_TOO_LARGE', 'The signature image is too large.');
  if (input.visitId) {
    const v = await ctx.db.query('SELECT 1 FROM visits WHERE id=$1 AND venue_id=$2 AND customer_id=$3', [input.visitId, ctx.venueId, customerId]);
    if (!v.rowCount) throw E.notFound('Visit');
  }
  const r = await ctx.db.query(
    `INSERT INTO waiver_acceptances (venue_id, customer_id, waiver_version_id, visit_id, accepted_at, accepted_by_staff, device_id, signature_data, for_minor, guardian_name, guardian_phone)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING id, accepted_at`,
    [ctx.venueId, customerId, current.id, input.visitId ?? null, ctx.now, ctx.user?.id ?? null, ctx.deviceId, input.signatureData ?? null,
      status.isMinor, input.guardianName?.trim() ?? null, input.guardianPhone?.trim() ?? null]);
  await audit(ctx, { action: 'waiver.accepted', entityType: 'waiver_acceptance', entityId: r.rows[0].id, after: { customerId, waiverVersion: current.version, forMinor: status.isMinor } });
  return { id: r.rows[0].id, acceptedAt: r.rows[0].accepted_at, waiverVersion: current.version };
}
