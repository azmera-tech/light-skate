import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit } from '../shared/events.js';
import { getSettings, getVenue } from '../settings.js';
import { many, one, withTx, pool, type Queryable } from '../db.js';
import { toCamel, toCamelAll, lockOne, secondsBetween } from './util.js';
import { nextCounter, customerNumber } from './customers.js';
import { normalizePhone } from '../shared/phone.js';
import { localDateIn, isValidDate } from '../shared/time.js';
import { formatMinor } from '../shared/money.js';
import { clock } from '../shared/clock.js';
import { newStorageKey, storage } from '../storage/index.js';
import { validateImage } from '../storage/image.js';

const OPEN = ['PENDING_PAYMENT', 'READY', 'ACTIVE', 'PAUSED'];

const requireOperate = (ctx: Ctx) => assertCan(ctx, 'playstation.operate');
function requireOperateOrManage(ctx: Ctx) {
  if (!can(ctx, 'playstation.operate') && !can(ctx, 'playstation.manage')) throw E.forbidden("You don't have access to the PlayStation module.");
}

async function event(ctx: Ctx, sessionId: string, type: string, meta: Record<string, unknown> = {}) {
  const r = await ctx.db.query(
    `INSERT INTO ps_session_events (venue_id, ps_session_id, event_type, actor_user_id, occurred_at, metadata, request_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING RETURNING id`,
    [ctx.venueId, sessionId, type, ctx.user?.id ?? null, ctx.now, JSON.stringify(meta), ctx.requestId]);
  return r.rowCount === 1;
}

/** Remaining play time (seconds) at `at`, frozen while paused; null for per-game sessions or before start. */
export function remainingSeconds(s: any, at: Date): number | null {
  if (s.pricing_type !== 'DURATION' || !s.expected_end_at) return null;
  const ref = s.status === 'PAUSED' && s.paused_at ? new Date(s.paused_at) : at;
  return Math.round((new Date(s.expected_end_at).getTime() - ref.getTime()) / 1000);
}

// ======================================================================== packages (admin)

export interface PackageInput {
  name: string; description?: string | null; pricingType: 'DURATION' | 'PER_GAME';
  durationMinutes?: number | null; gamesPerUnit?: number | null; gameLabel?: string | null;
  priceMinor: number; active?: boolean; sortOrder?: number;
}

function validatePackage(p: { pricingType: string; durationMinutes?: number | null; gamesPerUnit?: number | null; priceMinor: number }) {
  if (!Number.isSafeInteger(p.priceMinor) || p.priceMinor <= 0) throw E.unprocessable('INVALID_PRICE', 'Enter a price greater than 0 ETB.');
  if (p.pricingType === 'DURATION' && !(Number.isInteger(p.durationMinutes) && p.durationMinutes! > 0 && p.durationMinutes! <= 1440)) {
    throw E.unprocessable('INVALID_DURATION', 'A duration package needs a duration between 1 and 1440 minutes.');
  }
  if (p.pricingType === 'PER_GAME' && !(Number.isInteger(p.gamesPerUnit) && p.gamesPerUnit! > 0 && p.gamesPerUnit! <= 100)) {
    throw E.unprocessable('INVALID_GAME_COUNT', 'A per-game package needs the number of games it includes (1–100).');
  }
}

export async function listPackages(ctx: Ctx, opts: { includeInactive?: boolean } = {}) {
  requireOperateOrManage(ctx);
  const all = opts.includeInactive && can(ctx, 'playstation.manage');
  const rows = await many<any>(ctx.db,
    `SELECT p.*, (SELECT COUNT(*)::int FROM ps_session_items i WHERE i.package_id=p.id) AS times_sold
       FROM ps_packages p WHERE p.venue_id=$1 AND p.archived_at IS NULL ${all ? '' : 'AND p.active'} ORDER BY p.sort_order, p.pricing_type, p.price_minor`, [ctx.venueId]);
  return { packages: toCamelAll(rows) };
}

export async function createPackage(ctx: Ctx, i: PackageInput) {
  assertCan(ctx, 'playstation.manage');
  validatePackage(i);
  const r = (await ctx.db.query(
    `INSERT INTO ps_packages (venue_id, name, description, pricing_type, duration_minutes, games_per_unit, game_label, price_minor, active, sort_order, created_by, updated_by, created_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$11,$12,$12) RETURNING *`,
    [ctx.venueId, i.name.trim(), i.description?.trim() || null, i.pricingType, i.pricingType === 'DURATION' ? i.durationMinutes : null,
      i.pricingType === 'PER_GAME' ? i.gamesPerUnit : null, i.pricingType === 'PER_GAME' ? (i.gameLabel?.trim() || 'game') : null,
      i.priceMinor, i.active ?? true, i.sortOrder ?? 0, ctx.user?.id ?? null, ctx.now])).rows[0];
  await audit(ctx, { action: 'ps.package_created', entityType: 'ps_package', entityId: r.id, after: toCamel(r) });
  await emit(ctx, 'PS_PACKAGES_CHANGED', 'ps_package', r.id, {});
  return toCamel(r);
}

/** Price/duration changes apply to new sales only: every sold line item keeps the price agreed at purchase. */
export async function updatePackage(ctx: Ctx, id: string, patch: Partial<PackageInput>) {
  assertCan(ctx, 'playstation.manage');
  const p = await lockOne<any>(ctx.db, 'SELECT * FROM ps_packages WHERE id=$1 AND venue_id=$2 AND archived_at IS NULL FOR NO KEY UPDATE', [id, ctx.venueId], 'Package');
  const next = {
    name: patch.name?.trim() ?? p.name, description: patch.description !== undefined ? (patch.description?.trim() || null) : p.description,
    pricingType: patch.pricingType ?? p.pricing_type,
    durationMinutes: patch.durationMinutes !== undefined ? patch.durationMinutes : p.duration_minutes,
    gamesPerUnit: patch.gamesPerUnit !== undefined ? patch.gamesPerUnit : p.games_per_unit,
    gameLabel: patch.gameLabel !== undefined ? patch.gameLabel : p.game_label,
    priceMinor: patch.priceMinor ?? Number(p.price_minor), active: patch.active ?? p.active, sortOrder: patch.sortOrder ?? p.sort_order,
  };
  if (next.pricingType !== p.pricing_type) {
    const used = await one(ctx.db, 'SELECT 1 FROM ps_session_items WHERE package_id=$1 LIMIT 1', [id]);
    if (used) throw E.conflict('PACKAGE_TYPE_LOCKED', 'This package has already been sold, so its pricing type cannot change. Create a new package instead.');
  }
  if (next.pricingType === 'DURATION') { next.gamesPerUnit = null; next.gameLabel = null; } else { next.durationMinutes = null; next.gameLabel = next.gameLabel?.trim() || 'game'; }
  validatePackage(next);
  const r = (await ctx.db.query(
    `UPDATE ps_packages SET name=$2, description=$3, pricing_type=$4, duration_minutes=$5, games_per_unit=$6, game_label=$7, price_minor=$8, active=$9, sort_order=$10, updated_by=$11, updated_at=$12
      WHERE id=$1 RETURNING *`,
    [id, next.name, next.description, next.pricingType, next.durationMinutes, next.gamesPerUnit, next.gameLabel, next.priceMinor, next.active, next.sortOrder, ctx.user?.id ?? null, ctx.now])).rows[0];
  await audit(ctx, { action: 'ps.package_updated', entityType: 'ps_package', entityId: id,
    before: { name: p.name, priceMinor: Number(p.price_minor), durationMinutes: p.duration_minutes, gamesPerUnit: p.games_per_unit, active: p.active },
    after: { name: r.name, priceMinor: Number(r.price_minor), durationMinutes: r.duration_minutes, gamesPerUnit: r.games_per_unit, active: r.active } });
  await emit(ctx, 'PS_PACKAGES_CHANGED', 'ps_package', id, {});
  return toCamel(r);
}

/** Never-sold packages are deleted; sold ones are archived so session history keeps pointing at them. */
export async function deletePackage(ctx: Ctx, id: string) {
  assertCan(ctx, 'playstation.manage');
  const p = await lockOne<any>(ctx.db, 'SELECT * FROM ps_packages WHERE id=$1 AND venue_id=$2 AND archived_at IS NULL FOR UPDATE', [id, ctx.venueId], 'Package');
  const used = await one(ctx.db, 'SELECT 1 FROM ps_session_items WHERE package_id=$1 LIMIT 1', [id]);
  if (used) {
    await ctx.db.query('UPDATE ps_packages SET active=false, archived_at=$2, updated_by=$3, updated_at=$2 WHERE id=$1', [id, ctx.now, ctx.user?.id ?? null]);
  } else {
    await ctx.db.query('DELETE FROM ps_packages WHERE id=$1', [id]);
  }
  await audit(ctx, { action: used ? 'ps.package_archived' : 'ps.package_deleted', entityType: 'ps_package', entityId: id, before: { name: p.name, priceMinor: Number(p.price_minor) } });
  await emit(ctx, 'PS_PACKAGES_CHANGED', 'ps_package', id, {});
  return { id, archived: !!used, deleted: !used };
}

// ======================================================================== consoles

export async function listConsoles(ctx: Ctx, opts: { includeArchived?: boolean } = {}) {
  requireOperateOrManage(ctx);
  const rows = await many<any>(ctx.db,
    `SELECT c.*, s.id AS session_id, s.session_number, s.status AS session_status, s.pricing_type, s.expected_end_at, s.paused_at, s.started_at,
            s.games_purchased, s.games_completed, s.payment_status, s.total_minor, s.walk_in_name, s.version AS session_version, cu.full_name AS customer_name, u.full_name AS operator_name,
            (SELECT i.package_name FROM ps_session_items i WHERE i.ps_session_id=s.id AND i.kind='INITIAL' LIMIT 1) AS package_name,
            (SELECT i.unit_price_minor FROM ps_session_items i WHERE i.ps_session_id=s.id AND i.kind='INITIAL' LIMIT 1) AS unit_price_minor,
            (SELECT i.quantity FROM ps_session_items i WHERE i.ps_session_id=s.id AND i.kind='INITIAL' LIMIT 1) AS quantity,
            ${MONEY_SQL}
       FROM ps_consoles c
       LEFT JOIN ps_sessions s ON s.console_id=c.id AND s.status = ANY($2)
       LEFT JOIN customers cu ON cu.id=s.customer_id LEFT JOIN users u ON u.id=s.operator_id
      WHERE c.venue_id=$1 ${opts.includeArchived ? '' : 'AND c.archived_at IS NULL'} ORDER BY c.code`, [ctx.venueId, OPEN]);
  return {
    serverTime: ctx.now.toISOString(),
    consoles: rows.map((r) => ({
      id: r.id, code: r.code, name: r.name, model: r.model, location: r.location, status: r.status, notes: r.notes, archivedAt: r.archived_at,
      state: r.archived_at ? 'ARCHIVED' : r.status !== 'ACTIVE' ? r.status : r.session_id ? 'IN_USE' : 'AVAILABLE',
      session: r.session_id ? {
        id: r.session_id, sessionNumber: r.session_number, status: r.session_status, pricingType: r.pricing_type, startedAt: r.started_at, version: r.session_version,
        expectedEndAt: r.expected_end_at, remainingSeconds: remainingSeconds({ pricing_type: r.pricing_type, expected_end_at: r.expected_end_at, status: r.session_status, paused_at: r.paused_at }, ctx.now),
        gamesPurchased: r.games_purchased, gamesCompleted: r.games_completed, gamesCount: r.games_purchased, quantity: r.quantity ?? 0, paymentStatus: r.payment_status,
        packageName: r.package_name, unitPriceMinor: r.unit_price_minor == null ? 0 : Number(r.unit_price_minor),
        ...moneyOf(Number(r.total_minor), { paid: Number(r.paid_minor), settled: Number(r.settled_minor), pending: Number(r.pending_minor) }),
        playerName: r.customer_name ?? r.walk_in_name, operatorName: r.operator_name,
      } : null,
    })),
  };
}

export interface ConsoleInput { code: string; name: string; model?: string | null; location?: string | null; notes?: string | null; status?: 'ACTIVE' | 'MAINTENANCE' | 'INACTIVE' }

export async function createConsole(ctx: Ctx, i: ConsoleInput) {
  assertCan(ctx, 'playstation.manage');
  const code = i.code.trim().toUpperCase();
  if (await one(ctx.db, 'SELECT 1 FROM ps_consoles WHERE venue_id=$1 AND code=$2', [ctx.venueId, code])) throw E.conflict('CONSOLE_CODE_TAKEN', `A console with the number ${code} already exists.`);
  const r = (await ctx.db.query(
    `INSERT INTO ps_consoles (venue_id, code, name, model, location, notes, status, created_by, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$9) RETURNING *`,
    [ctx.venueId, code, i.name.trim(), i.model?.trim() || null, i.location?.trim() || null, i.notes?.trim() || null, i.status ?? 'ACTIVE', ctx.user?.id ?? null, ctx.now])).rows[0];
  await audit(ctx, { action: 'ps.console_created', entityType: 'ps_console', entityId: r.id, after: { code, name: r.name } });
  await emit(ctx, 'PS_CONSOLES_CHANGED', 'ps_console', r.id, {});
  return toCamel(r);
}

export async function updateConsole(ctx: Ctx, id: string, patch: Partial<ConsoleInput> & { archived?: boolean }) {
  assertCan(ctx, 'playstation.manage');
  const c = await lockOne<any>(ctx.db, 'SELECT * FROM ps_consoles WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Console');
  const busy = await one<any>(ctx.db, 'SELECT session_number FROM ps_sessions WHERE console_id=$1 AND status = ANY($2)', [id, OPEN]);
  if (busy && ((patch.status && patch.status !== 'ACTIVE') || patch.archived)) {
    throw E.conflict('CONSOLE_IN_USE', `Console ${c.code} has an open session (${busy.session_number}). Finish or cancel it first.`);
  }
  if (patch.code) {
    const code = patch.code.trim().toUpperCase();
    if (code !== c.code && await one(ctx.db, 'SELECT 1 FROM ps_consoles WHERE venue_id=$1 AND code=$2', [ctx.venueId, code])) throw E.conflict('CONSOLE_CODE_TAKEN', `A console with the number ${code} already exists.`);
    patch.code = code;
  }
  const r = (await ctx.db.query(
    `UPDATE ps_consoles SET code=$2, name=$3, model=$4, location=$5, notes=$6, status=$7, archived_at=$8, updated_at=$9 WHERE id=$1 RETURNING *`,
    [id, patch.code ?? c.code, patch.name?.trim() ?? c.name, patch.model !== undefined ? (patch.model?.trim() || null) : c.model,
      patch.location !== undefined ? (patch.location?.trim() || null) : c.location, patch.notes !== undefined ? (patch.notes?.trim() || null) : c.notes,
      patch.archived ? 'INACTIVE' : patch.status ?? c.status, patch.archived === undefined ? c.archived_at : patch.archived ? ctx.now : null, ctx.now])).rows[0];
  await audit(ctx, { action: 'ps.console_updated', entityType: 'ps_console', entityId: id, before: { code: c.code, status: c.status, archived: !!c.archived_at }, after: { code: r.code, status: r.status, archived: !!r.archived_at } });
  await emit(ctx, 'PS_CONSOLES_CHANGED', 'ps_console', id, {});
  return toCamel(r);
}

// ======================================================================== payments

const SETTLED_SQL = `('PAID','PARTIALLY_REFUNDED','REFUNDED')`;
/** Per-session money columns for list queries (alias `s` = ps_sessions). */
const MONEY_SQL = `
  COALESCE((SELECT SUM(p.amount_minor - p.refunded_minor) FROM ps_payments p WHERE p.ps_session_id=s.id AND p.status IN ${SETTLED_SQL}),0)::bigint AS paid_minor,
  COALESCE((SELECT SUM(p.amount_minor) FROM ps_payments p WHERE p.ps_session_id=s.id AND p.status IN ${SETTLED_SQL}),0)::bigint AS settled_minor,
  COALESCE((SELECT SUM(p.amount_minor) FROM ps_payments p WHERE p.ps_session_id=s.id AND p.status='PENDING'),0)::bigint AS pending_minor`;

/**
 * Money rules (one place, used by every screen and report):
 *   balance   = total charge − payments that are actually received (settled). Pending-verification and rejected
 *               payments never reduce it; refunded money is treated as settled-then-returned, so a refund does not
 *               re-open the debt.
 *   toCollect = balance − payments still awaiting verification (what a new payment may still claim).
 */
export const moneyOf = (total: number, r: { settled: number; pending: number; paid: number; refunded?: number }) => ({
  totalMinor: total, paidMinor: r.paid, settledMinor: r.settled, pendingMinor: r.pending, refundedMinor: r.refunded ?? 0,
  balanceMinor: Math.max(0, total - r.settled), toCollectMinor: Math.max(0, total - r.settled - r.pending),
});

async function paymentTotals(q: Queryable, sessionId: string) {
  const r = (await one<any>(q,
    `SELECT COALESCE(SUM(amount_minor - refunded_minor) FILTER (WHERE status IN ${SETTLED_SQL}),0)::bigint AS paid,
            COALESCE(SUM(amount_minor) FILTER (WHERE status IN ${SETTLED_SQL}),0)::bigint AS settled,
            COALESCE(SUM(amount_minor) FILTER (WHERE status='PENDING'),0)::bigint AS pending,
            COALESCE(SUM(refunded_minor),0)::bigint AS refunded
       FROM ps_payments WHERE ps_session_id=$1`, [sessionId]))!;
  return { paid: Number(r.paid), settled: Number(r.settled), pending: Number(r.pending), refunded: Number(r.refunded) };
}

/** Recompute the cached payment status from the payment records (never from what the client says). */
async function refreshPaymentState(ctx: Ctx, s: any) {
  const t = await paymentTotals(ctx.db, s.id);
  const total = Number(s.total_minor);
  const ps = t.refunded > 0 ? (t.paid <= 0 ? 'REFUNDED' : 'PARTIALLY_REFUNDED')
    : total === 0 ? (s.status === 'COMPLETED' ? 'PAID' : 'UNPAID')
    : t.settled >= total ? 'PAID' : t.settled > 0 ? 'PARTIALLY_PAID' : t.pending > 0 ? 'PENDING' : 'UNPAID';
  const next = s.status === 'PENDING_PAYMENT' && total > 0 && t.settled >= total ? 'READY' : s.status; // legacy pre-paid sessions
  const upd = (await ctx.db.query('UPDATE ps_sessions SET payment_status=$2, status=$3, updated_at=$4, version=version+1 WHERE id=$1 RETURNING *', [s.id, ps, next, ctx.now])).rows[0];
  return { session: upd, totals: t, ...moneyOf(total, t) };
}

async function lockSession(ctx: Ctx, id: string) {
  return lockOne<any>(ctx.db, 'SELECT * FROM ps_sessions WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Gaming session');
}

function payOut(p: any) {
  return {
    id: p.id, sessionId: p.ps_session_id, amountMinor: Number(p.amount_minor), refundedMinor: Number(p.refunded_minor), method: p.method, reference: p.reference, status: p.status,
    paidAt: p.paid_at, createdAt: p.created_at, recordedBy: p.recorded_by, recordedByName: p.recorded_by_name ?? null,
    confirmedByName: p.confirmed_by_name ?? null, rejectedByName: p.rejected_by_name ?? null, rejectedAt: p.rejected_at, rejectReason: p.reject_reason,
    verificationRequired: p.verification_required, hasProof: !!p.proof_key, proofUploadedAt: p.proof_uploaded_at,
    tenderedMinor: p.tendered_minor == null ? null : Number(p.tendered_minor), changeMinor: p.tendered_minor == null ? null : Number(p.tendered_minor) - Number(p.amount_minor), note: p.note,
  };
}

export interface PayInput { amountMinor: number; method: string; reference?: string | null; tenderedMinor?: number | null; note?: string | null }

async function insertPayment(ctx: Ctx, s: any, p: PayInput, proofBytes: Buffer | null, written: { keys: string[] }) {
  if (!Number.isSafeInteger(p.amountMinor) || p.amountMinor <= 0) throw E.unprocessable('INVALID_AMOUNT', 'The payment amount must be greater than zero.');
  const settings = await getSettings(ctx.db, ctx.venueId);
  const method = settings.paymentMethods.find((m) => m.code === p.method && m.enabled);
  if (!method) throw E.unprocessable('PAYMENT_METHOD_INVALID', `Payment method ${p.method} is not available at this venue.`);
  const isCash = method.code === 'CASH';
  const reference = p.reference?.trim() || null;
  if (!isCash && method.requiresReference && !reference) throw E.unprocessable('PAYMENT_REFERENCE_REQUIRED', `${method.label} payments need a reference / transaction number.`);
  if (!isCash && settings.playstation.proofRequiredMethods.includes(method.code) && !proofBytes) {
    throw E.unprocessable('PROOF_REQUIRED', `${method.label} payments need a photo or screenshot of the payment as evidence.`, { proofRequired: true });
  }
  if (p.tenderedMinor != null && (!isCash || !Number.isSafeInteger(p.tenderedMinor) || p.tenderedMinor < p.amountMinor)) {
    throw E.unprocessable('INVALID_TENDERED', 'The cash received must be a number no smaller than the amount being paid.');
  }
  const t = await paymentTotals(ctx.db, s.id);
  const due = moneyOf(Number(s.total_minor), t).toCollectMinor;
  if (due <= 0) throw E.unprocessable('NOTHING_DUE', t.pending > 0 ? 'The remaining balance is already covered by payments awaiting verification.' : 'There is nothing left to pay on this session.');
  if (p.amountMinor > due) throw E.unprocessable('PAYMENT_EXCEEDS_DUE', `That would overpay this session. Remaining to pay: ${formatMinor(due, s.currency)}.`, { remainingMinor: due });

  const verify = !isCash && settings.playstation.verifyNonCash;
  let proofKey: string | null = null, proof: ReturnType<typeof validateImage> | null = null;
  if (proofBytes) {
    proof = validateImage(proofBytes);
    proofKey = newStorageKey(ctx.venueId, 'psproof', proof.ext);
    await storage.put(proofKey, proof.bytes);
    written.keys.push(proofKey);
  }
  let row: any;
  try {
    row = (await ctx.db.query(
      `INSERT INTO ps_payments (venue_id, ps_session_id, amount_minor, currency, method, reference, status, verification_required, tendered_minor, recorded_by, confirmed_by, paid_at, note,
          proof_key, proof_mime, proof_size, proof_sha256, proof_uploaded_at, created_at, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$19) RETURNING *`,
      [ctx.venueId, s.id, p.amountMinor, s.currency, p.method, reference, verify ? 'PENDING' : 'PAID', verify, isCash ? p.tenderedMinor ?? null : null, ctx.user?.id ?? null,
        verify ? null : ctx.user?.id ?? null, verify ? null : ctx.now, p.note?.trim() || null,
        proofKey, proof?.mime ?? null, proof?.size ?? null, proof?.sha256 ?? null, proof ? ctx.now : null, ctx.now])).rows[0];
  } catch (e: any) {
    if (e?.code === '23505' && String(e.constraint).includes('proof')) throw E.conflict('PROOF_ALREADY_USED', 'This exact screenshot/photo was already submitted for another payment. Upload the proof for this payment.');
    if (e?.code === '23505' && String(e.constraint).includes('txn')) throw E.conflict('TRANSACTION_ALREADY_USED', `The ${method.label} reference ${reference} was already recorded for another payment.`);
    throw e;
  }
  await event(ctx, s.id, verify ? 'PAYMENT_SUBMITTED' : 'PAYMENT_RECEIVED', { paymentId: row.id, amountMinor: p.amountMinor, method: p.method, reference, hasProof: !!proofKey });
  await audit(ctx, { action: verify ? 'ps.payment_submitted' : 'ps.payment_recorded', entityType: 'ps_payment', entityId: row.id, after: { sessionId: s.id, amountMinor: p.amountMinor, method: p.method, status: row.status, hasProof: !!proofKey } });
  if (verify) await emit(ctx, 'PS_PAYMENT_SUBMITTED', 'ps_payment', row.id, { paymentId: row.id, sessionId: s.id, recordedBy: ctx.user?.id ?? null });
  return row;
}

/** Record a payment (cash counts as received immediately; non-cash waits for verification when the venue requires it). */
export async function recordPayment(ctx: Ctx, sessionId: string, p: PayInput, proofBytes: Buffer | null = null, written: { keys: string[] } = { keys: [] }) {
  requireOperate(ctx);
  const s = await lockSession(ctx, sessionId);
  if (s.status === 'CANCELLED') throw E.conflict('SESSION_CANCELLED', 'This gaming session was cancelled.');
  const row = await insertPayment(ctx, s, p, proofBytes, written);
  await refreshPaymentState(ctx, s);
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id });
  const d = await getGamingSession(ctx, s.id);
  return { ...d, payment: d.payments.find((x: any) => x.id === row.id), changeMinor: row.tendered_minor == null ? null : Number(row.tendered_minor) - Number(row.amount_minor) };
}

/** Attach or replace evidence on a payment that is still awaiting verification. */
export async function attachProof(ctx: Ctx, paymentId: string, bytes: Buffer, written: { keys: string[] }) {
  requireOperate(ctx);
  const p0 = await one<any>(ctx.db, 'SELECT ps_session_id FROM ps_payments WHERE id=$1 AND venue_id=$2', [paymentId, ctx.venueId]);
  if (!p0) throw E.notFound('Payment');
  await lockSession(ctx, p0.ps_session_id);
  const p = await lockOne<any>(ctx.db, 'SELECT * FROM ps_payments WHERE id=$1 FOR NO KEY UPDATE', [paymentId], 'Payment');
  if (p.status !== 'PENDING') throw E.conflict('PAYMENT_NOT_PENDING', 'Evidence can only be added while a payment is awaiting verification.');
  if (p.recorded_by !== ctx.user?.id && !can(ctx, 'playstation.manage')) throw E.forbidden('Only the employee who recorded this payment can add its evidence.');
  const img = validateImage(bytes);
  const key = newStorageKey(ctx.venueId, 'psproof', img.ext);
  await storage.put(key, img.bytes);
  written.keys.push(key);
  try {
    await ctx.db.query('UPDATE ps_payments SET proof_key=$2, proof_mime=$3, proof_size=$4, proof_sha256=$5, proof_uploaded_at=$6, updated_at=$6 WHERE id=$1', [paymentId, key, img.mime, img.size, img.sha256, ctx.now]);
  } catch (e: any) {
    if (e?.code === '23505') throw E.conflict('PROOF_ALREADY_USED', 'This exact screenshot/photo was already submitted for another payment.');
    throw e;
  }
  await event(ctx, p.ps_session_id, 'PAYMENT_PROOF_ADDED', { paymentId, replaced: !!p.proof_key });
  await audit(ctx, { action: 'ps.payment_proof_added', entityType: 'ps_payment', entityId: paymentId, after: { replaced: !!p.proof_key } });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', p.ps_session_id, { sessionId: p.ps_session_id });
  return { id: paymentId, hasProof: true };
}

/** Private evidence image: verifiers see any; an employee sees only their own submissions. */
export async function loadProof(ctx: Ctx, paymentId: string) {
  const p = await one<any>(ctx.db, 'SELECT venue_id, proof_key, proof_mime, recorded_by FROM ps_payments WHERE id=$1', [paymentId]);
  if (!p || p.venue_id !== ctx.venueId || !p.proof_key) throw E.notFound('Payment evidence');
  const allowed = can(ctx, 'playstation.verify') || can(ctx, 'playstation.manage') || (can(ctx, 'playstation.operate') && p.recorded_by === ctx.user?.id);
  if (!allowed) throw E.forbidden("You don't have permission to view payment evidence.");
  const bytes = await storage.get(p.proof_key).catch(() => null);
  if (!bytes) throw E.notFound('Payment evidence');
  await audit(ctx, { action: 'ps.proof_viewed', entityType: 'ps_payment', entityId: paymentId });
  return { bytes, mime: p.proof_mime as string };
}

async function loadPendingForReview(ctx: Ctx, paymentId: string) {
  const p0 = await one<any>(ctx.db, 'SELECT ps_session_id FROM ps_payments WHERE id=$1 AND venue_id=$2', [paymentId, ctx.venueId]);
  if (!p0) throw E.notFound('Payment');
  const s = await lockSession(ctx, p0.ps_session_id); // lock order: session, then payment
  const p = await lockOne<any>(ctx.db, 'SELECT * FROM ps_payments WHERE id=$1 FOR NO KEY UPDATE', [paymentId], 'Payment');
  if (p.status !== 'PENDING') throw E.conflict('PAYMENT_NOT_PENDING', `This payment is already ${p.status === 'PAID' ? 'verified' : p.status.toLowerCase().replace('_', ' ')}.`);
  return { s, p };
}

async function assertNotSelfReview(ctx: Ctx, p: any) {
  const settings = await getSettings(ctx.db, ctx.venueId);
  if (p.recorded_by && p.recorded_by === ctx.user?.id && !settings.playstation.allowSelfVerification) {
    throw E.forbidden('You recorded this payment, so someone else must verify it.', 'SELF_VERIFICATION');
  }
}

export async function verifyPayment(ctx: Ctx, paymentId: string, reference?: string | null) {
  assertCan(ctx, 'playstation.verify');
  const { s, p } = await loadPendingForReview(ctx, paymentId);
  await assertNotSelfReview(ctx, p);
  const settings = await getSettings(ctx.db, ctx.venueId);
  if (settings.playstation.proofRequiredMethods.includes(p.method) && !p.proof_key) throw E.unprocessable('EVIDENCE_MISSING', 'This payment has no evidence image. Reject it, or ask the employee to add the evidence first.');
  const ref = reference?.trim() || p.reference;
  const needsRef = settings.paymentMethods.find((m) => m.code === p.method)?.requiresReference;
  if (needsRef && !ref) throw E.unprocessable('PAYMENT_REFERENCE_REQUIRED', 'A reference / transaction number is needed to verify this payment.');
  await ctx.db.query(`UPDATE ps_payments SET status='PAID', reference=$2, confirmed_by=$3, paid_at=$4, updated_at=$4 WHERE id=$1`, [paymentId, ref, ctx.user?.id ?? null, ctx.now]);
  await event(ctx, s.id, 'PAYMENT_VERIFIED', { paymentId, amountMinor: Number(p.amount_minor) });
  await audit(ctx, { action: 'ps.payment_verified', entityType: 'ps_payment', entityId: paymentId, before: { status: 'PENDING' }, after: { status: 'PAID', amountMinor: Number(p.amount_minor), recordedBy: p.recorded_by } });
  const r = await refreshPaymentState(ctx, s);
  await emit(ctx, 'PS_PAYMENT_VERIFIED', 'ps_payment', paymentId, { paymentId, sessionId: s.id, recordedBy: p.recorded_by });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id });
  return { paymentId, status: 'PAID', balanceMinor: r.balanceMinor, session: toCamel(r.session) };
}

export async function rejectPayment(ctx: Ctx, paymentId: string, reason: string) {
  assertCan(ctx, 'playstation.verify');
  if (!reason?.trim() || reason.trim().length < 3) throw E.unprocessable('REASON_REQUIRED', 'Give a reason for rejecting this payment.');
  const { s, p } = await loadPendingForReview(ctx, paymentId);
  await assertNotSelfReview(ctx, p);
  await ctx.db.query(`UPDATE ps_payments SET status='REJECTED', rejected_by=$2, rejected_at=$3, reject_reason=$4, updated_at=$3 WHERE id=$1`, [paymentId, ctx.user?.id ?? null, ctx.now, reason.trim()]);
  await event(ctx, s.id, 'PAYMENT_REJECTED', { paymentId, amountMinor: Number(p.amount_minor), reason: reason.trim() });
  await audit(ctx, { action: 'ps.payment_rejected', entityType: 'ps_payment', entityId: paymentId, reason: reason.trim(), before: { status: 'PENDING' }, after: { status: 'REJECTED', recordedBy: p.recorded_by } });
  const r = await refreshPaymentState(ctx, s);
  await emit(ctx, 'PS_PAYMENT_REJECTED', 'ps_payment', paymentId, { paymentId, sessionId: s.id, recordedBy: p.recorded_by, consoleCode: (await one<any>(ctx.db, 'SELECT code FROM ps_consoles WHERE id=$1', [s.console_id]))?.code });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id });
  return { paymentId, status: 'REJECTED', balanceMinor: r.balanceMinor };
}

/** An employee withdraws their own payment while it is still pending (e.g. wrong amount). The record stays. */
export async function cancelPendingPayment(ctx: Ctx, paymentId: string) {
  requireOperate(ctx);
  const { s, p } = await loadPendingForReview(ctx, paymentId);
  if (p.recorded_by !== ctx.user?.id && !can(ctx, 'playstation.manage')) throw E.forbidden('Only the employee who recorded this payment can withdraw it.');
  await ctx.db.query(`UPDATE ps_payments SET status='CANCELLED', updated_at=$2 WHERE id=$1`, [paymentId, ctx.now]);
  await event(ctx, s.id, 'PAYMENT_CANCELLED', { paymentId, amountMinor: Number(p.amount_minor) });
  await audit(ctx, { action: 'ps.payment_cancelled', entityType: 'ps_payment', entityId: paymentId, before: { status: 'PENDING' }, after: { status: 'CANCELLED' } });
  const r = await refreshPaymentState(ctx, s);
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id });
  return { session: toCamel(r.session) };
}

export async function refundPayment(ctx: Ctx, paymentId: string, input: { amountMinor?: number; reason: string }) {
  assertCan(ctx, 'playstation.refund');
  if (!input.reason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'A reason is required for every refund.');
  const p0 = await one<any>(ctx.db, 'SELECT ps_session_id FROM ps_payments WHERE id=$1 AND venue_id=$2', [paymentId, ctx.venueId]);
  if (!p0) throw E.notFound('Payment');
  const s = await lockSession(ctx, p0.ps_session_id);
  const p = await lockOne<any>(ctx.db, 'SELECT * FROM ps_payments WHERE id=$1 FOR NO KEY UPDATE', [paymentId], 'Payment');
  if (!['PAID', 'PARTIALLY_REFUNDED'].includes(p.status)) throw E.conflict('PAYMENT_NOT_REFUNDABLE', p.status === 'REFUNDED' ? 'This payment has already been fully refunded.' : `A ${p.status.toLowerCase()} payment cannot be refunded.`);
  const refundable = Number(p.amount_minor) - Number(p.refunded_minor);
  const amount = input.amountMinor ?? refundable;
  if (!Number.isSafeInteger(amount) || amount <= 0) throw E.unprocessable('INVALID_AMOUNT', 'The refund amount must be greater than zero.');
  if (amount > refundable) throw E.unprocessable('REFUND_EXCEEDS_PAYMENT', `Only ${formatMinor(refundable, p.currency)} can still be refunded on this payment.`, { refundableMinor: refundable });
  const ref = (await ctx.db.query(`INSERT INTO ps_refunds (venue_id, payment_id, amount_minor, reason, refunded_by, created_at) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
    [ctx.venueId, paymentId, amount, input.reason.trim(), ctx.user?.id ?? null, ctx.now])).rows[0];
  const newRefunded = Number(p.refunded_minor) + amount;
  await ctx.db.query('UPDATE ps_payments SET refunded_minor=$2, status=$3, updated_at=$4 WHERE id=$1', [paymentId, newRefunded, newRefunded === Number(p.amount_minor) ? 'REFUNDED' : 'PARTIALLY_REFUNDED', ctx.now]);
  await event(ctx, s.id, 'PAYMENT_REFUNDED', { paymentId, amountMinor: amount, reason: input.reason.trim() });
  await audit(ctx, { action: 'ps.payment_refunded', entityType: 'ps_payment', entityId: paymentId, reason: input.reason.trim(), after: { amountMinor: amount, refundId: ref.id } });
  const r = await refreshPaymentState(ctx, s);
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id });
  return { refundId: ref.id, session: toCamel(r.session) };
}

/** Payments awaiting (or past) verification, with the context a reviewer needs. Evidence is fetched separately and privately. */
export async function reviewQueue(ctx: Ctx, opts: { status?: 'PENDING' | 'PAID' | 'REJECTED'; limit?: number }) {
  assertCan(ctx, 'playstation.verify');
  const status = opts.status ?? 'PENDING';
  const rows = await many<any>(ctx.db,
    `SELECT p.*, s.session_number, s.id AS session_id, s.total_minor AS session_total, c.code AS console_code, COALESCE(cu.full_name, s.walk_in_name) AS player_name,
            (SELECT i.package_name FROM ps_session_items i WHERE i.ps_session_id=s.id AND i.kind='INITIAL' LIMIT 1) AS package_name, s.games_purchased, s.pricing_type,
            ru.full_name AS recorded_by_name, cu2.full_name AS confirmed_by_name, ju.full_name AS rejected_by_name
       FROM ps_payments p JOIN ps_sessions s ON s.id=p.ps_session_id JOIN ps_consoles c ON c.id=s.console_id LEFT JOIN customers cu ON cu.id=s.customer_id
       LEFT JOIN users ru ON ru.id=p.recorded_by LEFT JOIN users cu2 ON cu2.id=p.confirmed_by LEFT JOIN users ju ON ju.id=p.rejected_by
      WHERE p.venue_id=$1 AND p.verification_required AND p.status ${status === 'PAID' ? `IN ${SETTLED_SQL}` : '= $3'}
      ORDER BY p.created_at DESC LIMIT $2`, status === 'PAID' ? [ctx.venueId, opts.limit ?? 100] : [ctx.venueId, opts.limit ?? 100, status]);
  const counts = (await one<any>(ctx.db,
    `SELECT COUNT(*) FILTER (WHERE status='PENDING')::int AS pending, COALESCE(SUM(amount_minor) FILTER (WHERE status='PENDING'),0)::bigint AS pending_minor,
            COUNT(*) FILTER (WHERE status='REJECTED')::int AS rejected FROM ps_payments WHERE venue_id=$1 AND verification_required`, [ctx.venueId]))!;
  return {
    counts: { pending: counts.pending, pendingMinor: Number(counts.pending_minor), rejected: counts.rejected },
    payments: rows.map((r) => ({ ...payOut(r), sessionNumber: r.session_number, consoleCode: r.console_code, playerName: r.player_name, packageName: r.package_name, sessionTotalMinor: Number(r.session_total) })),
  };
}

// ======================================================================== sessions

async function loadActivePackage(ctx: Ctx, id: string) {
  const p = await one<any>(ctx.db, 'SELECT * FROM ps_packages WHERE id=$1 AND venue_id=$2', [id, ctx.venueId]);
  if (!p || p.archived_at || !p.active) throw E.unprocessable('PACKAGE_UNAVAILABLE', 'That package is not available. Choose an active package.');
  return p;
}

export interface CreateGamingInput {
  consoleId: string; packageId: string; quantity?: number;
  customerId?: string | null; walkInName?: string | null; walkInPhone?: string | null; notes?: string | null;
}

/** Opens a session that starts immediately and unpaid (play first, pay at checkout). */
export async function createGamingSession(ctx: Ctx, i: CreateGamingInput) {
  requireOperate(ctx);
  const pkg0 = await loadActivePackage(ctx, i.packageId);
  const qty = i.quantity ?? (pkg0.pricing_type === 'PER_GAME' ? 0 : 1);
  const minQty = pkg0.pricing_type === 'PER_GAME' ? 0 : 1;
  if (!Number.isInteger(qty) || qty < minQty || qty > 50) throw E.unprocessable('INVALID_QUANTITY', `Quantity must be between ${minQty} and 50.`);
  // Lock order everywhere: console -> session -> payments.
  const con = await lockOne<any>(ctx.db, 'SELECT * FROM ps_consoles WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [i.consoleId, ctx.venueId], 'Console');
  if (con.archived_at || con.status !== 'ACTIVE') throw E.conflict('CONSOLE_UNAVAILABLE', `Console ${con.code} is ${con.archived_at ? 'archived' : con.status === 'MAINTENANCE' ? 'under maintenance' : 'inactive'} and cannot take sessions.`);
  const busy = await one<any>(ctx.db, 'SELECT id, session_number FROM ps_sessions WHERE console_id=$1 AND status = ANY($2)', [con.id, OPEN]);
  if (busy) throw E.conflict('CONSOLE_IN_USE', `Console ${con.code} is already in use (${busy.session_number}).`, { sessionId: busy.id });
  const pkg = pkg0;
  let customerId: string | null = null;
  if (i.customerId) {
    const c = await one<any>(ctx.db, 'SELECT id, status FROM customers WHERE id=$1 AND venue_id=$2', [i.customerId, ctx.venueId]);
    if (!c || c.status === 'ERASED') throw E.unprocessable('CUSTOMER_INVALID', 'That customer was not found.');
    customerId = c.id;
  } else if (!i.walkInName?.trim()) {
    throw E.unprocessable('PLAYER_REQUIRED', 'Enter the walk-in customer name, or choose a registered customer.');
  }
  const venue = await getVenue(ctx.db, ctx.venueId);
  const day = localDateIn(venue.timezone, ctx.now);
  const n = await nextCounter(ctx, 'ps:' + day);
  const number = `PS-${day.replace(/-/g, '')}-${String(n).padStart(3, '0')}`;
  const unit = Number(pkg.price_minor);
  const total = unit * qty;
  const seconds = pkg.pricing_type === 'DURATION' ? pkg.duration_minutes * 60 * qty : 0;
  const games = pkg.pricing_type === 'PER_GAME' ? pkg.games_per_unit * qty : 0;
  const end = pkg.pricing_type === 'DURATION' ? new Date(ctx.now.getTime() + seconds * 1000) : null;
  const s = (await ctx.db.query(
    `INSERT INTO ps_sessions (venue_id, session_number, console_id, customer_id, walk_in_name, walk_in_phone, pricing_type, status, payment_status, total_minor, currency,
        purchased_seconds, games_purchased, games_completed, started_at, expected_end_at, started_by, operator_id, notes, created_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,'ACTIVE','UNPAID',$8,$9,$10,$11,$11,$12,$13,$14,$14,$15,$12,$12) RETURNING *`,
    [ctx.venueId, number, con.id, customerId, customerId ? null : i.walkInName!.trim(), i.walkInPhone ? (normalizePhone(i.walkInPhone) ?? i.walkInPhone.trim()) : null,
      pkg.pricing_type, total, pkg.currency, seconds, games, ctx.now, end, ctx.user?.id ?? null, i.notes?.trim() || null])).rows[0];
  await ctx.db.query(
    `INSERT INTO ps_session_items (venue_id, ps_session_id, kind, package_id, package_name, pricing_type, unit_price_minor, quantity, added_seconds, added_games, total_minor, added_by, created_at)
     VALUES ($1,$2,'INITIAL',$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
    [ctx.venueId, s.id, pkg.id, pkg.name, pkg.pricing_type, unit, qty, seconds, games, total, ctx.user?.id ?? null, ctx.now]);
  await event(ctx, s.id, 'SESSION_CREATED', { consoleCode: con.code, package: pkg.name, quantity: qty, unitPriceMinor: unit, totalMinor: total });
  await event(ctx, s.id, 'SESSION_STARTED', { expectedEndAt: end?.toISOString() ?? null, postPaid: true });
  await audit(ctx, { action: 'ps.session_started', entityType: 'ps_session', entityId: s.id, after: { number, console: con.code, package: pkg.name, quantity: qty, unitPriceMinor: unit, totalMinor: total, startedAt: ctx.now } });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id, consoleId: con.id });
  return getGamingSession(ctx, s.id);
}

/** Legacy pre-paid sessions only (created before the post-paid workflow); new sessions start on creation. */
export async function startGamingSession(ctx: Ctx, id: string) {
  requireOperate(ctx);
  const s0 = await one<any>(ctx.db, 'SELECT console_id FROM ps_sessions WHERE id=$1 AND venue_id=$2', [id, ctx.venueId]);
  if (!s0) throw E.notFound('Gaming session');
  const con = await lockOne<any>(ctx.db, 'SELECT * FROM ps_consoles WHERE id=$1 FOR NO KEY UPDATE', [s0.console_id], 'Console');
  const s = await lockSession(ctx, id);
  if (['ACTIVE', 'PAUSED'].includes(s.status)) throw E.conflict('SESSION_ALREADY_STARTED', 'This gaming session has already started.');
  if (!['READY', 'PENDING_PAYMENT'].includes(s.status)) throw E.conflict('SESSION_INVALID_TRANSITION', `A ${s.status.toLowerCase()} session cannot be started.`);
  if (con.status !== 'ACTIVE' || con.archived_at) throw E.conflict('CONSOLE_UNAVAILABLE', `Console ${con.code} is not available.`);
  const end = s.pricing_type === 'DURATION' ? new Date(ctx.now.getTime() + s.purchased_seconds * 1000) : null;
  await ctx.db.query(`UPDATE ps_sessions SET status='ACTIVE', started_at=$2, expected_end_at=$3, started_by=$4, updated_at=$2, version=version+1 WHERE id=$1`, [id, ctx.now, end, ctx.user?.id ?? null]);
  await event(ctx, id, 'SESSION_STARTED', { expectedEndAt: end?.toISOString() ?? null });
  await audit(ctx, { action: 'ps.session_started', entityType: 'ps_session', entityId: id, after: { startedAt: ctx.now, expectedEndAt: end } });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', id, { sessionId: id });
  return getGamingSession(ctx, id);
}

/** Pause rule: the clock is frozen while paused; on resume the expected end moves out by the paused time. */
export async function pauseGamingSession(ctx: Ctx, id: string, reason?: string | null) {
  requireOperate(ctx);
  const settings = await getSettings(ctx.db, ctx.venueId);
  if (!settings.playstation.pauseEnabled) throw E.conflict('PAUSE_DISABLED', 'Pausing gaming sessions is switched off.');
  const s = await lockSession(ctx, id);
  if (s.status !== 'ACTIVE') throw E.conflict('SESSION_INVALID_TRANSITION', 'Only an active session can be paused.');
  await ctx.db.query(`UPDATE ps_sessions SET status='PAUSED', paused_at=$2, updated_at=$2, version=version+1 WHERE id=$1`, [id, ctx.now]);
  await event(ctx, id, 'SESSION_PAUSED', { reason: reason ?? null, remainingSeconds: remainingSeconds(s, ctx.now) });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', id, { sessionId: id });
  return getGamingSession(ctx, id);
}

export async function resumeGamingSession(ctx: Ctx, id: string) {
  requireOperate(ctx);
  const s = await lockSession(ctx, id);
  if (s.status !== 'PAUSED') throw E.conflict('SESSION_INVALID_TRANSITION', 'Only a paused session can be resumed.');
  const d = Math.max(0, secondsBetween(new Date(s.paused_at), ctx.now));
  const end = s.expected_end_at ? new Date(new Date(s.expected_end_at).getTime() + d * 1000) : null;
  await ctx.db.query(`UPDATE ps_sessions SET status='ACTIVE', paused_at=NULL, total_paused_seconds=total_paused_seconds+$2, expected_end_at=$3, updated_at=$4, version=version+1 WHERE id=$1`, [id, d, end, ctx.now]);
  await event(ctx, id, 'SESSION_RESUMED', { pausedSeconds: d, expectedEndAt: end?.toISOString() ?? null });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', id, { sessionId: id });
  return getGamingSession(ctx, id);
}

/** Add more time to a timed session at today's package price. Billed at checkout like everything else. */
export async function extendGamingSession(ctx: Ctx, id: string, i: { packageId: string; quantity?: number }) {
  requireOperate(ctx);
  const qty = i.quantity ?? 1;
  if (!Number.isInteger(qty) || qty < 1 || qty > 50) throw E.unprocessable('INVALID_QUANTITY', 'Quantity must be between 1 and 50.');
  const s = await lockSession(ctx, id);
  if (!['READY', 'ACTIVE', 'PAUSED'].includes(s.status)) throw E.conflict('SESSION_INVALID_TRANSITION', 'Only an open session can be extended.');
  if (s.pricing_type !== 'DURATION') throw E.unprocessable('NOT_TIMED', 'This is a per-game session: use + Add Game instead.');
  const pkg = await loadActivePackage(ctx, i.packageId);
  if (pkg.pricing_type !== 'DURATION') throw E.unprocessable('PACKAGE_TYPE_MISMATCH', 'Extend a timed session with a time package.');
  const total = Number(pkg.price_minor) * qty;
  const seconds = pkg.duration_minutes * 60 * qty;
  await ctx.db.query(
    `INSERT INTO ps_session_items (venue_id, ps_session_id, kind, package_id, package_name, pricing_type, unit_price_minor, quantity, added_seconds, added_games, total_minor, added_by, created_at)
     VALUES ($1,$2,'EXTENSION',$3,$4,$5,$6,$7,$8,0,$9,$10,$11)`,
    [ctx.venueId, s.id, pkg.id, pkg.name, pkg.pricing_type, pkg.price_minor, qty, seconds, total, ctx.user?.id ?? null, ctx.now]);
  const newEnd = s.expected_end_at ? new Date(new Date(s.expected_end_at).getTime() + seconds * 1000) : null;
  const grown = (await ctx.db.query(
    `UPDATE ps_sessions SET total_minor=total_minor+$2, purchased_seconds=purchased_seconds+$3, expected_end_at=COALESCE($4, expected_end_at), updated_at=$5, version=version+1 WHERE id=$1 RETURNING *`,
    [s.id, total, seconds, newEnd, ctx.now])).rows[0];
  await refreshPaymentState(ctx, grown);
  await event(ctx, s.id, 'SESSION_EXTENDED', { package: pkg.name, quantity: qty, addedSeconds: seconds, totalMinor: total, expectedEndAt: newEnd?.toISOString() ?? null });
  await audit(ctx, { action: 'ps.session_extended', entityType: 'ps_session', entityId: s.id, after: { package: pkg.name, quantity: qty, totalMinor: total } });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id });
  return getGamingSession(ctx, s.id);
}

/**
 * Add (or, as an audited correction, remove) billable units on a per-game session. Atomic: the session row is locked,
 * so simultaneous taps from several devices each count exactly once and the total is always units × the price
 * snapshotted when the session started. Returns a compact summary so a rapid tap loop stays fast.
 */
export async function adjustGames(ctx: Ctx, id: string, input: { delta: number; reason?: string | null }) {
  requireOperate(ctx);
  const { delta } = input;
  if (!Number.isInteger(delta) || delta === 0 || Math.abs(delta) > 50) throw E.unprocessable('INVALID_QUANTITY', 'Add or remove between 1 and 50 games at a time.');
  const s = await lockSession(ctx, id);
  if (s.pricing_type !== 'PER_GAME') throw E.unprocessable('NOT_PER_GAME', 'This is a timed session: use Add time instead.');
  if (s.status === 'CANCELLED') throw E.conflict('SESSION_CANCELLED', 'This gaming session was cancelled.');
  const ended = s.status === 'COMPLETED';
  const reason = input.reason?.trim() || null;
  if (delta < 0 && !reason) throw E.unprocessable('REASON_REQUIRED', 'Say why the game count is being reduced.');
  if (ended) {
    assertCan(ctx, 'playstation.manage'); // changing a finished bill is an admin correction
    if (!reason) throw E.unprocessable('REASON_REQUIRED', 'A reason is required to change a finished session.');
  }
  const item = await lockOne<any>(ctx.db, `SELECT * FROM ps_session_items WHERE ps_session_id=$1 AND kind='INITIAL' FOR NO KEY UPDATE`, [id], 'Session item');
  const newQty = item.quantity + delta;
  if (newQty < 0) throw E.unprocessable('QUANTITY_NEGATIVE', 'The game count cannot go below zero.');
  if (newQty > 500) throw E.unprocessable('QUANTITY_TOO_HIGH', 'That is more games than one session can hold.');
  const unit = Number(item.unit_price_minor);
  const gpu = (await one<any>(ctx.db, 'SELECT games_per_unit FROM ps_packages WHERE id=$1', [item.package_id]))?.games_per_unit ?? 1;
  const newTotal = Number(s.total_minor) + delta * unit;
  const t = await paymentTotals(ctx.db, id);
  if (newTotal < t.settled + t.pending) throw E.conflict('BELOW_PAYMENTS', 'Payments already recorded are more than the corrected total. Refund or cancel the payment first.');
  await ctx.db.query('UPDATE ps_session_items SET quantity=$2, added_games=$3, total_minor=$4 WHERE id=$1', [item.id, newQty, newQty * gpu, newQty * unit]);
  const upd = (await ctx.db.query(
    `UPDATE ps_sessions SET total_minor=$2, games_purchased=games_purchased+$3, games_completed=games_completed+$3, updated_at=$4, version=version+1 WHERE id=$1 RETURNING *`,
    [id, newTotal, delta * gpu, ctx.now])).rows[0];
  await event(ctx, id, delta > 0 ? 'GAMES_ADDED' : 'GAMES_CORRECTED', { delta, quantity: newQty, games: upd.games_purchased, totalMinor: newTotal, reason, afterEnd: ended });
  if (delta < 0 || ended) await audit(ctx, { action: 'ps.games_corrected', entityType: 'ps_session', entityId: id, reason, before: { quantity: item.quantity, totalMinor: Number(s.total_minor) }, after: { quantity: newQty, totalMinor: newTotal } });
  const r = await refreshPaymentState(ctx, upd);
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', id, { sessionId: id });
  return {
    session: {
      id, version: r.session.version, status: r.session.status, paymentStatus: r.session.payment_status, quantity: newQty, gamesCount: upd.games_purchased, unitPriceMinor: unit,
      totalMinor: newTotal, paidMinor: r.paidMinor, pendingMinor: r.pendingMinor, balanceMinor: r.balanceMinor,
    },
  };
}

async function finishTx(ctx: Ctx, s: any, reason: string | null) {
  let pausedExtra = 0;
  if (s.status === 'PAUSED' && s.paused_at) pausedExtra = Math.max(0, secondsBetween(new Date(s.paused_at), ctx.now));
  const upd = (await ctx.db.query(
    `UPDATE ps_sessions SET status='COMPLETED', ended_at=$2, ended_by=$3, paused_at=NULL, total_paused_seconds=total_paused_seconds+$4, end_reason=$5, updated_at=$2, version=version+1 WHERE id=$1 RETURNING *`,
    [s.id, ctx.now, ctx.user?.id ?? null, pausedExtra, reason])).rows[0];
  const rem = remainingSeconds(s, ctx.now);
  const r = await refreshPaymentState(ctx, upd);
  await event(ctx, s.id, 'SESSION_FINISHED', { reason, remainingSeconds: rem, overtimeSeconds: rem !== null && rem < 0 ? -rem : 0, games: upd.games_purchased, totalMinor: Number(upd.total_minor), balanceMinor: r.balanceMinor });
  await audit(ctx, { action: 'ps.session_finished', entityType: 'ps_session', entityId: s.id, reason, after: { endedAt: ctx.now, totalMinor: Number(upd.total_minor), balanceMinor: r.balanceMinor } });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', s.id, { sessionId: s.id, finished: true });
}

/** Ends play and fixes the bill. Payment is separate: the session can be closed with money still owed (see checkout). */
export async function finishGamingSession(ctx: Ctx, id: string, input: { reason?: string | null } = {}) {
  requireOperate(ctx);
  const s = await lockSession(ctx, id);
  if (!['ACTIVE', 'PAUSED'].includes(s.status)) throw E.conflict('SESSION_INVALID_TRANSITION', s.status === 'COMPLETED' ? 'This session has already finished.' : 'Only a started session can be finished. Cancel it instead.');
  const rem = remainingSeconds(s, ctx.now);
  if (rem !== null && rem > 60 && !input.reason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'This session still has purchased time left. Give a reason for finishing early.');
  await finishTx(ctx, s, input.reason?.trim() || null);
  return getGamingSession(ctx, id);
}

const CANCEL_GRACE_MS = 5 * 60_000;

/** Cancel a session started by mistake: nothing played (no games / first 5 minutes) and nothing paid or awaiting verification. */
export async function cancelGamingSession(ctx: Ctx, id: string, reason: string) {
  requireOperate(ctx);
  if (!reason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'A reason is required to cancel a session.');
  const s = await lockSession(ctx, id);
  const legacy = ['PENDING_PAYMENT', 'READY'].includes(s.status);
  if (!legacy && !['ACTIVE', 'PAUSED'].includes(s.status)) throw E.conflict('SESSION_INVALID_TRANSITION', s.status === 'COMPLETED' ? 'A finished session cannot be cancelled.' : 'This session is already cancelled.');
  const t = await paymentTotals(ctx.db, id);
  if (!legacy) {
    if (t.settled > 0 || t.pending > 0) throw E.conflict('SESSION_HAS_PAYMENTS', 'Payments are recorded on this session, so it cannot be cancelled. Finish it, and ask an admin to refund if needed.');
    const nothingPlayed = s.pricing_type === 'PER_GAME' ? s.games_purchased === 0 : ctx.now.getTime() - new Date(s.started_at).getTime() <= CANCEL_GRACE_MS;
    if (!nothingPlayed) throw E.conflict('SESSION_ALREADY_PLAYED', s.pricing_type === 'PER_GAME' ? 'Games have already been counted on this session. Finish it instead.' : 'This session started more than 5 minutes ago. Finish it instead.');
  }
  await ctx.db.query(`UPDATE ps_payments SET status='CANCELLED', updated_at=$2 WHERE ps_session_id=$1 AND status='PENDING'`, [id, ctx.now]);
  await ctx.db.query(`UPDATE ps_sessions SET status='CANCELLED', ended_at=$2, ended_by=$3, end_reason=$4, updated_at=$2, version=version+1 WHERE id=$1`, [id, ctx.now, ctx.user?.id ?? null, reason.trim()]);
  await event(ctx, id, 'SESSION_CANCELLED', { reason: reason.trim(), refundDueMinor: t.paid });
  await audit(ctx, { action: 'ps.session_cancelled', entityType: 'ps_session', entityId: id, reason: reason.trim(), after: { refundDueMinor: t.paid } });
  await emit(ctx, 'PS_SESSION_UPDATED', 'ps_session', id, { sessionId: id });
  return { ...(await getGamingSession(ctx, id)), refundDueMinor: t.paid };
}

// ======================================================================== reads

export async function getGamingSession(ctx: Ctx, id: string) {
  requireOperateOrManage(ctx);
  const s = await one<any>(ctx.db,
    `SELECT s.*, c.code AS console_code, c.name AS console_name, cu.full_name AS customer_name, cu.customer_no, u.full_name AS operator_name
       FROM ps_sessions s JOIN ps_consoles c ON c.id=s.console_id LEFT JOIN customers cu ON cu.id=s.customer_id LEFT JOIN users u ON u.id=s.operator_id
      WHERE s.id=$1 AND s.venue_id=$2`, [id, ctx.venueId]);
  if (!s) throw E.notFound('Gaming session');
  const items = await many<any>(ctx.db, `SELECT i.*, u.full_name AS added_by_name FROM ps_session_items i LEFT JOIN users u ON u.id=i.added_by WHERE i.ps_session_id=$1 ORDER BY i.created_at`, [id]);
  const payments = await many<any>(ctx.db,
    `SELECT p.*, u.full_name AS recorded_by_name, cb.full_name AS confirmed_by_name, rb.full_name AS rejected_by_name FROM ps_payments p
       LEFT JOIN users u ON u.id=p.recorded_by LEFT JOIN users cb ON cb.id=p.confirmed_by LEFT JOIN users rb ON rb.id=p.rejected_by WHERE p.ps_session_id=$1 ORDER BY p.created_at`, [id]);
  const refunds = await many<any>(ctx.db, `SELECT r.*, u.full_name AS refunded_by_name FROM ps_refunds r JOIN ps_payments p ON p.id=r.payment_id LEFT JOIN users u ON u.id=r.refunded_by WHERE p.ps_session_id=$1 ORDER BY r.created_at`, [id]);
  const events = await many<any>(ctx.db, `SELECT e.id, e.event_type, e.occurred_at, e.metadata, u.full_name AS actor_name FROM ps_session_events e LEFT JOIN users u ON u.id=e.actor_user_id WHERE e.ps_session_id=$1 ORDER BY e.id`, [id]);
  const t = await paymentTotals(ctx.db, id);
  const m = moneyOf(Number(s.total_minor), t);
  const venue = await getVenue(ctx.db, ctx.venueId);
  const initial = items.find((i) => i.kind === 'INITIAL') ?? items[0];
  const player = s.customer_name ?? s.walk_in_name;
  return {
    serverTime: ctx.now.toISOString(),
    session: {
      ...toCamel(s), playerName: player, customerCode: s.customer_no ? customerNumber(s.customer_no) : null,
      remainingSeconds: remainingSeconds(s, ctx.now), gamesRemaining: s.games_purchased - s.games_completed,
      ...m, dueMinor: m.toCollectMinor, packageName: initial?.package_name ?? null, unitPriceMinor: initial ? Number(initial.unit_price_minor) : 0,
      quantity: initial?.quantity ?? 0, gamesCount: s.games_purchased,
      canRefund: can(ctx, 'playstation.refund'), canVerify: can(ctx, 'playstation.verify'), canCorrect: can(ctx, 'playstation.manage'),
    },
    items: toCamelAll(items), payments: payments.map(payOut), refunds: toCamelAll(refunds), events: toCamelAll(events),
    receipt: {
      venueName: venue.name, sessionNumber: s.session_number, console: `${s.console_code} · ${s.console_name}`, player,
      operator: s.operator_name, createdAt: s.created_at, startedAt: s.started_at, endedAt: s.ended_at,
      lines: items.map((i) => ({ description: i.package_name, quantity: i.quantity, unitPriceMinor: Number(i.unit_price_minor), totalMinor: Number(i.total_minor), kind: i.kind })),
      totalMinor: m.totalMinor, paidMinor: m.paidMinor, refundedMinor: m.refundedMinor, balanceMinor: m.balanceMinor, pendingMinor: m.pendingMinor,
      payments: payments.filter((p) => !['CANCELLED', 'FAILED', 'REJECTED'].includes(p.status)).map((p) => ({ method: p.method, amountMinor: Number(p.amount_minor), status: p.status === 'PENDING' ? 'PENDING_VERIFICATION' : p.status, reference: p.reference, at: p.paid_at ?? p.created_at })),
      currency: s.currency,
    },
  };
}

export interface HistoryFilter {
  from?: string; to?: string; consoleId?: string; operatorId?: string; packageId?: string; status?: string; paymentStatus?: string; mine?: boolean; outstanding?: boolean; limit?: number; offset?: number;
}

export async function listGamingSessions(ctx: Ctx, f: HistoryFilter) {
  requireOperateOrManage(ctx);
  const venue = await getVenue(ctx.db, ctx.venueId);
  const today = localDateIn(venue.timezone, ctx.now);
  const from = f.from ?? today, to = f.to ?? from;
  if (!isValidDate(from) || !isValidDate(to)) throw E.badRequest('INVALID_DATE', 'Use a date like 2026-10-24.');
  // The date range doesn't apply to "outstanding" (an unpaid session from last week is still owed), so its
  // parameters are only bound when used.
  const params: unknown[] = f.outstanding ? [ctx.venueId] : [ctx.venueId, from, to, venue.timezone];
  const where: string[] = [];
  const add = (sql: string, v: unknown) => { params.push(v); where.push(sql.replace('?', `$${params.length}`)); };
  if (f.consoleId) add('s.console_id = ?', f.consoleId);
  if (f.operatorId) add('s.operator_id = ?', f.operatorId);
  if (f.mine && ctx.user) add('s.operator_id = ?', ctx.user.id);
  if (f.status) add('s.status = ?', f.status);
  if (f.paymentStatus) add('s.payment_status = ?', f.paymentStatus);
  if (f.packageId) add('EXISTS (SELECT 1 FROM ps_session_items i WHERE i.ps_session_id=s.id AND i.package_id = ?)', f.packageId);
  if (f.outstanding) where.push(`s.status <> 'CANCELLED' AND s.total_minor > COALESCE((SELECT SUM(p.amount_minor) FROM ps_payments p WHERE p.ps_session_id=s.id AND p.status IN ${SETTLED_SQL}),0)`);
  params.push(f.limit ?? 200, f.offset ?? 0);
  const dateCond = f.outstanding ? 'TRUE' : '(s.created_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date';
  const rows = await many<any>(ctx.db,
    `SELECT s.id, s.session_number, s.status, s.payment_status, s.pricing_type, s.total_minor, s.currency, s.purchased_seconds, s.games_purchased, s.games_completed,
            s.created_at, s.started_at, s.ended_at, s.total_paused_seconds, c.code AS console_code, COALESCE(cu.full_name, s.walk_in_name) AS player_name, u.full_name AS operator_name,
            (SELECT string_agg(i.package_name || CASE WHEN i.quantity>1 THEN ' ×' || i.quantity ELSE '' END, ', ' ORDER BY i.created_at) FROM ps_session_items i WHERE i.ps_session_id=s.id) AS packages,
            ${MONEY_SQL}
       FROM ps_sessions s JOIN ps_consoles c ON c.id=s.console_id LEFT JOIN customers cu ON cu.id=s.customer_id LEFT JOIN users u ON u.id=s.operator_id
      WHERE s.venue_id=$1 AND ${dateCond} ${where.length ? 'AND ' + where.join(' AND ') : ''}
      ORDER BY s.created_at DESC LIMIT $${params.length - 1} OFFSET $${params.length}`, params);
  return {
    from, to,
    sessions: rows.map((r) => ({
      ...toCamel(r), ...moneyOf(Number(r.total_minor), { paid: Number(r.paid_minor), settled: Number(r.settled_minor), pending: Number(r.pending_minor) }),
      playedSeconds: r.started_at ? Math.max(0, secondsBetween(new Date(r.started_at), r.ended_at ? new Date(r.ended_at) : ctx.now) - r.total_paused_seconds) : 0,
    })),
  };
}

/** Money actually collected (payments received/verified) minus refunds actually issued, both by the day they happened. */
async function revenueBetween(q: Queryable, venueId: string, tz: string, from: string, to: string) {
  const r = (await one<any>(q,
    `SELECT COALESCE((SELECT SUM(amount_minor) FROM ps_payments WHERE venue_id=$1 AND paid_at IS NOT NULL AND (paid_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date),0)::bigint AS collected,
            COALESCE((SELECT SUM(amount_minor) FROM ps_refunds WHERE venue_id=$1 AND (created_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date),0)::bigint AS refunded`,
    [venueId, from, to, tz]))!;
  return { collectedMinor: Number(r.collected), refundedMinor: Number(r.refunded), netMinor: Number(r.collected) - Number(r.refunded) };
}

/** Admin overview and PlayStation Manager dashboard. */
export async function overview(ctx: Ctx) {
  requireOperateOrManage(ctx);
  const settings = await getSettings(ctx.db, ctx.venueId);
  const venue = await getVenue(ctx.db, ctx.venueId);
  const today = localDateIn(venue.timezone, ctx.now);
  const { consoles } = await listConsoles(ctx);
  const count = (st: string) => consoles.filter((c) => c.state === st).length;
  const live = consoles.filter((c) => c.session);
  const completedToday = (await one<any>(ctx.db, `SELECT COUNT(*)::int AS n FROM ps_sessions WHERE venue_id=$1 AND status='COMPLETED' AND (ended_at AT TIME ZONE $2)::date = $3::date`, [ctx.venueId, venue.timezone, today])).n;
  const outstanding = (await one<any>(ctx.db,
    `SELECT COUNT(*) FILTER (WHERE bal>0)::int AS n, COUNT(*) FILTER (WHERE bal>0 AND ended)::int AS ended_n, COALESCE(SUM(bal),0)::bigint AS minor FROM (
       SELECT GREATEST(0, s.total_minor - COALESCE((SELECT SUM(p.amount_minor) FROM ps_payments p WHERE p.ps_session_id=s.id AND p.status IN ${SETTLED_SQL}),0)) AS bal, (s.status='COMPLETED') AS ended
         FROM ps_sessions s WHERE s.venue_id=$1 AND s.status <> 'CANCELLED') x`, [ctx.venueId]))!;
  const pending = (await one<any>(ctx.db, `SELECT COUNT(*)::int AS n, COALESCE(SUM(amount_minor),0)::bigint AS minor FROM ps_payments WHERE venue_id=$1 AND status='PENDING'`, [ctx.venueId]))!;
  const popular = await many<any>(ctx.db,
    `SELECT i.package_name, COUNT(*)::int AS sold, SUM(i.total_minor)::bigint AS value_minor FROM ps_session_items i JOIN ps_sessions s ON s.id=i.ps_session_id
      WHERE i.venue_id=$1 AND s.status <> 'CANCELLED' AND i.created_at >= $2 GROUP BY i.package_name ORDER BY sold DESC LIMIT 5`, [ctx.venueId, new Date(ctx.now.getTime() - 7 * 86400_000)]);
  const recent = await many<any>(ctx.db,
    `SELECT e.id, e.event_type, e.occurred_at, e.metadata, s.id AS session_id, s.session_number, c.code AS console_code, u.full_name AS actor_name
       FROM ps_session_events e JOIN ps_sessions s ON s.id=e.ps_session_id JOIN ps_consoles c ON c.id=s.console_id LEFT JOIN users u ON u.id=e.actor_user_id
      WHERE e.venue_id=$1 AND e.event_type NOT IN ('GAMES_ADDED') ORDER BY e.id DESC LIMIT 20`, [ctx.venueId]);
  const warnAt = settings.playstation.warningMinutes * 60;
  return {
    serverTime: ctx.now.toISOString(), date: today, warningMinutes: settings.playstation.warningMinutes,
    consoles: { total: consoles.length, available: count('AVAILABLE'), inUse: count('IN_USE'), maintenance: count('MAINTENANCE'), inactive: count('INACTIVE') },
    sessions: {
      active: live.filter((c) => ['ACTIVE', 'PAUSED'].includes(c.session!.status)).length,
      waiting: live.filter((c) => ['PENDING_PAYMENT', 'READY'].includes(c.session!.status)).length,
      timedActive: live.filter((c) => c.session!.pricingType === 'DURATION' && c.session!.status === 'ACTIVE').length,
      perGameActive: live.filter((c) => c.session!.pricingType === 'PER_GAME' && c.session!.status === 'ACTIVE').length,
      completedToday,
    },
    endingSoon: live.filter((c) => c.session!.status === 'ACTIVE' && c.session!.remainingSeconds !== null && c.session!.remainingSeconds! <= warnAt)
      .map((c) => ({ consoleId: c.id, consoleCode: c.code, sessionId: c.session!.id, playerName: c.session!.playerName, remainingSeconds: c.session!.remainingSeconds }))
      .sort((a, b) => a.remainingSeconds! - b.remainingSeconds!),
    revenueToday: await revenueBetween(ctx.db, ctx.venueId, venue.timezone, today, today),
    outstanding: { sessions: outstanding.n, endedSessions: outstanding.ended_n, minor: Number(outstanding.minor) },
    pendingVerification: { count: pending.n, minor: Number(pending.minor) },
    popularPackages: toCamelAll(popular),
    recentActivity: toCamelAll(recent),
  };
}

export async function reports(ctx: Ctx, opts: { from: string; to: string }) {
  assertCan(ctx, 'playstation.reports');
  if (!isValidDate(opts.from) || !isValidDate(opts.to)) throw E.badRequest('INVALID_DATE', 'Use a date like 2026-10-24.');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const p = [ctx.venueId, opts.from, opts.to, venue.timezone];
  const byDay = await many<any>(ctx.db,
    `WITH d AS (SELECT generate_series($2::date, $3::date, interval '1 day')::date AS day)
     SELECT d.day::text AS day,
            COALESCE((SELECT SUM(amount_minor) FROM ps_payments WHERE venue_id=$1 AND paid_at IS NOT NULL AND (paid_at AT TIME ZONE $4)::date = d.day),0)::bigint AS collected_minor,
            COALESCE((SELECT SUM(amount_minor) FROM ps_refunds WHERE venue_id=$1 AND (created_at AT TIME ZONE $4)::date = d.day),0)::bigint AS refunded_minor,
            (SELECT COUNT(*)::int FROM ps_sessions WHERE venue_id=$1 AND status='COMPLETED' AND (ended_at AT TIME ZONE $4)::date = d.day) AS sessions_completed
       FROM d ORDER BY d.day`, p);
  const byPackage = await many<any>(ctx.db,
    `SELECT i.package_name, i.pricing_type, COUNT(*)::int AS times_sold, SUM(i.quantity)::int AS units, SUM(i.total_minor)::bigint AS sold_minor
       FROM ps_session_items i JOIN ps_sessions s ON s.id=i.ps_session_id
      WHERE i.venue_id=$1 AND s.status<>'CANCELLED' AND (i.created_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date
      GROUP BY 1,2 ORDER BY sold_minor DESC`, p);
  const byConsole = await many<any>(ctx.db,
    `SELECT c.code, c.name, COUNT(s.id)::int AS sessions,
            COALESCE(SUM(GREATEST(0, EXTRACT(EPOCH FROM (s.ended_at - s.started_at))::int - s.total_paused_seconds)) FILTER (WHERE s.ended_at IS NOT NULL AND s.started_at IS NOT NULL),0)::bigint AS played_seconds
       FROM ps_consoles c LEFT JOIN ps_sessions s ON s.console_id=c.id AND s.status='COMPLETED' AND (s.ended_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date
      WHERE c.venue_id=$1 GROUP BY c.id ORDER BY c.code`, p);
  const byEmployee = await many<any>(ctx.db,
    `SELECT u.id AS user_id, u.full_name, r.name AS role_name,
            (SELECT COUNT(*)::int FROM ps_sessions s WHERE s.operator_id=u.id AND (s.created_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date) AS sessions_opened,
            COALESCE((SELECT SUM(amount_minor) FROM ps_payments pp WHERE pp.recorded_by=u.id AND pp.paid_at IS NOT NULL AND (pp.paid_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date),0)::bigint AS collected_minor,
            (SELECT COUNT(*)::int FROM ps_session_events e WHERE e.actor_user_id=u.id AND (e.occurred_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date) AS actions
       FROM users u JOIN roles r ON r.id=u.role_id
      WHERE u.venue_id=$1 AND EXISTS (SELECT 1 FROM ps_session_events e WHERE e.actor_user_id=u.id AND (e.occurred_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date)
      ORDER BY collected_minor DESC`, p);
  return {
    from: opts.from, to: opts.to,
    totals: { ...(await revenueBetween(ctx.db, ctx.venueId, venue.timezone, opts.from, opts.to)), sessionsCompleted: byDay.reduce((a, d) => a + d.sessions_completed, 0) },
    byDay: toCamelAll(byDay), byPackage: toCamelAll(byPackage), byConsole: toCamelAll(byConsole), byEmployee: toCamelAll(byEmployee),
    definitions: { collected: 'Payments received (paid or confirmed) on that day', refunded: 'Refunds issued on that day', net: 'Collected minus refunded. Unpaid sessions are not counted.' },
  };
}

export async function employeeActivity(ctx: Ctx, opts: { userId?: string; limit?: number }) {
  if (!can(ctx, 'playstation.reports') && !(opts.userId && opts.userId === ctx.user?.id && can(ctx, 'playstation.operate'))) {
    throw E.forbidden("You don't have permission to view employee activity.");
  }
  const params: unknown[] = [ctx.venueId, opts.limit ?? 100];
  let w = '';
  if (opts.userId) { params.push(opts.userId); w = `AND e.actor_user_id = $3`; }
  const rows = await many<any>(ctx.db,
    `SELECT e.id, e.event_type, e.occurred_at, e.metadata, s.id AS session_id, s.session_number, c.code AS console_code, u.full_name AS actor_name
       FROM ps_session_events e JOIN ps_sessions s ON s.id=e.ps_session_id JOIN ps_consoles c ON c.id=s.console_id LEFT JOIN users u ON u.id=e.actor_user_id
      WHERE e.venue_id=$1 ${w} ORDER BY e.id DESC LIMIT $2`, params);
  return { events: toCamelAll(rows) };
}

/** Operators can attach a registered customer by exact phone number without getting general customer access. */
export async function lookupCustomerByPhone(ctx: Ctx, phone: string) {
  requireOperate(ctx);
  const e164 = normalizePhone(phone);
  if (!e164) throw E.unprocessable('INVALID_PHONE', 'That phone number is not valid.');
  const rows = await many<any>(ctx.db, `SELECT id, full_name, customer_no FROM customers WHERE venue_id=$1 AND phone_e164=$2 AND status IN ('ACTIVE','BLOCKED') ORDER BY registered_at LIMIT 5`, [ctx.venueId, e164]);
  return { customers: rows.map((r) => ({ id: r.id, fullName: r.full_name, customerCode: customerNumber(r.customer_no) })) };
}

// ======================================================================== worker: timer notices

/** Warn once when a timed session nears its end, and once when its time is up. Sessions keep running until staff finish them. */
export async function processGamingTimers(venueId: string, now: Date = clock.now()) {
  const settings = await getSettings(pool, venueId);
  const warnMs = settings.playstation.warningMinutes * 60_000;
  const due = await many<any>(pool,
    `SELECT id FROM ps_sessions WHERE venue_id=$1 AND status='ACTIVE' AND pricing_type='DURATION' AND expected_end_at <= $2 LIMIT 500`, [venueId, new Date(now.getTime() + warnMs)]);
  let n = 0;
  for (const { id } of due) {
    await withTx(async (db) => {
      const ctx: Ctx = { db, user: null, venueId, deviceId: null, requestId: 'worker', ip: null, now };
      const s = (await db.query(`SELECT s.*, c.code AS console_code FROM ps_sessions s JOIN ps_consoles c ON c.id=s.console_id WHERE s.id=$1 AND s.status='ACTIVE' FOR NO KEY UPDATE OF s SKIP LOCKED`, [id])).rows[0];
      if (!s) return;
      const rem = remainingSeconds(s, now)!;
      const forEnd = new Date(s.expected_end_at).toISOString();
      if (rem <= 0) {
        if (await event(ctx, s.id, 'TIME_UP', { for_end_at: forEnd })) {
          await emit(ctx, 'PS_SESSION_TIME_UP', 'ps_session', s.id, { sessionId: s.id, consoleCode: s.console_code });
          n++;
        }
      } else if (await event(ctx, s.id, 'TIME_WARNING', { for_end_at: forEnd, remainingSeconds: rem })) {
        await emit(ctx, 'PS_SESSION_WARNING', 'ps_session', s.id, { sessionId: s.id, consoleCode: s.console_code, remainingSeconds: rem });
        n++;
      }
    }).catch((e) => console.error('gaming timer failed', id, (e as Error).message));
  }
  return n;
}
