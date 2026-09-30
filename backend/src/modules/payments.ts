import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit, recordPaymentEvent } from '../shared/events.js';
import { getSettings, getVenue } from '../settings.js';
import { many, one, type Queryable } from '../db.js';
import { toCamel, toCamelAll, lockOne } from './util.js';
import { formatMinor } from '../shared/money.js';
import { onSessionPaymentChanged } from './sessions.js';
import { localDateIn, isValidDate } from '../shared/time.js';

/**
 * Payment provider abstraction. The session system only ever talks to recordPayment(); which provider
 * settles the money is chosen per payment method. Only the manual provider (staff attest that cash/transfer/
 * card-terminal/telebirr money was received) exists today.
 * TODO(phase 2): Telebirr / bank / card provider adapters that return PENDING and settle via webhook.
 */
export interface ProviderChargeResult { status: 'PAID' | 'PENDING' | 'FAILED'; reference: string | null }
export interface PaymentProvider {
  name: string;
  charge(input: { amountMinor: number; currency: string; method: string; reference: string | null; confirmed: boolean }): Promise<ProviderChargeResult>;
}
const manualProvider: PaymentProvider = {
  name: 'manual',
  async charge(i) {
    return { status: i.confirmed ? 'PAID' : 'PENDING', reference: i.reference };
  },
};
export function providerFor(_method: string): PaymentProvider {
  return manualProvider;
}

export const SETTLED = ['PAID', 'PARTIALLY_REFUNDED', 'REFUNDED'];

/** Net settled money for a session's primary charge (refunds subtracted). */
export async function sessionNetPaid(q: Queryable, sessionId: string): Promise<{ paid: number; pending: number }> {
  const r = await one<{ paid: number; pending: number }>(q,
    `SELECT COALESCE(SUM(amount_minor - refunded_minor) FILTER (WHERE status = ANY($2)),0)::bigint AS paid,
            COALESCE(SUM(amount_minor) FILTER (WHERE status IN ('PENDING','AUTHORIZED')),0)::bigint AS pending
       FROM payments WHERE session_id=$1 AND purpose='SESSION'`, [sessionId, SETTLED]);
  return { paid: r?.paid ?? 0, pending: r?.pending ?? 0 };
}

export interface RecordPaymentInput {
  sessionId: string;
  amountMinor: number;
  method: string;
  reference?: string | null;
  note?: string | null;
  /** false = awaiting confirmation (e.g. bank transfer not yet seen). */
  confirmed?: boolean;
  purpose?: 'SESSION' | 'EXTENSION';
}

export async function recordPayment(ctx: Ctx, input: RecordPaymentInput, opts: { sessionLocked?: any } = {}) {
  assertCan(ctx, 'payment.create');
  if (!Number.isSafeInteger(input.amountMinor) || input.amountMinor <= 0) throw E.unprocessable('INVALID_AMOUNT', 'The payment amount must be greater than zero.');
  const settings = await getSettings(ctx.db, ctx.venueId);
  const venue = await getVenue(ctx.db, ctx.venueId);
  const method = settings.paymentMethods.find((m) => m.code === input.method && m.enabled);
  if (!method) throw E.unprocessable('PAYMENT_METHOD_INVALID', `Payment method ${input.method} is not available at this venue.`);
  const confirmed = input.confirmed !== false;
  const reference = input.reference?.trim() || null;
  if (method.requiresReference && confirmed && !reference) {
    throw E.unprocessable('PAYMENT_REFERENCE_REQUIRED', `${method.label} payments need a reference / receipt number.`);
  }
  const s = opts.sessionLocked ?? await lockOne<any>(ctx.db, 'SELECT * FROM sessions WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [input.sessionId, ctx.venueId], 'Session');
  const purpose = input.purpose ?? 'SESSION';
  if (purpose === 'SESSION') {
    if (['CANCELLED', 'NO_SHOW', 'COMPLETED', 'EARLY_EXIT'].includes(s.status)) {
      throw E.conflict('SESSION_NOT_PAYABLE', `This session is ${s.status.toLowerCase().replace('_', ' ')} and can no longer take payments.`);
    }
    const due = s.price_minor - s.discount_minor;
    const { paid, pending } = await sessionNetPaid(ctx.db, s.id);
    if (paid + pending + input.amountMinor > due) {
      throw E.unprocessable('PAYMENT_EXCEEDS_DUE', `That would overpay this session. Remaining to pay: ${formatMinor(Math.max(0, due - paid - pending), s.currency)}.`, { remainingMinor: Math.max(0, due - paid - pending) });
    }
  }
  const result = await providerFor(input.method).charge({ amountMinor: input.amountMinor, currency: s.currency, method: input.method, reference, confirmed });
  const p = (await ctx.db.query(
    `INSERT INTO payments (venue_id, visit_id, session_id, customer_id, amount_minor, currency, method, provider, provider_reference, status, purpose, note, created_by, device_id, created_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$15) RETURNING *`,
    [ctx.venueId, s.visit_id, s.id, s.customer_id, input.amountMinor, s.currency, input.method, providerFor(input.method).name, result.reference,
      result.status, purpose, input.note?.trim() || null, ctx.user?.id ?? null, ctx.deviceId, ctx.now])).rows[0];
  await recordPaymentEvent(ctx, p.id, 'PAYMENT_CREATED', { to: p.status, meta: { amountMinor: p.amount_minor, method: p.method } });
  if (p.status === 'PAID') await settleCharge(ctx, p);
  await audit(ctx, { action: 'payment.created', entityType: 'payment', entityId: p.id, after: { sessionId: s.id, amountMinor: p.amount_minor, method: p.method, status: p.status, reference } });
  await emit(ctx, 'PAYMENT_RECORDED', 'payment', p.id, { paymentId: p.id, sessionId: s.id, status: p.status });
  if (purpose === 'SESSION') await onSessionPaymentChanged(ctx, s.id);
  return toCamel(p);
}

async function settleCharge(ctx: Ctx, p: any) {
  await ctx.db.query(
    `INSERT INTO payment_transactions (venue_id, payment_id, type, amount_minor, currency, method, provider_reference, created_by, created_at)
     VALUES ($1,$2,'CHARGE',$3,$4,$5,$6,$7,$8)`,
    [ctx.venueId, p.id, p.amount_minor, p.currency, p.method, p.provider_reference, ctx.user?.id ?? null, ctx.now]);
  await recordPaymentEvent(ctx, p.id, 'PAYMENT_PAID', { from: 'PENDING', to: 'PAID', meta: { amountMinor: p.amount_minor } });
}

export async function resolvePendingPayment(ctx: Ctx, paymentId: string, outcome: 'CONFIRM' | 'CANCEL' | 'FAIL', reference?: string | null) {
  assertCan(ctx, 'payment.create');
  const p0 = await one<any>(ctx.db, 'SELECT session_id FROM payments WHERE id=$1 AND venue_id=$2', [paymentId, ctx.venueId]);
  if (!p0) throw E.notFound('Payment');
  // lock order: session, then payment
  if (p0.session_id) await ctx.db.query('SELECT 1 FROM sessions WHERE id=$1 FOR NO KEY UPDATE', [p0.session_id]);
  const p = await lockOne<any>(ctx.db, 'SELECT * FROM payments WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [paymentId, ctx.venueId], 'Payment');
  if (p.status !== 'PENDING') throw E.conflict('PAYMENT_NOT_PENDING', `This payment is already ${p.status.toLowerCase().replace('_', ' ')}.`);
  const to = outcome === 'CONFIRM' ? 'PAID' : outcome === 'CANCEL' ? 'CANCELLED' : 'FAILED';
  const settings = await getSettings(ctx.db, ctx.venueId);
  const method = settings.paymentMethods.find((m) => m.code === p.method);
  const ref = reference?.trim() || p.provider_reference;
  if (to === 'PAID' && method?.requiresReference && !ref) throw E.unprocessable('PAYMENT_REFERENCE_REQUIRED', 'A reference / receipt number is needed to confirm this payment.');
  const upd = (await ctx.db.query('UPDATE payments SET status=$2, provider_reference=$3, updated_at=$4 WHERE id=$1 RETURNING *', [paymentId, to, ref, ctx.now])).rows[0];
  if (to === 'PAID') await settleCharge(ctx, upd);
  else await recordPaymentEvent(ctx, paymentId, `PAYMENT_${to}`, { from: 'PENDING', to });
  await audit(ctx, { action: `payment.${to.toLowerCase()}`, entityType: 'payment', entityId: paymentId, before: { status: 'PENDING' }, after: { status: to } });
  await emit(ctx, 'PAYMENT_RECORDED', 'payment', paymentId, { paymentId, status: to });
  if (p.session_id) await onSessionPaymentChanged(ctx, p.session_id);
  return toCamel(upd);
}

export async function refundPayment(ctx: Ctx, paymentId: string, input: { amountMinor?: number; reason: string }) {
  assertCan(ctx, 'payment.refund');
  if (!input.reason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'A reason is required for every refund.');
  const p0 = await one<any>(ctx.db, 'SELECT session_id FROM payments WHERE id=$1 AND venue_id=$2', [paymentId, ctx.venueId]);
  if (!p0) throw E.notFound('Payment');
  if (p0.session_id) await ctx.db.query('SELECT 1 FROM sessions WHERE id=$1 FOR NO KEY UPDATE', [p0.session_id]);
  // Row lock makes two simultaneous refunds of the same payment serialize; the loser sees the updated refunded_minor.
  const p = await lockOne<any>(ctx.db, 'SELECT * FROM payments WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [paymentId, ctx.venueId], 'Payment');
  if (!['PAID', 'PARTIALLY_REFUNDED'].includes(p.status)) {
    throw E.conflict('PAYMENT_NOT_REFUNDABLE', p.status === 'REFUNDED' ? 'This payment has already been fully refunded.' : `A ${p.status.toLowerCase()} payment cannot be refunded.`);
  }
  const refundable = p.amount_minor - p.refunded_minor;
  const amount = input.amountMinor ?? refundable;
  if (!Number.isSafeInteger(amount) || amount <= 0) throw E.unprocessable('INVALID_AMOUNT', 'The refund amount must be greater than zero.');
  if (amount > refundable) throw E.unprocessable('REFUND_EXCEEDS_PAYMENT', `Only ${formatMinor(refundable, p.currency)} can still be refunded on this payment.`, { refundableMinor: refundable });
  const tx = (await ctx.db.query(
    `INSERT INTO payment_transactions (venue_id, payment_id, type, amount_minor, currency, method, provider_reference, created_by, created_at)
     VALUES ($1,$2,'REFUND',$3,$4,$5,$6,$7,$8) RETURNING id`,
    [ctx.venueId, paymentId, amount, p.currency, p.method, p.provider_reference, ctx.user?.id ?? null, ctx.now])).rows[0];
  const refund = (await ctx.db.query(
    `INSERT INTO refunds (venue_id, payment_id, transaction_id, amount_minor, reason, status, requested_by, approved_by, created_at)
     VALUES ($1,$2,$3,$4,$5,'COMPLETED',$6,$6,$7) RETURNING id, amount_minor, created_at`,
    [ctx.venueId, paymentId, tx.id, amount, input.reason.trim(), ctx.user?.id ?? null, ctx.now])).rows[0];
  const newRefunded = p.refunded_minor + amount;
  const newStatus = newRefunded === p.amount_minor ? 'REFUNDED' : 'PARTIALLY_REFUNDED';
  await ctx.db.query('UPDATE payments SET refunded_minor=$2, status=$3, updated_at=$4 WHERE id=$1', [paymentId, newRefunded, newStatus, ctx.now]);
  await recordPaymentEvent(ctx, paymentId, 'PAYMENT_REFUNDED', { from: p.status, to: newStatus, meta: { amountMinor: amount, reason: input.reason.trim(), refundId: refund.id } });
  await audit(ctx, { action: 'payment.refunded', entityType: 'payment', entityId: paymentId, reason: input.reason.trim(),
    before: { status: p.status, refundedMinor: p.refunded_minor }, after: { status: newStatus, refundedMinor: newRefunded, refundMinor: amount } });
  await emit(ctx, 'PAYMENT_REFUNDED', 'payment', paymentId, { paymentId, sessionId: p.session_id, amountMinor: amount });
  return { refundId: refund.id, paymentId, status: newStatus, refundedMinor: newRefunded, refundMinor: amount, remainingRefundableMinor: p.amount_minor - newRefunded };
}

export async function listPayments(ctx: Ctx, opts: { date?: string; status?: string; limit?: number; offset?: number }) {
  assertCan(ctx, 'payment.read');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const date = opts.date ?? localDateIn(venue.timezone, ctx.now);
  if (!isValidDate(date)) throw E.badRequest('INVALID_DATE', 'Use a date like 2026-09-30.');
  const params: unknown[] = [ctx.venueId, date, venue.timezone, opts.limit ?? 200, opts.offset ?? 0];
  let st = '';
  if (opts.status) { params.push(opts.status); st = ` AND p.status = $${params.length}`; }
  const rows = await many<any>(ctx.db,
    `SELECT p.id, p.amount_minor, p.refunded_minor, p.currency, p.method, p.status, p.purpose, p.provider_reference, p.created_at,
            c.full_name AS customer_name, v.visit_number, u.full_name AS staff_name, p.session_id
       FROM payments p JOIN customers c ON c.id = p.customer_id JOIN visits v ON v.id = p.visit_id LEFT JOIN users u ON u.id = p.created_by
      WHERE p.venue_id=$1 AND (p.created_at AT TIME ZONE $3)::date = $2::date${st} ORDER BY p.created_at DESC LIMIT $4 OFFSET $5`, params);
  return toCamelAll(rows);
}

export async function getPayment(ctx: Ctx, id: string) {
  assertCan(ctx, 'payment.read');
  const p = await one<any>(ctx.db, 'SELECT * FROM payments WHERE id=$1 AND venue_id=$2', [id, ctx.venueId]);
  if (!p) throw E.notFound('Payment');
  const tx = await many<any>(ctx.db, 'SELECT id, type, amount_minor, method, created_at, created_by FROM payment_transactions WHERE payment_id=$1 ORDER BY created_at', [id]);
  const events = await many<any>(ctx.db,
    `SELECT pe.event_type, pe.from_status, pe.to_status, pe.occurred_at, pe.metadata, u.full_name AS actor_name FROM payment_events pe LEFT JOIN users u ON u.id=pe.actor_user_id WHERE pe.payment_id=$1 ORDER BY pe.id`, [id]);
  const refunds = await many<any>(ctx.db, 'SELECT id, amount_minor, reason, status, created_at FROM refunds WHERE payment_id=$1 ORDER BY created_at', [id]);
  return { ...toCamel(p), transactions: toCamelAll(tx), events: toCamelAll(events), refunds: toCamelAll(refunds), canRefund: can(ctx, 'payment.refund') };
}
