import { randomBytes, randomInt } from 'node:crypto';
import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit, recordSessionEvent } from '../shared/events.js';
import { getSettings, type Settings } from '../settings.js';
import { many, one, type Queryable } from '../db.js';
import { toCamel, lockOne } from './util.js';
import { sessionNetPaid } from './payments.js';
import { onSessionPaymentChanged } from './sessions.js';
import { customerNumber } from './customers.js';
import { formatMinor } from '../shared/money.js';
import { REWARD_INFO, STAMPS_PER_CARD, TIERS, nextTier, programDescription, tierRule, type RewardType } from './loyalty-config.js';

// ---------- small helpers ----------

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I: read aloud and typed by staff
function newRewardCode() {
  let s = '';
  for (let i = 0; i < 8; i++) s += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}
const newPublicToken = () => randomBytes(18).toString('base64url');

async function logEvent(ctx: Ctx, accountId: string, action: string, entityType: string, entityId: string | null, metadata: Record<string, unknown> = {}) {
  await ctx.db.query(
    `INSERT INTO loyalty_events (venue_id, account_id, actor_user_id, action, entity_type, entity_id, metadata, request_id, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
    [ctx.venueId, accountId, ctx.user?.id ?? null, action, entityType, entityId, JSON.stringify(metadata), ctx.requestId, ctx.now]);
}

async function createCard(ctx: Ctx, accountId: string, tier: string, cardNumber: number) {
  const card = (await ctx.db.query(
    `INSERT INTO loyalty_cards (venue_id, account_id, tier, card_number, started_at) VALUES ($1,$2,$3,$4,$5) RETURNING *`,
    [ctx.venueId, accountId, tier, cardNumber, ctx.now])).rows[0];
  await ctx.db.query('UPDATE loyalty_accounts SET current_card_id=$2, updated_at=$3 WHERE id=$1', [accountId, card.id, ctx.now]);
  await logEvent(ctx, accountId, 'card.started', 'loyalty_card', card.id, { tier, cardNumber });
  return card;
}

/** The customer's loyalty account, created (with Standard card #1) on first use, row-locked for this transaction. */
async function lockAccount(ctx: Ctx, customerId: string) {
  const ins = await ctx.db.query(
    `INSERT INTO loyalty_accounts (venue_id, customer_id, joined_at, created_at, updated_at) VALUES ($1,$2,$3,$3,$3)
     ON CONFLICT (customer_id) DO NOTHING RETURNING id`, [ctx.venueId, customerId, ctx.now]);
  if (ins.rowCount) {
    await logEvent(ctx, ins.rows[0].id, 'account.joined', 'loyalty_account', ins.rows[0].id, {});
    await createCard(ctx, ins.rows[0].id, 'STANDARD', 1);
  }
  const acc = await one<any>(ctx.db, 'SELECT * FROM loyalty_accounts WHERE customer_id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [customerId, ctx.venueId]);
  if (!acc) throw E.notFound('Loyalty account');
  return acc;
}

async function lockCustomer(ctx: Ctx, customerId: string) {
  const c = await one<any>(ctx.db, 'SELECT id, status, full_name, customer_no FROM customers WHERE id=$1 AND venue_id=$2', [customerId, ctx.venueId]);
  if (!c) throw E.notFound('Customer');
  if (c.status === 'ERASED') throw E.conflict('CUSTOMER_ERASED', 'This customer record has been erased.');
  return c;
}

// ---------- eligibility ----------

export type IneligibleReason =
  | 'LOYALTY_DISABLED' | 'SESSION_NOT_COMPLETED' | 'SESSION_NOT_PAID' | 'DISCOUNTED_SESSION' | 'ALREADY_STAMPED'
  | 'MAX_TIER_COMPLETED' | 'OUTSIDE_AWARD_WINDOW' | 'CUSTOMER_ERASED';

const REASON_TEXT: Record<IneligibleReason, string> = {
  LOYALTY_DISABLED: 'The loyalty program is switched off for this venue.',
  SESSION_NOT_COMPLETED: 'Only skating sessions that were started and have ended can earn a stamp.',
  SESSION_NOT_PAID: 'This session was not paid for (complimentary, free reward, or refunded), so it does not earn a stamp.',
  DISCOUNTED_SESSION: 'Sessions paid with a 50% OFF reward do not earn a stamp at this venue.',
  ALREADY_STAMPED: 'This session has already earned its loyalty stamp.',
  MAX_TIER_COMPLETED: 'This customer has completed the final Light card — the loyalty program is fully complete.',
  OUTSIDE_AWARD_WINDOW: 'This session ended too long ago to be stamped manually.',
  CUSTOMER_ERASED: 'This customer record has been erased.',
};

async function sessionEligibility(q: Queryable, s: any, settings: Settings, opts: { manual: boolean; now: Date }): Promise<IneligibleReason | null> {
  if (!settings.loyalty.enabled) return 'LOYALTY_DISABLED';
  if (!['COMPLETED', 'EARLY_EXIT'].includes(s.status) || !s.started_at) return 'SESSION_NOT_COMPLETED';
  const stamped = await one(q, 'SELECT 1 FROM loyalty_stamps WHERE session_id=$1', [s.id]);
  if (stamped) return 'ALREADY_STAMPED';
  const { paid } = await sessionNetPaid(q, s.id);
  if (paid <= 0) return 'SESSION_NOT_PAID';
  if (!settings.loyalty.stampDiscountedSessions) {
    const viaReward = await one(q, `SELECT 1 FROM loyalty_rewards WHERE redeemed_session_id=$1 AND status='REDEEMED'`, [s.id]);
    if (viaReward) return 'DISCOUNTED_SESSION';
  }
  if (opts.manual && s.actual_end_at && new Date(s.actual_end_at).getTime() < opts.now.getTime() - settings.loyalty.manualAwardWindowDays * 86400_000) {
    return 'OUTSIDE_AWARD_WINDOW';
  }
  const acc = await one<any>(q, 'SELECT is_max_tier_completed FROM loyalty_accounts WHERE customer_id=$1', [s.customer_id]);
  if (acc?.is_max_tier_completed) return 'MAX_TIER_COMPLETED';
  return null;
}

// ---------- the progression engine ----------

export interface StampResult {
  awarded: boolean;
  reason?: IneligibleReason;
  message?: string;
  stampPosition?: number;
  reward?: { id: string; type: RewardType; label: string; description: string; code: string } | null;
  cardCompleted?: boolean;
  tierAdvancedTo?: string | null;
  maxTierCompleted?: boolean;
}

/**
 * Award exactly one stamp for one eligible skating session, then apply the consequences (reward, card completion,
 * tier advancement, final-tier completion) in the same transaction. The caller must hold the session row lock.
 */
async function awardStampTx(ctx: Ctx, s: any, method: 'AUTO_SESSION_END' | 'STAFF_VERIFIED'): Promise<StampResult> {
  const settings = await getSettings(ctx.db, ctx.venueId);
  const reason = await sessionEligibility(ctx.db, s, settings, { manual: method === 'STAFF_VERIFIED', now: ctx.now });
  if (reason) return { awarded: false, reason, message: REASON_TEXT[reason] };

  const acc = await lockAccount(ctx, s.customer_id);
  if (acc.is_max_tier_completed) return { awarded: false, reason: 'MAX_TIER_COMPLETED', message: REASON_TEXT.MAX_TIER_COMPLETED };
  const tier = tierRule(acc.current_tier);
  let card = await one<any>(ctx.db, `SELECT * FROM loyalty_cards WHERE account_id=$1 AND status='ACTIVE' FOR NO KEY UPDATE`, [acc.id]);
  if (!card) {
    // Self-heal: an account always has exactly one active card until the final card is complete.
    const n = (await one<any>(ctx.db, 'SELECT COALESCE(MAX(card_number),0)::int AS n FROM loyalty_cards WHERE account_id=$1 AND tier=$2', [acc.id, tier.code])).n;
    card = await createCard(ctx, acc.id, tier.code, n + 1);
  }
  const position = card.stamps_earned + 1;
  if (position > STAMPS_PER_CARD) throw new Error('loyalty card overflow'); // impossible under the CHECK + lock; never silently continue

  const stamp = (await ctx.db.query(
    `INSERT INTO loyalty_stamps (venue_id, account_id, card_id, stamp_position, session_id, award_method, awarded_by, awarded_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,
    [ctx.venueId, acc.id, card.id, position, s.id, method, ctx.user?.id ?? null, ctx.now])).rows[0];
  await logEvent(ctx, acc.id, 'stamp.awarded', 'loyalty_stamp', stamp.id, { tier: tier.code, cardNumber: card.card_number, position, sessionId: s.id, method });

  let reward: StampResult['reward'] = null;
  const rewardType = tier.rewards[position];
  if (rewardType) {
    let row: any = null;
    for (let attempt = 0; !row && attempt < 5; attempt++) {
      const r = await ctx.db.query(
        `INSERT INTO loyalty_rewards (venue_id, account_id, card_id, stamp_id, tier, stamp_position, reward_type, code, earned_at)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT (code) DO NOTHING RETURNING *`,
        [ctx.venueId, acc.id, card.id, stamp.id, tier.code, position, rewardType, newRewardCode(), ctx.now]);
      row = r.rows[0] ?? null;
    }
    if (!row) throw new Error('could not allocate a unique reward code');
    reward = { id: row.id, type: rewardType, label: REWARD_INFO[rewardType].label, description: REWARD_INFO[rewardType].description, code: row.code };
    await logEvent(ctx, acc.id, 'reward.earned', 'loyalty_reward', row.id, { rewardType, tier: tier.code, cardNumber: card.card_number, position });
  }

  const cardCompleted = position === STAMPS_PER_CARD;
  await ctx.db.query(
    `UPDATE loyalty_cards SET stamps_earned=$2, status=$3, completed_at=$4 WHERE id=$1`,
    [card.id, position, cardCompleted ? 'COMPLETED' : 'ACTIVE', cardCompleted ? ctx.now : null]);
  await ctx.db.query('UPDATE loyalty_accounts SET total_stamps=total_stamps+1, updated_at=$2 WHERE id=$1', [acc.id, ctx.now]);

  let tierAdvancedTo: string | null = null;
  let maxTierCompleted = false;
  if (cardCompleted) {
    const done = (await one<any>(ctx.db, `SELECT COUNT(*)::int AS n FROM loyalty_cards WHERE account_id=$1 AND tier=$2 AND status='COMPLETED'`, [acc.id, tier.code])).n;
    await logEvent(ctx, acc.id, 'card.completed', 'loyalty_card', card.id, { tier: tier.code, cardNumber: card.card_number, completedInTier: done, cardsRequired: tier.cardsRequired });
    if (done >= tier.cardsRequired) {
      const nxt = nextTier(tier.code);
      if (!nxt) {
        maxTierCompleted = true;
        await ctx.db.query('UPDATE loyalty_accounts SET is_max_tier_completed=true, max_tier_completed_at=$2, updated_at=$2 WHERE id=$1', [acc.id, ctx.now]);
        await logEvent(ctx, acc.id, 'program.completed', 'loyalty_account', acc.id, { tier: tier.code });
      } else {
        tierAdvancedTo = nxt.code;
        await ctx.db.query('UPDATE loyalty_accounts SET current_tier=$2, updated_at=$3 WHERE id=$1', [acc.id, nxt.code, ctx.now]);
        await logEvent(ctx, acc.id, 'tier.advanced', 'loyalty_account', acc.id, { from: tier.code, to: nxt.code });
        await createCard(ctx, acc.id, nxt.code, 1);
      }
    } else {
      await createCard(ctx, acc.id, tier.code, card.card_number + 1);
    }
  }

  await recordSessionEvent(ctx, s, 'LOYALTY_STAMP_AWARDED', { meta: { position, tier: tier.code, rewardType: rewardType ?? null, method } });
  await emit(ctx, 'LOYALTY_UPDATED', 'customer', s.customer_id, { customerId: s.customer_id, rewardEarned: !!reward, tierAdvancedTo, maxTierCompleted });
  return { awarded: true, stampPosition: position, reward, cardCompleted, tierAdvancedTo, maxTierCompleted };
}

/** Trusted integration point: called inside endSession's transaction (session already locked). Never throws on ineligibility. */
export async function onSessionEnded(ctx: Ctx, s: any): Promise<StampResult | null> {
  const settings = await getSettings(ctx.db, ctx.venueId);
  if (!settings.loyalty.enabled || !settings.loyalty.autoStampOnSessionEnd) return null;
  return awardStampTx(ctx, s, 'AUTO_SESSION_END');
}

/** Staff-verified award for a specific past session of this customer (e.g. auto-stamping was off). */
export async function awardStampManually(ctx: Ctx, customerId: string, sessionId: string) {
  assertCan(ctx, 'loyalty.stamp');
  await lockCustomer(ctx, customerId);
  const s = await lockOne<any>(ctx.db, 'SELECT * FROM sessions WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [sessionId, ctx.venueId], 'Session');
  if (s.customer_id !== customerId) throw E.unprocessable('SESSION_CUSTOMER_MISMATCH', 'That session belongs to a different customer.');
  const r = await awardStampTx(ctx, s, 'STAFF_VERIFIED');
  if (!r.awarded) throw E.conflict(r.reason!, r.message!);
  await audit(ctx, { action: 'loyalty.stamp_awarded', entityType: 'session', entityId: s.id, after: { customerId, position: r.stampPosition, reward: r.reward?.type ?? null, tierAdvancedTo: r.tierAdvancedTo } });
  return { ...r, loyalty: await loyaltyOverview(ctx, customerId) };
}

export async function eligibleSessions(ctx: Ctx, customerId: string) {
  assertCan(ctx, 'loyalty.read');
  const settings = await getSettings(ctx.db, ctx.venueId);
  const rows = await many<any>(ctx.db,
    `SELECT s.* FROM sessions s WHERE s.customer_id=$1 AND s.venue_id=$2 AND s.status IN ('COMPLETED','EARLY_EXIT')
        AND s.actual_end_at >= $3 AND NOT EXISTS (SELECT 1 FROM loyalty_stamps ls WHERE ls.session_id=s.id)
      ORDER BY s.actual_end_at DESC LIMIT 50`,
    [customerId, ctx.venueId, new Date(ctx.now.getTime() - settings.loyalty.manualAwardWindowDays * 86400_000)]);
  const out = [];
  for (const s of rows) {
    const reason = await sessionEligibility(ctx.db, s, settings, { manual: true, now: ctx.now });
    const { paid } = await sessionNetPaid(ctx.db, s.id);
    out.push({ sessionId: s.id, productName: s.product_name, endedAt: s.actual_end_at, status: s.status, paidMinor: paid, currency: s.currency, eligible: !reason, reason, message: reason ? REASON_TEXT[reason] : null });
  }
  return { sessions: out };
}

// ---------- rewards ----------

async function lockReward(ctx: Ctx, rewardId: string) {
  return lockOne<any>(ctx.db, `SELECT r.*, a.customer_id FROM loyalty_rewards r JOIN loyalty_accounts a ON a.id=r.account_id
     WHERE r.id=$1 AND r.venue_id=$2 FOR NO KEY UPDATE OF r`, [rewardId, ctx.venueId], 'Reward');
}

function rewardBlocker(r: any): { code: string; message: string } | null {
  if (r.status === 'REDEEMED') return { code: 'REWARD_ALREADY_REDEEMED', message: `This reward was already redeemed on ${new Date(r.redeemed_at).toLocaleString('en-GB')}.` };
  if (r.status === 'VOIDED') return { code: 'REWARD_VOIDED', message: 'This reward has been voided and cannot be used.' };
  return null;
}

/** Validate before redeeming: who it belongs to, how it was earned, and whether it can still be used. */
export async function validateReward(ctx: Ctx, ref: { id?: string; code?: string }) {
  assertCan(ctx, 'loyalty.read');
  const r = await one<any>(ctx.db,
    `SELECT r.*, a.customer_id, c.full_name AS customer_name, c.customer_no, c.phone_e164, lc.card_number, u.full_name AS redeemed_by_name
       FROM loyalty_rewards r JOIN loyalty_accounts a ON a.id=r.account_id JOIN customers c ON c.id=a.customer_id
       JOIN loyalty_cards lc ON lc.id=r.card_id LEFT JOIN users u ON u.id=r.redeemed_by
      WHERE r.venue_id=$1 AND ${ref.id ? 'r.id=$2' : 'r.code=$2'}`, [ctx.venueId, ref.id ?? ref.code!.trim().toUpperCase()]);
  if (!r) throw E.notFound('Reward');
  const blocker = rewardBlocker(r);
  return {
    reward: serializeReward(r),
    customer: { id: r.customer_id, fullName: r.customer_name, customerCode: customerNumber(r.customer_no), phone: r.phone_e164 },
    canRedeem: !blocker && can(ctx, 'loyalty.redeem'),
    blocker,
    needsSession: r.reward_type !== 'free_burger',
  };
}

/**
 * Redeem a reward. Free session / 50% OFF are applied to a not-yet-paid skating session of the same customer
 * (as the session's discount, so the payment due drops accordingly); a free burger is a staff-confirmed handover.
 * The row lock + status check makes two simultaneous redemptions of one reward impossible.
 */
export async function redeemReward(ctx: Ctx, rewardId: string, input: { sessionId?: string | null; note?: string | null }) {
  assertCan(ctx, 'loyalty.redeem');
  const r0 = await one<any>(ctx.db, 'SELECT reward_type FROM loyalty_rewards WHERE id=$1 AND venue_id=$2', [rewardId, ctx.venueId]);
  if (!r0) throw E.notFound('Reward');
  let s: any = null;
  // Lock order everywhere: session -> loyalty account -> reward.
  if (r0.reward_type !== 'free_burger') {
    if (!input.sessionId) throw E.unprocessable('SESSION_REQUIRED', 'Choose the skating session this reward pays for.');
    s = await lockOne<any>(ctx.db, 'SELECT * FROM sessions WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [input.sessionId, ctx.venueId], 'Session');
  }
  const r = await lockReward(ctx, rewardId);
  await ctx.db.query('SELECT 1 FROM loyalty_accounts WHERE id=$1 FOR NO KEY UPDATE', [r.account_id]);
  const blocker = rewardBlocker(r);
  if (blocker) throw E.conflict(blocker.code, blocker.message);
  await lockCustomer(ctx, r.customer_id);

  let reference: string | null = null;
  if (s) {
    if (s.customer_id !== r.customer_id) throw E.unprocessable('REWARD_CUSTOMER_MISMATCH', 'This reward belongs to a different customer than the session.');
    if (!['CREATED', 'PAYMENT_PENDING'].includes(s.status)) throw E.conflict('SESSION_NOT_PAYABLE', 'Rewards can only be applied to a session that has not been paid or started yet.');
    const { paid, pending } = await sessionNetPaid(ctx.db, s.id);
    if (paid + pending > 0) throw E.conflict('SESSION_HAS_PAYMENTS', 'This session already has a payment recorded. Apply the reward before taking payment.');
    const settings = await getSettings(ctx.db, ctx.venueId);
    if (s.discount_minor > 0 && !settings.loyalty.allowRewardStacking) {
      throw E.conflict('REWARD_STACKING_NOT_ALLOWED', 'This session already has a discount. Loyalty rewards cannot be combined with other discounts.');
    }
    const value = r.reward_type === 'free_session' ? s.price_minor : Math.round(s.price_minor / 2);
    const newDiscount = Math.min(s.price_minor, s.discount_minor + value);
    const reasonText = `Loyalty reward ${REWARD_INFO[r.reward_type as RewardType].label} (${r.code})`;
    const upd = (await ctx.db.query(
      `UPDATE sessions SET discount_minor=$2, discount_reason=$3, updated_at=$4, version=version+1 WHERE id=$1 RETURNING *`,
      [s.id, newDiscount, reasonText, ctx.now])).rows[0];
    await recordSessionEvent(ctx, upd, 'LOYALTY_REWARD_APPLIED', { meta: { rewardId: r.id, rewardType: r.reward_type, code: r.code, discountMinor: value, newDueMinor: upd.price_minor - upd.discount_minor } });
    reference = s.id;
    await onSessionPaymentChanged(ctx, s.id); // nothing left to pay -> READY
  } else {
    reference = 'HANDED_OVER';
  }
  const red = (await ctx.db.query(
    `UPDATE loyalty_rewards SET status='REDEEMED', redeemed_at=$2, redeemed_by=$3, redeemed_session_id=$4, redemption_reference=$5, redemption_note=$6
      WHERE id=$1 AND status='AVAILABLE' RETURNING *`,
    [r.id, ctx.now, ctx.user?.id ?? null, s?.id ?? null, reference, input.note?.trim() || null])).rows[0];
  if (!red) throw E.conflict('REWARD_ALREADY_REDEEMED', 'This reward was redeemed by someone else just now.');
  await logEvent(ctx, r.account_id, 'reward.redeemed', 'loyalty_reward', r.id, { rewardType: r.reward_type, sessionId: s?.id ?? null, note: input.note ?? null });
  await audit(ctx, { action: 'loyalty.reward_redeemed', entityType: 'loyalty_reward', entityId: r.id, after: { rewardType: r.reward_type, code: r.code, sessionId: s?.id ?? null, customerId: r.customer_id } });
  await emit(ctx, 'LOYALTY_UPDATED', 'customer', r.customer_id, { customerId: r.customer_id });
  const session = s ? await one<any>(ctx.db, 'SELECT id, status, price_minor, discount_minor, currency FROM sessions WHERE id=$1', [s.id]) : null;
  return {
    reward: serializeReward({ ...red, customer_id: r.customer_id }),
    session: session ? { id: session.id, status: session.status, priceMinor: session.price_minor, discountMinor: session.discount_minor, dueMinor: session.price_minor - session.discount_minor,
      dueLabel: formatMinor(session.price_minor - session.discount_minor, session.currency) } : null,
  };
}

/** A skating session that a reward paid for was cancelled / no-show: the customer gets the reward back (audited). */
export async function onSessionVoided(ctx: Ctx, sessionId: string, why: string) {
  const rows = await many<any>(ctx.db, `SELECT id, account_id, code FROM loyalty_rewards WHERE redeemed_session_id=$1 AND status='REDEEMED' FOR NO KEY UPDATE`, [sessionId]);
  for (const r of rows) {
    await ctx.db.query(`UPDATE loyalty_rewards SET status='AVAILABLE', redeemed_at=NULL, redeemed_by=NULL, redeemed_session_id=NULL, redemption_reference=NULL WHERE id=$1`, [r.id]);
    await logEvent(ctx, r.account_id, 'reward.restored', 'loyalty_reward', r.id, { sessionId, reason: why });
    await audit(ctx, { action: 'loyalty.reward_restored', entityType: 'loyalty_reward', entityId: r.id, reason: why, after: { sessionId } });
  }
}

// ---------- audited corrections ----------

export async function voidReward(ctx: Ctx, rewardId: string, reason: string) {
  assertCan(ctx, 'loyalty.correct');
  const r = await lockReward(ctx, rewardId);
  if (r.status !== 'AVAILABLE') throw E.conflict('REWARD_NOT_AVAILABLE', `Only an available reward can be voided (this one is ${r.status.toLowerCase()}).`);
  await ctx.db.query(`UPDATE loyalty_rewards SET status='VOIDED', voided_at=$2, voided_by=$3, void_reason=$4 WHERE id=$1`, [r.id, ctx.now, ctx.user?.id ?? null, reason]);
  await logEvent(ctx, r.account_id, 'reward.voided', 'loyalty_reward', r.id, { reason, rewardType: r.reward_type });
  await audit(ctx, { action: 'loyalty.reward_voided', entityType: 'loyalty_reward', entityId: r.id, reason });
  await emit(ctx, 'LOYALTY_UPDATED', 'customer', r.customer_id, { customerId: r.customer_id });
  return loyaltyOverview(ctx, r.customer_id);
}

/**
 * Void the most recent stamp (e.g. the session's payment was refunded). Only the latest stamp on the active card can
 * be reversed, and only if any reward it unlocked is still unused — completed cards and tier changes are never unwound.
 */
export async function voidStamp(ctx: Ctx, stampId: string, reason: string) {
  assertCan(ctx, 'loyalty.correct');
  const st0 = await one<any>(ctx.db, 'SELECT account_id FROM loyalty_stamps WHERE id=$1 AND venue_id=$2', [stampId, ctx.venueId]);
  if (!st0) throw E.notFound('Stamp');
  const acc = await lockOne<any>(ctx.db, 'SELECT * FROM loyalty_accounts WHERE id=$1 FOR NO KEY UPDATE', [st0.account_id], 'Loyalty account');
  const st = await lockOne<any>(ctx.db, 'SELECT * FROM loyalty_stamps WHERE id=$1 FOR NO KEY UPDATE', [stampId], 'Stamp');
  if (st.status !== 'ACTIVE') throw E.conflict('STAMP_ALREADY_VOIDED', 'This stamp has already been voided.');
  const card = await lockOne<any>(ctx.db, 'SELECT * FROM loyalty_cards WHERE id=$1 FOR NO KEY UPDATE', [st.card_id], 'Card');
  if (card.status !== 'ACTIVE' || st.stamp_position !== card.stamps_earned) {
    throw E.conflict('STAMP_NOT_REVERSIBLE', 'Only the most recent stamp on the current card can be voided. Stamps on completed cards are permanent.');
  }
  const reward = await one<any>(ctx.db, `SELECT * FROM loyalty_rewards WHERE stamp_id=$1 AND status<>'VOIDED' FOR NO KEY UPDATE`, [st.id]);
  if (reward?.status === 'REDEEMED') throw E.conflict('REWARD_ALREADY_REDEEMED', 'The reward from this stamp has already been used, so the stamp cannot be voided.');
  if (reward) {
    await ctx.db.query(`UPDATE loyalty_rewards SET status='VOIDED', voided_at=$2, voided_by=$3, void_reason=$4 WHERE id=$1`, [reward.id, ctx.now, ctx.user?.id ?? null, `Stamp voided: ${reason}`]);
    await logEvent(ctx, acc.id, 'reward.voided', 'loyalty_reward', reward.id, { reason: `Stamp voided: ${reason}` });
  }
  await ctx.db.query(`UPDATE loyalty_stamps SET status='VOIDED', voided_at=$2, voided_by=$3, void_reason=$4 WHERE id=$1`, [st.id, ctx.now, ctx.user?.id ?? null, reason]);
  await ctx.db.query('UPDATE loyalty_cards SET stamps_earned=stamps_earned-1 WHERE id=$1', [card.id]);
  await ctx.db.query('UPDATE loyalty_accounts SET total_stamps=total_stamps-1, updated_at=$2 WHERE id=$1', [acc.id, ctx.now]);
  await logEvent(ctx, acc.id, 'stamp.voided', 'loyalty_stamp', st.id, { reason, position: st.stamp_position, sessionId: st.session_id });
  await audit(ctx, { action: 'loyalty.stamp_voided', entityType: 'loyalty_stamp', entityId: st.id, reason, after: { sessionId: st.session_id, position: st.stamp_position } });
  await emit(ctx, 'LOYALTY_UPDATED', 'customer', acc.customer_id, { customerId: acc.customer_id });
  return loyaltyOverview(ctx, acc.customer_id);
}

// ---------- customer card link ----------

/** Creates (or rotates) the private link that lets the customer view their own card without an account. */
export async function issueCardLink(ctx: Ctx, customerId: string, rotate: boolean) {
  assertCan(ctx, 'loyalty.read');
  await lockCustomer(ctx, customerId);
  const acc = await lockAccount(ctx, customerId);
  let token = acc.public_token as string | null;
  if (!token || rotate) {
    token = newPublicToken();
    await ctx.db.query('UPDATE loyalty_accounts SET public_token=$2, updated_at=$3 WHERE id=$1', [acc.id, token, ctx.now]);
    await logEvent(ctx, acc.id, rotate ? 'card_link.rotated' : 'card_link.issued', 'loyalty_account', acc.id, {});
  }
  return { token, path: `/card/${token}` };
}

// ---------- read models ----------

function serializeReward(r: any) {
  const info = REWARD_INFO[r.reward_type as RewardType];
  return {
    id: r.id, type: r.reward_type, label: info.label, description: info.description, code: r.code, status: r.status,
    tier: r.tier, tierTitle: tierRule(r.tier).title, cardNumber: r.card_number ?? null, position: r.stamp_position,
    earnedAt: r.earned_at, redeemedAt: r.redeemed_at, redeemedByName: r.redeemed_by_name ?? null, redeemedSessionId: r.redeemed_session_id,
    redemptionNote: r.redemption_note, voidedAt: r.voided_at, voidReason: r.void_reason,
  };
}

function cardPositions(tier: string, stamps: any[], rewards: any[]) {
  const t = tierRule(tier);
  return Array.from({ length: STAMPS_PER_CARD }, (_, i) => {
    const pos = i + 1;
    const st = stamps.find((x) => x.stamp_position === pos && x.status === 'ACTIVE');
    const rw = rewards.find((x) => x.stamp_position === pos && x.status !== 'VOIDED');
    const type = t.rewards[pos] ?? null;
    return {
      position: pos, rewardType: type, label: type ? REWARD_INFO[type].label : null, earned: !!st, stampedAt: st?.awarded_at ?? null,
      stampId: st?.id ?? null, reward: rw ? { id: rw.id, status: rw.status, code: rw.code } : null,
    };
  });
}

/** Everything the loyalty screens show, built from stored records only. */
export async function loyaltyOverview(ctx: Ctx, customerId: string, opts: { forCustomer?: boolean } = {}) {
  if (!opts.forCustomer) assertCan(ctx, 'loyalty.read');
  const c = await one<any>(ctx.db, 'SELECT id, full_name, customer_no, status FROM customers WHERE id=$1 AND venue_id=$2', [customerId, ctx.venueId]);
  if (!c) throw E.notFound('Customer');
  const acc = await one<any>(ctx.db, 'SELECT * FROM loyalty_accounts WHERE customer_id=$1', [customerId]);
  const customer = { id: c.id, fullName: c.full_name, customerCode: customerNumber(c.customer_no) };
  if (!acc) {
    const t = TIERS[0];
    return {
      customer, account: null, tier: { code: t.code, title: t.title, theme: t.theme, cardsRequired: t.cardsRequired, final: t.final },
      currentCard: { id: null, tier: t.code, cardNumber: 1, stampsEarned: 0, status: 'ACTIVE', startedAt: null, completedAt: null, positions: cardPositions(t.code, [], []) },
      progress: progressOf(t.code, 0, 0, false), rewards: [], availableRewards: [], completedCards: [], events: [],
    };
  }
  const tier = tierRule(acc.current_tier);
  const card = await one<any>(ctx.db, 'SELECT * FROM loyalty_cards WHERE id=$1', [acc.current_card_id]);
  const stamps = await many<any>(ctx.db, 'SELECT * FROM loyalty_stamps WHERE card_id=$1', [card.id]);
  const cardRewards = await many<any>(ctx.db, 'SELECT * FROM loyalty_rewards WHERE card_id=$1', [card.id]);
  const done = (await one<any>(ctx.db, `SELECT COUNT(*)::int AS n FROM loyalty_cards WHERE account_id=$1 AND tier=$2 AND status='COMPLETED'`, [acc.id, tier.code])).n;
  const rewards = await many<any>(ctx.db,
    `SELECT r.*, lc.card_number, u.full_name AS redeemed_by_name FROM loyalty_rewards r JOIN loyalty_cards lc ON lc.id=r.card_id
       LEFT JOIN users u ON u.id=r.redeemed_by WHERE r.account_id=$1 ORDER BY r.earned_at DESC, r.stamp_position DESC`, [acc.id]);
  const completed = await many<any>(ctx.db,
    `SELECT lc.id, lc.tier, lc.card_number, lc.started_at, lc.completed_at,
            (SELECT COUNT(*)::int FROM loyalty_rewards r WHERE r.card_id=lc.id AND r.status<>'VOIDED') AS rewards_earned
       FROM loyalty_cards lc WHERE lc.account_id=$1 AND lc.status='COMPLETED' ORDER BY lc.completed_at DESC`, [acc.id]);
  const serializedRewards = rewards.map((r) => {
    const x = serializeReward(r);
    // the customer view never shows staff names
    return opts.forCustomer ? { ...x, redeemedByName: null, redemptionNote: null } : x;
  });
  const events = opts.forCustomer ? [] : (await many<any>(ctx.db,
    `SELECT e.id, e.action, e.entity_type, e.metadata, e.created_at, u.full_name AS actor_name FROM loyalty_events e LEFT JOIN users u ON u.id=e.actor_user_id
      WHERE e.account_id=$1 ORDER BY e.id DESC LIMIT 100`, [acc.id])).map(toCamel);
  return {
    customer,
    account: {
      id: acc.id, joinedAt: acc.joined_at, currentTier: acc.current_tier, totalStamps: acc.total_stamps,
      isMaxTierCompleted: acc.is_max_tier_completed, maxTierCompletedAt: acc.max_tier_completed_at, hasCardLink: !!acc.public_token,
    },
    tier: { code: tier.code, title: tier.title, theme: tier.theme, cardsRequired: tier.cardsRequired, final: tier.final },
    currentCard: {
      id: card.id, tier: card.tier, cardNumber: card.card_number, stampsEarned: card.stamps_earned, status: card.status,
      startedAt: card.started_at, completedAt: card.completed_at, positions: cardPositions(card.tier, stamps, cardRewards),
    },
    progress: progressOf(tier.code, done, card.stamps_earned, acc.is_max_tier_completed),
    rewards: serializedRewards,
    availableRewards: serializedRewards.filter((r) => r.status === 'AVAILABLE'),
    completedCards: completed.map((x) => ({ id: x.id, tier: x.tier, tierTitle: tierRule(x.tier).title, cardNumber: x.card_number, startedAt: x.started_at, completedAt: x.completed_at, rewardsEarned: x.rewards_earned })),
    events,
  };
}

function progressOf(tierCode: string, completedInTier: number, stampsOnCard: number, maxCompleted: boolean) {
  const t = tierRule(tierCode);
  const nxt = nextTier(tierCode);
  const cardsRemaining = maxCompleted ? 0 : Math.max(0, t.cardsRequired - completedInTier);
  return {
    completedCardsInTier: completedInTier, cardsRequired: t.cardsRequired, cardsRemaining,
    stampsOnCard, stampsToCompleteCard: maxCompleted ? 0 : STAMPS_PER_CARD - stampsOnCard,
    stampsToNextTier: maxCompleted ? 0 : cardsRemaining * STAMPS_PER_CARD - stampsOnCard,
    nextTier: nxt ? { code: nxt.code, title: nxt.title, theme: nxt.theme, rewardsPerCard: Object.values(nxt.rewards).map((r) => REWARD_INFO[r].label) } : null,
    isFinalTier: t.final, maxTierCompleted: maxCompleted,
  };
}

/** Public, read-only card for the customer (via the private link). First name only; no staff or audit data. */
export async function publicCard(ctx: Ctx, token: string) {
  const acc = await one<any>(ctx.db, `SELECT a.customer_id, c.status FROM loyalty_accounts a JOIN customers c ON c.id=a.customer_id WHERE a.public_token=$1`, [token]);
  if (!acc || acc.status === 'ERASED') throw E.notFound('Loyalty card');
  const o = await loyaltyOverview({ ...ctx }, acc.customer_id, { forCustomer: true });
  const venue = await one<any>(ctx.db, 'SELECT name FROM venues WHERE id=$1', [ctx.venueId]);
  return {
    venueName: venue?.name ?? 'Light Skate',
    firstName: String(o.customer.fullName).split(/\s+/)[0],
    tier: o.tier, currentCard: { ...o.currentCard, positions: o.currentCard.positions.map((p) => ({ ...p, stampId: null })) },
    progress: o.progress, account: o.account ? { joinedAt: o.account.joinedAt, totalStamps: o.account.totalStamps, isMaxTierCompleted: o.account.isMaxTierCompleted } : null,
    rewards: o.rewards.map((r) => ({ ...r, code: r.status === 'AVAILABLE' ? r.code : null })),
    completedCards: o.completedCards,
    program: programDescription(),
  };
}

export async function venueForCardToken(q: Queryable, token: string) {
  return one<{ venue_id: string }>(q, 'SELECT venue_id FROM loyalty_accounts WHERE public_token=$1', [token]);
}

/** Admin: members by tier, searchable. */
export async function listMembers(ctx: Ctx, opts: { tier?: string; q?: string; limit?: number }) {
  assertCan(ctx, 'loyalty.read');
  const params: unknown[] = [ctx.venueId, opts.limit ?? 100];
  let where = '';
  if (opts.tier) { params.push(opts.tier); where += ` AND a.current_tier=$${params.length}`; }
  if (opts.q) { params.push(`%${opts.q.trim()}%`); where += ` AND (c.full_name ILIKE $${params.length} OR c.phone_e164 ILIKE $${params.length})`; }
  const rows = await many<any>(ctx.db,
    `SELECT a.customer_id, c.full_name, c.customer_no, a.current_tier, a.total_stamps, a.is_max_tier_completed, a.joined_at, lc.stamps_earned, lc.card_number,
            (SELECT COUNT(*)::int FROM loyalty_rewards r WHERE r.account_id=a.id AND r.status='AVAILABLE') AS available_rewards
       FROM loyalty_accounts a JOIN customers c ON c.id=a.customer_id LEFT JOIN loyalty_cards lc ON lc.id=a.current_card_id
      WHERE a.venue_id=$1 AND c.status<>'ERASED'${where} ORDER BY a.updated_at DESC LIMIT $2`, params);
  const tiers = await many<any>(ctx.db, `SELECT current_tier, COUNT(*)::int AS n, COUNT(*) FILTER (WHERE is_max_tier_completed)::int AS completed FROM loyalty_accounts WHERE venue_id=$1 GROUP BY current_tier`, [ctx.venueId]);
  const rewardStats = await one<any>(ctx.db,
    `SELECT COUNT(*) FILTER (WHERE status='AVAILABLE')::int AS available, COUNT(*) FILTER (WHERE status='REDEEMED')::int AS redeemed, COUNT(*) FILTER (WHERE status='VOIDED')::int AS voided
       FROM loyalty_rewards WHERE venue_id=$1`, [ctx.venueId]);
  return {
    members: rows.map((r) => ({ customerId: r.customer_id, fullName: r.full_name, customerCode: customerNumber(r.customer_no), tier: r.current_tier, tierTitle: tierRule(r.current_tier).title,
      totalStamps: r.total_stamps, stampsOnCard: r.stamps_earned, cardNumber: r.card_number, isMaxTierCompleted: r.is_max_tier_completed, joinedAt: r.joined_at, availableRewards: r.available_rewards })),
    tiers: TIERS.map((t) => ({ code: t.code, title: t.title, members: tiers.find((x) => x.current_tier === t.code)?.n ?? 0, completed: tiers.find((x) => x.current_tier === t.code)?.completed ?? 0 })),
    rewards: rewardStats,
  };
}

/** Admin: venue-wide loyalty activity (stamps, redemptions, corrections). */
export async function loyaltyActivity(ctx: Ctx, opts: { limit?: number; before?: number }) {
  assertCan(ctx, 'loyalty.read');
  const rows = await many<any>(ctx.db,
    `SELECT e.id, e.action, e.entity_type, e.entity_id, e.metadata, e.created_at, u.full_name AS actor_name, c.full_name AS customer_name, a.customer_id
       FROM loyalty_events e JOIN loyalty_accounts a ON a.id=e.account_id JOIN customers c ON c.id=a.customer_id LEFT JOIN users u ON u.id=e.actor_user_id
      WHERE e.venue_id=$1 ${opts.before ? 'AND e.id < $3' : ''} ORDER BY e.id DESC LIMIT $2`,
    opts.before ? [ctx.venueId, opts.limit ?? 100, opts.before] : [ctx.venueId, opts.limit ?? 100]);
  return { events: rows.map(toCamel) };
}

export { programDescription };
