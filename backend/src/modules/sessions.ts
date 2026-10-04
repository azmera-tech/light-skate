import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { AppError, E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit, recordSessionEvent } from '../shared/events.js';
import { getSettings, getVenue } from '../settings.js';
import { many, one, withTx, pool } from '../db.js';
import { toCamel, toCamelAll, lockOne, secondsBetween } from './util.js';
import { assertTransition, OCCUPANCY_STATUSES, LIVE_STATUSES, TERMINAL_STATUSES, type SessionStatus } from './sessions-machine.js';
import { countOccupancy, getMaxCapacity, lockVenue } from './capacity.js';
import { sessionNetPaid, recordPayment } from './payments.js';
import { assignEquipmentTx } from './equipment.js';
import { completeVisitIfDone } from './visits.js';
import { waiverStatus } from './waivers.js';
import { dayKind, ruleApplies } from './pricing.js';
import { isMinor } from './customers.js';
import { formatMinor } from '../shared/money.js';
import { localMinutesIn, localWeekdayIn } from '../shared/time.js';
import { LATEST_PHOTO_SQL } from './photos.js';
import { clock } from '../shared/clock.js';

// ---------- helpers ----------

/** Seconds remaining in paid time at instant `at`. A frozen (paused, not-counted) session stops at paused_at. */
export function remainingSeconds(s: { status: string; scheduled_end_at: Date | string | null; paused_at: Date | string | null; pause_counts_toward_time: boolean }, at: Date): number | null {
  if (!s.scheduled_end_at) return null;
  const end = new Date(s.scheduled_end_at).getTime();
  const ref = s.status === 'PAUSED' && !s.pause_counts_toward_time && s.paused_at ? new Date(s.paused_at).getTime() : at.getTime();
  return Math.round((end - ref) / 1000);
}

async function lockSession(ctx: Ctx, id: string) {
  return lockOne<any>(ctx.db, 'SELECT * FROM sessions WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Session');
}

/** Apply a validated state transition + write its immutable event. */
async function transition(
  ctx: Ctx, s: any, to: SessionStatus, action: string, eventType: string,
  patch: Record<string, unknown> = {}, meta: Record<string, unknown> = {}, at?: Date, opts: { skipValidation?: boolean } = {},
) {
  if (!opts.skipValidation) assertTransition(s.status, to, action);
  const cols = Object.keys(patch);
  const params: unknown[] = [s.id, to, ctx.now];
  const sets = cols.map((c) => { params.push(patch[c]); return `${c} = $${params.length}`; });
  const r = await ctx.db.query(
    `UPDATE sessions SET status=$2, updated_at=$3, version=version+1${sets.length ? ', ' + sets.join(', ') : ''} WHERE id=$1 RETURNING *`, params);
  const upd = r.rows[0];
  await recordSessionEvent(ctx, upd, eventType, { from: s.status, to, meta, at });
  return upd;
}

async function patchSession(ctx: Ctx, s: any, patch: Record<string, unknown>) {
  const cols = Object.keys(patch);
  const params: unknown[] = [s.id, ctx.now];
  const sets = cols.map((c) => { params.push(patch[c]); return `${c} = $${params.length}`; });
  return (await ctx.db.query(`UPDATE sessions SET updated_at=$2, version=version+1, ${sets.join(', ')} WHERE id=$1 RETURNING *`, params)).rows[0];
}

async function capacityEvent(ctx: Ctx) {
  const occupancy = await countOccupancy(ctx.db, ctx.venueId);
  const max = await getMaxCapacity(ctx.db, ctx.venueId, ctx.now);
  await emit(ctx, 'CAPACITY_CHANGED', 'venue', ctx.venueId, { occupancy, max });
  return { occupancy, max };
}

// ---------- create ----------

export interface CreateSessionInput {
  visitId: string; pricingRuleId: string; discountMinor?: number; discountReason?: string | null; wristband?: string | null;
}

export async function createSession(ctx: Ctx, input: CreateSessionInput) {
  assertCan(ctx, 'session.create');
  const visit = await lockOne<any>(ctx.db, 'SELECT * FROM visits WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [input.visitId, ctx.venueId], 'Visit');
  if (visit.status !== 'OPEN') throw E.conflict('VISIT_CLOSED', `This visit is ${visit.status.toLowerCase()}. Start a new visit for this customer.`);
  const cust = await one<any>(ctx.db, 'SELECT id, status, date_of_birth FROM customers WHERE id=$1', [visit.customer_id]);
  if (cust.status !== 'ACTIVE') throw E.conflict('CUSTOMER_INACTIVE', 'This customer record is not active.');
  const existing = await one<any>(ctx.db, `SELECT id, status FROM sessions WHERE visit_id=$1 AND status NOT IN ('CANCELLED','NO_SHOW','COMPLETED','EARLY_EXIT') LIMIT 1`, [visit.id]);
  if (existing) throw E.conflict('VISIT_HAS_SESSION', 'This visit already has a session in progress.', { sessionId: existing.id });

  const settings = await getSettings(ctx.db, ctx.venueId);
  const venue = await getVenue(ctx.db, ctx.venueId);
  const rule = await one<any>(ctx.db, `SELECT * FROM pricing_rules WHERE id=$1 AND venue_id=$2`, [input.pricingRuleId, ctx.venueId]);
  if (!rule || !rule.active || rule.kind !== 'SESSION') throw E.unprocessable('PRODUCT_UNAVAILABLE', 'That session option is not available.');
  if (!ruleApplies(rule, dayKind(settings, venue.timezone, ctx.now), isMinor(cust.date_of_birth, settings.minorAgeYears, ctx.now))) {
    throw E.unprocessable('PRODUCT_NOT_APPLICABLE', 'That session option does not apply to this customer or today.');
  }
  const discount = input.discountMinor ?? 0;
  if (discount > 0) {
    assertCan(ctx, 'payment.discount');
    if (!input.discountReason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'A reason is required when applying a discount.');
    if (discount > rule.price_minor) throw E.unprocessable('DISCOUNT_TOO_LARGE', 'The discount cannot be larger than the price.');
  }
  if (input.wristband && !settings.wristbands.enabled) throw E.unprocessable('WRISTBANDS_DISABLED', 'Wristbands are not enabled at this venue.');

  const r = await ctx.db.query(
    `INSERT INTO sessions (venue_id, visit_id, customer_id, status, pricing_rule_id, product_name, price_minor, discount_minor, discount_reason, currency,
        original_duration_seconds, current_duration_seconds, wristband, created_by, device_id, created_at, updated_at)
     VALUES ($1,$2,$3,'CREATED',$4,$5,$6,$7,$8,$9,$10,$10,$11,$12,$13,$14,$14) RETURNING *`,
    [ctx.venueId, visit.id, visit.customer_id, rule.id, rule.name, rule.price_minor, discount, input.discountReason?.trim() ?? null, rule.currency,
      rule.duration_minutes * 60, input.wristband ?? null, ctx.user?.id ?? null, ctx.deviceId, ctx.now]);
  let s = r.rows[0];
  await recordSessionEvent(ctx, s, 'SESSION_CREATED', { to: 'CREATED', meta: { product: rule.name, priceMinor: rule.price_minor, discountMinor: discount, durationSeconds: s.original_duration_seconds } });
  const due = s.price_minor - s.discount_minor;
  s = due > 0
    ? await transition(ctx, s, 'PAYMENT_PENDING', 'request payment', 'PAYMENT_REQUESTED', {}, { dueMinor: due })
    : await transition(ctx, s, 'READY', 'become ready', 'PAYMENT_CONFIRMED', {}, { dueMinor: 0, complimentary: true });
  await audit(ctx, { action: 'session.created', entityType: 'session', entityId: s.id, after: { visitId: visit.id, product: rule.name, priceMinor: s.price_minor, discountMinor: discount }, reason: input.discountReason ?? null });
  await emit(ctx, 'SESSION_CREATED', 'session', s.id, { sessionId: s.id, status: s.status });
  return toCamel(s);
}

/** Called after any payment change: PAYMENT_PENDING -> READY once the amount due is settled. */
export async function onSessionPaymentChanged(ctx: Ctx, sessionId: string) {
  const s = await one<any>(ctx.db, 'SELECT * FROM sessions WHERE id=$1', [sessionId]);
  if (!s || s.status !== 'PAYMENT_PENDING') return;
  const { paid } = await sessionNetPaid(ctx.db, s.id);
  if (paid >= s.price_minor - s.discount_minor) {
    await transition(ctx, s, 'READY', 'become ready', 'PAYMENT_CONFIRMED', {}, { paidMinor: paid });
    await emit(ctx, 'SESSION_READY', 'session', s.id, { sessionId: s.id });
  }
}

// ---------- start ----------

export interface StartInput { equipmentIds?: string[]; wristband?: string | null; overrideCapacityReason?: string | null }

export async function startSession(ctx: Ctx, sessionId: string, input: StartInput = {}) {
  assertCan(ctx, 'session.create');
  // Lock order (everywhere): session -> venue -> customer -> equipment.
  let s = await lockSession(ctx, sessionId);
  if (s.status !== 'READY') {
    if (s.status === 'PAYMENT_PENDING') throw E.conflict('PAYMENT_INCOMPLETE', 'Payment for this session is not complete yet.');
    if (['ACTIVE', 'EXPIRING', 'PAUSED', 'EXPIRED', 'CHECKED_IN'].includes(s.status)) throw E.conflict('SESSION_ALREADY_STARTED', 'This session has already been started.');
    assertTransition(s.status, 'CHECKED_IN', 'start');
  }
  await lockVenue(ctx.db, ctx.venueId);
  const cust = await lockOne<any>(ctx.db, 'SELECT id, status, full_name FROM customers WHERE id=$1 FOR NO KEY UPDATE', [s.customer_id], 'Customer');
  if (cust.status !== 'ACTIVE') throw E.conflict(cust.status === 'BLOCKED' ? 'CUSTOMER_BLOCKED' : 'CUSTOMER_INACTIVE', cust.status === 'BLOCKED' ? 'This customer is blocked. Please speak to a manager.' : 'This customer record is not active.');
  const other = await one<any>(ctx.db, `SELECT id FROM sessions WHERE customer_id=$1 AND id<>$2 AND status = ANY($3) LIMIT 1`, [s.customer_id, s.id, LIVE_STATUSES]);
  if (other) throw E.conflict('CUSTOMER_ALREADY_ACTIVE', `Session cannot be started because ${cust.full_name} already has an active session.`, { sessionId: other.id });

  const settings = await getSettings(ctx.db, ctx.venueId);
  const venue = await getVenue(ctx.db, ctx.venueId);

  if (settings.waiverRequired) {
    const w = await waiverStatus(ctx.db, ctx.venueId, s.customer_id);
    if (!w.accepted) {
      throw E.conflict(w.isMinor && w.currentVersionId ? 'GUARDIAN_WAIVER_REQUIRED' : 'WAIVER_REQUIRED',
        w.isMinor ? 'A guardian must accept the waiver for this minor before skating.' : 'The customer must accept the current waiver before skating.');
    }
  }
  const { paid } = await sessionNetPaid(ctx.db, s.id);
  const due = s.price_minor - s.discount_minor;
  if (paid < due) throw E.conflict('PAYMENT_INCOMPLETE', `Payment is incomplete: ${formatMinor(paid, s.currency)} of ${formatMinor(due, s.currency)} received.`);

  if (settings.enforceOperatingHours) {
    const hrs = settings.operatingHours[String(localWeekdayIn(venue.timezone, ctx.now))];
    const mins = localMinutesIn(venue.timezone, ctx.now);
    const toMin = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3));
    if (!hrs || mins < toMin(hrs.open) || mins >= toMin(hrs.close)) {
      throw E.conflict('VENUE_CLOSED', hrs ? `The venue is closed right now (open ${hrs.open}–${hrs.close}).` : 'The venue is closed today.');
    }
  }

  // Capacity is decided here, inside the transaction, under the venue lock — never by the client.
  const max = await getMaxCapacity(ctx.db, ctx.venueId, ctx.now);
  const occupancy = await countOccupancy(ctx.db, ctx.venueId);
  let overridden = false;
  if (occupancy >= max) {
    if (input.overrideCapacityReason?.trim() && can(ctx, 'session.override_capacity')) overridden = true;
    else throw E.conflict('VENUE_FULL', `Venue is full (${occupancy} / ${max}). New sessions cannot start until someone leaves.`, { occupancy, max, canOverride: can(ctx, 'session.override_capacity') });
  }

  if (settings.equipmentRequiredForStart && !(input.equipmentIds?.length)) throw E.unprocessable('EQUIPMENT_REQUIRED', 'Rental equipment must be issued before this session can start.');
  if (input.wristband && !settings.wristbands.enabled) throw E.unprocessable('WRISTBANDS_DISABLED', 'Wristbands are not enabled at this venue.');

  const started = ctx.now;
  const end = new Date(started.getTime() + s.current_duration_seconds * 1000);
  s = await transition(ctx, s, 'CHECKED_IN', 'check in', 'CHECKED_IN', {}, {});
  await ctx.db.query('UPDATE visits SET checked_in_at = COALESCE(checked_in_at, $2) WHERE id=$1', [s.visit_id, started]);
  s = await transition(ctx, s, 'ACTIVE', 'start', 'SESSION_STARTED', {
    started_at: started, scheduled_end_at: end, started_by: ctx.user?.id ?? null, pause_counts_toward_time: settings.pause.countsTowardTime,
    wristband: input.wristband ?? s.wristband, device_id: ctx.deviceId ?? s.device_id,
  }, { startedAt: started.toISOString(), scheduledEndAt: end.toISOString(), capacityOverride: overridden ? input.overrideCapacityReason : undefined });

  const issued = input.equipmentIds?.length ? await assignEquipmentTx(ctx, s, input.equipmentIds) : [];

  await audit(ctx, { action: 'session.started', entityType: 'session', entityId: s.id,
    after: { startedAt: started, scheduledEndAt: end, equipment: issued.map((i) => i.code), wristband: s.wristband }, reason: overridden ? `Capacity override: ${input.overrideCapacityReason}` : null });
  if (overridden) await audit(ctx, { action: 'capacity.overridden', entityType: 'session', entityId: s.id, reason: input.overrideCapacityReason, after: { occupancy, max } });
  await emit(ctx, 'SESSION_STARTED', 'session', s.id, { sessionId: s.id, customerId: s.customer_id, startedAt: started.toISOString(), scheduledEndAt: end.toISOString() });
  const cap = await capacityEvent(ctx);
  if (cap.occupancy >= cap.max) await emit(ctx, 'CAPACITY_FULL', 'venue', ctx.venueId, { occupancy: cap.occupancy, max: cap.max });
  return { ...toCamel(s), equipment: issued, occupancy: cap.occupancy, maxCapacity: cap.max };
}

// ---------- pause / resume ----------

export async function pauseSession(ctx: Ctx, sessionId: string, input: { reason?: string | null } = {}) {
  assertCan(ctx, 'session.pause');
  const settings = await getSettings(ctx.db, ctx.venueId);
  if (!settings.pause.enabled) throw E.conflict('PAUSE_DISABLED', 'Pausing sessions is not enabled at this venue.');
  const s = await lockSession(ctx, sessionId);
  assertTransition(s.status, 'PAUSED', 'be paused');
  await ctx.db.query(
    `INSERT INTO session_pauses (venue_id, session_id, paused_at, counted_toward_time, reason, paused_by, device_id) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [ctx.venueId, s.id, ctx.now, s.pause_counts_toward_time, input.reason ?? null, ctx.user?.id ?? null, ctx.deviceId]);
  const upd = await transition(ctx, s, 'PAUSED', 'be paused', 'SESSION_PAUSED', { paused_at: ctx.now }, { reason: input.reason ?? null, countsTowardTime: s.pause_counts_toward_time });
  await audit(ctx, { action: 'session.paused', entityType: 'session', entityId: s.id, reason: input.reason ?? null });
  await emit(ctx, 'SESSION_PAUSED', 'session', s.id, { sessionId: s.id });
  return toCamel(upd);
}

export async function resumeSession(ctx: Ctx, sessionId: string, input: { reason?: string | null } = {}) {
  assertCan(ctx, 'session.pause');
  const s = await lockSession(ctx, sessionId);
  assertTransition(s.status, 'ACTIVE', 'be resumed');
  const pauseRow = await lockOne<any>(ctx.db, 'SELECT * FROM session_pauses WHERE session_id=$1 AND resumed_at IS NULL FOR NO KEY UPDATE', [s.id], 'Open pause');
  const d = Math.max(0, secondsBetween(new Date(pauseRow.paused_at), ctx.now));
  await ctx.db.query('UPDATE session_pauses SET resumed_at=$2, duration_seconds=$3, resumed_by=$4 WHERE id=$1', [pauseRow.id, ctx.now, d, ctx.user?.id ?? null]);
  const patch: Record<string, unknown> = { paused_at: null, total_paused_seconds: s.total_paused_seconds + d };
  let newEnd: Date | null = null;
  if (!s.pause_counts_toward_time) { // paused time is not consumed: push the end out by the pause length
    newEnd = new Date(new Date(s.scheduled_end_at).getTime() + d * 1000);
    patch.scheduled_end_at = newEnd;
  }
  const upd = await transition(ctx, s, 'ACTIVE', 'be resumed', 'SESSION_RESUMED', patch,
    { pausedSeconds: d, countedTowardTime: s.pause_counts_toward_time, newEndAt: (newEnd ?? new Date(s.scheduled_end_at)).toISOString(), reason: input.reason ?? null });
  await audit(ctx, { action: 'session.resumed', entityType: 'session', entityId: s.id, after: { pausedSeconds: d, newEndAt: upd.scheduled_end_at } });
  await emit(ctx, 'SESSION_RESUMED', 'session', s.id, { sessionId: s.id, scheduledEndAt: new Date(upd.scheduled_end_at).toISOString() });
  return toCamel(upd);
}

// ---------- extend ----------

export interface ExtendInput {
  minutes: number; reason?: string | null;
  payment?: { method: string; reference?: string | null } | null;
  complimentary?: boolean;
}

export async function extendSession(ctx: Ctx, sessionId: string, input: ExtendInput) {
  assertCan(ctx, 'session.extend');
  const settings = await getSettings(ctx.db, ctx.venueId);
  if (!settings.extensionOptionsMinutes.includes(input.minutes)) {
    throw E.unprocessable('EXTENSION_NOT_ALLOWED', `Extensions of ${input.minutes} minutes are not offered. Allowed: ${settings.extensionOptionsMinutes.join(', ')} minutes.`);
  }
  const s = await lockSession(ctx, sessionId);
  if (!['ACTIVE', 'EXPIRING', 'EXPIRED', 'PAUSED'].includes(s.status)) {
    assertTransition(s.status, 'ACTIVE', 'be extended'); // throws the friendly state error
    throw E.conflict('SESSION_INVALID_TRANSITION', 'This session cannot be extended right now.');
  }
  const rule = await one<any>(ctx.db, `SELECT * FROM pricing_rules WHERE venue_id=$1 AND kind='EXTENSION' AND active AND duration_minutes=$2 ORDER BY sort_order LIMIT 1`, [ctx.venueId, input.minutes]);
  const price = rule?.price_minor ?? 0;
  let paymentId: string | null = null;
  if (price > 0) {
    if (input.complimentary) {
      assertCan(ctx, 'payment.discount');
      if (!input.reason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'A reason is required for a complimentary extension.');
    } else if (input.payment) {
      const p = await recordPayment(ctx, { sessionId: s.id, amountMinor: price, method: input.payment.method, reference: input.payment.reference, purpose: 'EXTENSION' }, { sessionLocked: s });
      paymentId = p.id;
    } else {
      throw E.unprocessable('EXTENSION_PAYMENT_REQUIRED', `Extending by ${input.minutes} minutes costs ${formatMinor(price, s.currency)}. Record the payment to continue.`, { priceMinor: price });
    }
  }
  const originalEnd = new Date(s.scheduled_end_at);
  const base = s.status === 'EXPIRED' ? new Date(Math.max(originalEnd.getTime(), ctx.now.getTime())) : originalEnd;
  const added = input.minutes * 60;
  const newEnd = new Date(base.getTime() + added * 1000);
  await ctx.db.query(
    `INSERT INTO session_extensions (venue_id, session_id, added_seconds, original_end_at, new_end_at, price_minor, payment_id, reason, extended_by, device_id, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
    [ctx.venueId, s.id, added, originalEnd, newEnd, input.complimentary ? 0 : price, paymentId, input.reason ?? null, ctx.user?.id ?? null, ctx.deviceId, ctx.now]);
  const patch = { scheduled_end_at: newEnd, current_duration_seconds: s.current_duration_seconds + added };
  const meta = { originalEndAt: originalEnd.toISOString(), addedSeconds: added, newEndAt: newEnd.toISOString(), reason: input.reason ?? null, priceMinor: input.complimentary ? 0 : price, paymentId, complimentary: !!input.complimentary };
  let upd: any;
  if (s.status === 'EXPIRING' || s.status === 'EXPIRED') upd = await transition(ctx, s, 'ACTIVE', 'be extended', 'SESSION_EXTENDED', patch, meta);
  else { upd = await patchSession(ctx, s, patch); await recordSessionEvent(ctx, upd, 'SESSION_EXTENDED', { from: s.status, to: s.status, meta }); }
  await audit(ctx, { action: 'session.extended', entityType: 'session', entityId: s.id, reason: input.reason ?? null,
    before: { scheduledEndAt: originalEnd }, after: { scheduledEndAt: newEnd, addedMinutes: input.minutes, priceMinor: meta.priceMinor } });
  await emit(ctx, 'SESSION_EXTENDED', 'session', s.id, { sessionId: s.id, scheduledEndAt: newEnd.toISOString() });
  return toCamel(upd);
}

// ---------- end ----------

export async function endSession(ctx: Ctx, sessionId: string, input: { issuedAt?: Date | null; reason?: string | null } = {}) {
  assertCan(ctx, 'session.end');
  const s = await lockSession(ctx, sessionId);
  assertTransition(s.status, 'COMPLETED', 'be ended');
  const settings = await getSettings(ctx.db, ctx.venueId);
  // Offline replays may carry the time the staff member actually pressed END; honour it only within sane bounds.
  let endedAt = ctx.now;
  if (input.issuedAt) {
    const lo = new Date(s.started_at).getTime();
    endedAt = new Date(Math.min(ctx.now.getTime(), Math.max(lo, input.issuedAt.getTime())));
  }
  let pausedExtra = 0;
  if (s.status === 'PAUSED') {
    const pauseRow = await one<any>(ctx.db, 'SELECT * FROM session_pauses WHERE session_id=$1 AND resumed_at IS NULL FOR NO KEY UPDATE', [s.id]);
    if (pauseRow) {
      pausedExtra = Math.max(0, secondsBetween(new Date(pauseRow.paused_at), endedAt));
      await ctx.db.query('UPDATE session_pauses SET resumed_at=$2, duration_seconds=$3, resumed_by=$4 WHERE id=$1', [pauseRow.id, endedAt, pausedExtra, ctx.user?.id ?? null]);
    }
  }
  const remaining = remainingSeconds(s, endedAt) ?? 0;
  const early = remaining > settings.earlyExitGraceSeconds && s.status !== 'EXPIRED';
  const to: SessionStatus = early ? 'EARLY_EXIT' : 'COMPLETED';
  const upd = await transition(ctx, s, to, 'be ended', 'SESSION_ENDED', {
    actual_end_at: endedAt, ended_by: ctx.user?.id ?? null, paused_at: null, total_paused_seconds: s.total_paused_seconds + pausedExtra,
  }, {
    outcome: to, scheduledEndAt: new Date(s.scheduled_end_at).toISOString(), remainingSeconds: remaining,
    overtimeSeconds: remaining < 0 ? -remaining : 0,
    clientIssuedAt: input.issuedAt ? input.issuedAt.toISOString() : undefined, reason: input.reason ?? undefined,
  }, endedAt);
  const visitDone = await completeVisitIfDone(ctx, s.visit_id);
  if (visitDone) await recordSessionEvent(ctx, upd, 'VISIT_COMPLETED', { at: endedAt });
  const outstanding = (await many<any>(ctx.db, `SELECT e.code FROM equipment_assignments ea JOIN equipment e ON e.id=ea.equipment_id WHERE ea.session_id=$1 AND ea.returned_at IS NULL ORDER BY e.code`, [s.id])).map((r) => r.code);
  await audit(ctx, { action: 'session.ended', entityType: 'session', entityId: s.id, after: { outcome: to, endedAt, equipmentOutstanding: outstanding }, reason: input.reason ?? null });
  await emit(ctx, 'SESSION_ENDED', 'session', s.id, { sessionId: s.id, outcome: to });
  const cap = await capacityEvent(ctx);
  if (visitDone) await emit(ctx, 'VISIT_COMPLETED', 'visit', s.visit_id, { visitId: s.visit_id });
  return { ...toCamel(upd), equipmentOutstanding: outstanding, visitCompleted: visitDone, occupancy: cap.occupancy };
}

// ---------- cancel ----------

export async function cancelSession(ctx: Ctx, sessionId: string, input: { reason: string }) {
  assertCan(ctx, 'session.cancel');
  if (!input.reason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'A reason is required to cancel a session.');
  const s = await lockSession(ctx, sessionId);
  assertTransition(s.status, 'CANCELLED', 'be cancelled');
  const upd = await transition(ctx, s, 'CANCELLED', 'be cancelled', 'SESSION_CANCELLED', {}, { reason: input.reason.trim() });
  await ctx.db.query(`UPDATE visits SET status='CANCELLED', closed_at=$2 WHERE id=$1 AND status='OPEN'
     AND NOT EXISTS (SELECT 1 FROM sessions x WHERE x.visit_id=$1 AND x.status NOT IN ('CANCELLED','NO_SHOW'))`, [s.visit_id, ctx.now]);
  const { paid } = await sessionNetPaid(ctx.db, s.id);
  await audit(ctx, { action: 'session.cancelled', entityType: 'session', entityId: s.id, reason: input.reason.trim(), after: { paidMinor: paid } });
  await emit(ctx, 'SESSION_CANCELLED', 'session', s.id, { sessionId: s.id });
  return { ...toCamel(upd), refundDueMinor: paid };
}

// ---------- correction (controlled, audited) ----------

export type CorrectInput =
  | { action: 'CHANGE_DURATION'; newDurationMinutes: number; reason: string }
  | { action: 'REOPEN'; reason: string };

export async function correctSession(ctx: Ctx, sessionId: string, input: CorrectInput) {
  assertCan(ctx, 'session.correct');
  if (!input.reason?.trim()) throw E.unprocessable('REASON_REQUIRED', 'A reason is required for every correction.');
  const s = await lockSession(ctx, sessionId);
  if (input.action === 'CHANGE_DURATION') {
    if (!Number.isInteger(input.newDurationMinutes) || input.newDurationMinutes < 1 || input.newDurationMinutes > 600) throw E.unprocessable('INVALID_DURATION', 'Choose a duration between 1 and 600 minutes.');
    if (TERMINAL_STATUSES.includes(s.status)) throw E.conflict('SESSION_INVALID_TRANSITION', `Session is already ${s.status.toLowerCase().replace('_', ' ')}; reopen it first if it was ended by mistake.`);
    const newSeconds = input.newDurationMinutes * 60;
    const before = { durationSeconds: s.current_duration_seconds, scheduledEndAt: s.scheduled_end_at };
    const patch: Record<string, unknown> = { current_duration_seconds: newSeconds };
    if (!s.started_at) patch.original_duration_seconds = newSeconds;
    let newEnd: Date | null = null;
    if (s.started_at) {
      newEnd = new Date(new Date(s.started_at).getTime() + (newSeconds + (s.pause_counts_toward_time ? 0 : s.total_paused_seconds)) * 1000);
      patch.scheduled_end_at = newEnd;
    }
    let upd: any;
    const meta = { action: 'CHANGE_DURATION', original: before, corrected: { durationSeconds: newSeconds, scheduledEndAt: newEnd }, reason: input.reason.trim() };
    if (s.status === 'EXPIRED' && newEnd && newEnd > ctx.now) upd = await transition(ctx, s, 'ACTIVE', 'be corrected', 'SESSION_CORRECTED', patch, meta);
    else { upd = await patchSession(ctx, s, patch); await recordSessionEvent(ctx, upd, 'SESSION_CORRECTED', { from: s.status, to: s.status, meta }); }
    await audit(ctx, { action: 'session.corrected', entityType: 'session', entityId: s.id, reason: input.reason.trim(), before, after: { durationSeconds: newSeconds, scheduledEndAt: newEnd } });
    await emit(ctx, 'SESSION_EXTENDED', 'session', s.id, { sessionId: s.id, scheduledEndAt: newEnd ? newEnd.toISOString() : null });
    return toCamel(upd);
  }
  // REOPEN: the only way out of a terminal state, and only for ended-by-mistake sessions.
  if (!['COMPLETED', 'EARLY_EXIT'].includes(s.status)) throw E.conflict('SESSION_INVALID_TRANSITION', 'Only a completed or early-exit session can be reopened.');
  await lockVenue(ctx.db, ctx.venueId);
  const other = await one<any>(ctx.db, `SELECT id FROM sessions WHERE customer_id=$1 AND id<>$2 AND status = ANY($3) LIMIT 1`, [s.customer_id, s.id, LIVE_STATUSES]);
  if (other) throw E.conflict('CUSTOMER_ALREADY_ACTIVE', 'This customer already has another active session.');
  const max = await getMaxCapacity(ctx.db, ctx.venueId, ctx.now);
  const occupancy = await countOccupancy(ctx.db, ctx.venueId);
  if (occupancy >= max) throw E.conflict('VENUE_FULL', `Venue is full (${occupancy} / ${max}); the session cannot be reopened right now.`, { occupancy, max });
  const upd = await transition(ctx, s, 'ACTIVE', 'be reopened', 'SESSION_REOPENED', { actual_end_at: null, ended_by: null }, { reason: input.reason.trim(), previousStatus: s.status }, undefined, { skipValidation: true });
  await ctx.db.query(`UPDATE visits SET status='OPEN', closed_at=NULL WHERE id=$1`, [s.visit_id]);
  await audit(ctx, { action: 'session.reopened', entityType: 'session', entityId: s.id, reason: input.reason.trim(), before: { status: s.status, actualEndAt: s.actual_end_at }, after: { status: 'ACTIVE' } });
  await emit(ctx, 'SESSION_STARTED', 'session', s.id, { sessionId: s.id });
  await capacityEvent(ctx);
  return toCamel(upd);
}

// ---------- queries ----------

const SESSION_VIEW_SQL = (canPhotos: boolean) => `
  SELECT s.id, s.visit_id, s.customer_id, s.status, s.product_name, s.price_minor, s.discount_minor, s.currency,
         s.original_duration_seconds, s.current_duration_seconds, s.started_at, s.scheduled_end_at, s.actual_end_at,
         s.paused_at, s.total_paused_seconds, s.pause_counts_toward_time, s.wristband, s.created_at, s.updated_at,
         c.full_name AS customer_name, c.phone_e164 AS customer_phone, v.visit_number,
         ${canPhotos ? LATEST_PHOTO_SQL : 'NULL::uuid'} AS photo_id,
         COALESCE((SELECT string_agg(e.code, ', ' ORDER BY e.code) FROM equipment_assignments ea JOIN equipment e ON e.id=ea.equipment_id WHERE ea.session_id=s.id AND ea.returned_at IS NULL),'') AS equipment,
         su.full_name AS started_by_name
    FROM sessions s JOIN customers c ON c.id = s.customer_id JOIN visits v ON v.id = s.visit_id LEFT JOIN users su ON su.id = s.started_by`;

export async function listSessions(ctx: Ctx, opts: { group: 'live' | 'waiting' | 'expiring'; limit?: number }) {
  assertCan(ctx, 'session.read');
  const statuses = opts.group === 'live' ? OCCUPANCY_STATUSES : opts.group === 'expiring' ? ['EXPIRING', 'EXPIRED'] : ['CREATED', 'PAYMENT_PENDING', 'READY', 'CHECKED_IN'];
  const rows = await many<any>(ctx.db, `${SESSION_VIEW_SQL(can(ctx, 'customer.read'))} WHERE s.venue_id=$1 AND s.status = ANY($2)
     ORDER BY s.scheduled_end_at NULLS LAST, s.created_at LIMIT $3`, [ctx.venueId, statuses, opts.limit ?? 500]);
  return { serverTime: ctx.now.toISOString(), sessions: rows.map((r) => ({ ...toCamel(r), remainingSeconds: remainingSeconds(r, ctx.now) })) };
}

export async function getSession(ctx: Ctx, id: string) {
  assertCan(ctx, 'session.read');
  const r = await one<any>(ctx.db, `${SESSION_VIEW_SQL(can(ctx, 'customer.read'))} WHERE s.id=$1 AND s.venue_id=$2`, [id, ctx.venueId]);
  if (!r) throw E.notFound('Session');
  const events = await many<any>(ctx.db,
    `SELECT e.id, e.event_type, e.from_status, e.to_status, e.occurred_at, e.metadata, u.full_name AS actor_name, d.name AS device_name
       FROM session_events e LEFT JOIN users u ON u.id=e.actor_user_id LEFT JOIN devices d ON d.id=e.device_id WHERE e.session_id=$1 ORDER BY e.id`, [id]);
  const extensions = await many<any>(ctx.db, 'SELECT id, added_seconds, original_end_at, new_end_at, price_minor, reason, created_at FROM session_extensions WHERE session_id=$1 ORDER BY created_at', [id]);
  const pauses = await many<any>(ctx.db, 'SELECT id, paused_at, resumed_at, duration_seconds, counted_toward_time, reason FROM session_pauses WHERE session_id=$1 ORDER BY paused_at', [id]);
  const equipment = await many<any>(ctx.db, `SELECT e.id, e.code, ea.assigned_at, ea.returned_at FROM equipment_assignments ea JOIN equipment e ON e.id=ea.equipment_id WHERE ea.session_id=$1 ORDER BY ea.assigned_at`, [id]);
  const { paid, pending } = await sessionNetPaid(ctx.db, id);
  // Lets a full-screen expiry alert show the customer's stored shoes without a second lookup.
  const shoeClaim = await one<any>(ctx.db, `SELECT id, claim_number, status FROM shoe_claims WHERE session_id=$1 AND status <> 'RETURNED' ORDER BY created_at DESC LIMIT 1`, [id]);
  return {
    serverTime: ctx.now.toISOString(),
    session: {
      ...toCamel(r), remainingSeconds: remainingSeconds(r, ctx.now), paidMinor: paid, pendingMinor: pending, dueMinor: r.price_minor - r.discount_minor,
      shoeClaimId: shoeClaim?.id ?? null, shoeClaimNumber: shoeClaim?.claim_number ?? null,
    },
    events: toCamelAll(events), extensions: toCamelAll(extensions), pauses: toCamelAll(pauses), equipmentAssignments: toCamelAll(equipment),
  };
}

// ---------- worker: timer transitions ----------

/**
 * Efficient periodic processing: one indexed scan for sessions whose end is near, then a short transaction per session.
 * There is no per-second job; the clock lives in scheduled_end_at.
 */
export async function processSessionTimers(venueId: string, now: Date = clock.now()) {
  const settings = await getSettings(pool, venueId);
  const horizonMin = Math.max(settings.expiringMinutes, ...settings.warnings.map((w) => w.minutes));
  const due = await many<{ id: string }>(pool,
    `SELECT id FROM sessions WHERE venue_id=$1 AND status IN ('ACTIVE','EXPIRING','PAUSED') AND scheduled_end_at <= $2 ORDER BY scheduled_end_at LIMIT 500`,
    [venueId, new Date(now.getTime() + horizonMin * 60_000)]);
  let changed = 0;
  for (const { id } of due) {
    try {
      changed += await withTx(async (db) => {
        const ctx: Ctx = { db, user: null, venueId, deviceId: null, requestId: 'worker', ip: null, now };
        const r = await db.query('SELECT * FROM sessions WHERE id=$1 FOR NO KEY UPDATE SKIP LOCKED', [id]);
        const s = r.rows[0];
        if (!s || !['ACTIVE', 'EXPIRING', 'PAUSED'].includes(s.status)) return 0;
        if (s.status === 'PAUSED' && !s.pause_counts_toward_time) return 0; // clock is frozen
        const rem = remainingSeconds(s, now)!;
        const forEnd = new Date(s.scheduled_end_at).toISOString();
        let n = 0;
        if (rem <= 0) {
          await transition(ctx, s, 'EXPIRED', 'expire', 'SESSION_EXPIRED', {}, { for_end_at: forEnd, overtimeSeconds: -rem });
          await emit(ctx, 'SESSION_EXPIRED', 'session', s.id, { sessionId: s.id, customerId: s.customer_id });
          await audit(ctx, { action: 'session.expired', entityType: 'session', entityId: s.id, after: { scheduledEndAt: forEnd } });
          return 1;
        }
        let cur = s;
        if (s.status === 'ACTIVE' && rem <= settings.expiringMinutes * 60) {
          cur = await transition(ctx, s, 'EXPIRING', 'start expiring', 'SESSION_EXPIRING', {}, { for_end_at: forEnd, remainingSeconds: rem });
          await emit(ctx, 'SESSION_EXPIRING', 'session', s.id, { sessionId: s.id, remainingSeconds: rem });
          n++;
        }
        // Only the tightest threshold currently crossed fires (a late worker does not spam older warnings).
        const crossed = settings.warnings.filter((w) => rem <= w.minutes * 60).sort((a, b) => a.minutes - b.minutes)[0];
        if (crossed) {
          const inserted = await recordSessionEvent(ctx, cur, `WARNING_${crossed.minutes}_MIN`, { meta: { for_end_at: forEnd, level: crossed.level, remainingSeconds: rem } });
          if (inserted) { await emit(ctx, 'SESSION_WARNING', 'session', s.id, { sessionId: s.id, minutes: crossed.minutes, level: crossed.level }); n++; }
        }
        return n;
      });
    } catch (e) {
      console.error('timer processing failed for session', id, (e as Error).message);
    }
  }
  // no-shows: paid-and-ready sessions that never started
  if (settings.noShowMinutes > 0) {
    const stale = await many<{ id: string }>(pool, `SELECT id FROM sessions WHERE venue_id=$1 AND status='READY' AND updated_at < $2 LIMIT 100`,
      [venueId, new Date(now.getTime() - settings.noShowMinutes * 60_000)]);
    for (const { id } of stale) {
      await withTx(async (db) => {
        const ctx: Ctx = { db, user: null, venueId, deviceId: null, requestId: 'worker', ip: null, now };
        const s = (await db.query('SELECT * FROM sessions WHERE id=$1 AND status=$2 FOR NO KEY UPDATE SKIP LOCKED', [id, 'READY'])).rows[0];
        if (!s) return;
        await transition(ctx, s, 'NO_SHOW', 'be marked no-show', 'SESSION_NO_SHOW', {}, { afterMinutes: settings.noShowMinutes });
        await db.query(`UPDATE visits SET status='CANCELLED', closed_at=$2 WHERE id=$1 AND status='OPEN' AND NOT EXISTS (SELECT 1 FROM sessions x WHERE x.visit_id=$1 AND x.status NOT IN ('CANCELLED','NO_SHOW'))`, [s.visit_id, now]);
        await emit(ctx, 'SESSION_NO_SHOW', 'session', s.id, { sessionId: s.id });
        await audit(ctx, { action: 'session.no_show', entityType: 'session', entityId: s.id });
        changed++;
      }).catch((e) => console.error('no-show processing failed', (e as Error).message));
    }
  }
  return changed;
}
