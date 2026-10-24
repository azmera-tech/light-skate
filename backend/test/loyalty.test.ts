import { describe, it, expect, beforeAll } from 'vitest';
import { randomUUID } from 'node:crypto';
import { pool } from '../src/db.js';
import { TIERS } from '../src/modules/loyalty-config.js';
import { makeWorld, activeSession, registerCustomer, acceptWaiver, productId, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 500 }); });

/** A genuinely paid, completed skating session written straight to the DB (fast path for long progression tests). */
async function paidEndedSession(world: World, customerId: string, opts: { amountMinor?: number; endedDaysAgo?: number } = {}) {
  const ended = new Date(Date.now() - (opts.endedDaysAgo ?? 0) * 86400_000);
  const started = new Date(ended.getTime() - 3600_000);
  const v = (await pool.query(`INSERT INTO visits (venue_id, visit_number, customer_id, local_date, status) VALUES ($1,$2,$3,'2026-10-01','COMPLETED') RETURNING id`,
    [world.venueId, 'T-' + randomUUID(), customerId])).rows[0].id;
  const amount = opts.amountMinor ?? 20000;
  const s = (await pool.query(
    `INSERT INTO sessions (venue_id, visit_id, customer_id, status, product_name, price_minor, currency, original_duration_seconds, current_duration_seconds, started_at, scheduled_end_at, actual_end_at)
     VALUES ($1,$2,$3,'COMPLETED','Standard',20000,'ETB',3600,3600,$4,$5,$5) RETURNING id`, [world.venueId, v, customerId, started, ended])).rows[0].id;
  if (amount > 0) {
    await pool.query(`INSERT INTO payments (venue_id, visit_id, session_id, customer_id, amount_minor, currency, method, status, purpose) VALUES ($1,$2,$3,$4,$5,'ETB','CASH','PAID','SESSION')`,
      [world.venueId, v, s, customerId, amount]);
  }
  return s as string;
}

async function stamp(world: World, customerId: string, who = 'front') {
  const sid = await paidEndedSession(world, customerId);
  const r = await world.api(who, 'POST', `/loyalty/customers/${customerId}/stamps`, { sessionId: sid });
  if (r.status !== 201) throw new Error('stamp failed ' + JSON.stringify(r.body));
  return r.body;
}

const overview = async (world: World, customerId: string) => (await world.api('manager', 'GET', `/loyalty/customers/${customerId}`)).body;

describe('automatic stamping from real skating sessions', () => {
  it('ending a paid session awards exactly one stamp, recorded against that session', async () => {
    const a = await activeSession(w);
    const end = await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    expect(end.status).toBe(200);
    expect(end.body.loyalty).toMatchObject({ awarded: true, stampPosition: 1 });
    const o = await overview(w, a.customerId);
    expect(o.account.totalStamps).toBe(1);
    expect(o.currentCard.positions[0]).toMatchObject({ earned: true, position: 1 });
    const rows = (await pool.query('SELECT session_id, award_method FROM loyalty_stamps WHERE account_id=$1', [o.account.id])).rows;
    expect(rows).toEqual([{ session_id: a.sessionId, award_method: 'AUTO_SESSION_END' }]);
    // re-trying the same session through the staff path is rejected
    const again = await w.api('front', 'POST', `/loyalty/customers/${a.customerId}/stamps`, { sessionId: a.sessionId });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('ALREADY_STAMPED');
  });

  it('complimentary, unpaid and refunded sessions do not earn stamps', async () => {
    const c = (await registerCustomer(w)).id;
    const free = await paidEndedSession(w, c, { amountMinor: 0 });
    const r1 = await w.api('front', 'POST', `/loyalty/customers/${c}/stamps`, { sessionId: free });
    expect(r1.status).toBe(409);
    expect(r1.body.error.code).toBe('SESSION_NOT_PAID');
    const paid = await paidEndedSession(w, c);
    await pool.query(`UPDATE payments SET refunded_minor=amount_minor, status='REFUNDED' WHERE session_id=$1`, [paid]);
    const r2 = await w.api('front', 'POST', `/loyalty/customers/${c}/stamps`, { sessionId: paid });
    expect(r2.body.error.code).toBe('SESSION_NOT_PAID');
    // a session that has not ended yet
    const live = await activeSession(w);
    const r3 = await w.api('front', 'POST', `/loyalty/customers/${live.customerId}/stamps`, { sessionId: live.sessionId });
    expect(r3.body.error.code).toBe('SESSION_NOT_COMPLETED');
  });

  it("rejects stamping another customer's session and sessions outside the manual window", async () => {
    const c1 = (await registerCustomer(w)).id;
    const c2 = (await registerCustomer(w)).id;
    const s = await paidEndedSession(w, c1);
    const r = await w.api('front', 'POST', `/loyalty/customers/${c2}/stamps`, { sessionId: s });
    expect(r.status).toBe(422);
    expect(r.body.error.code).toBe('SESSION_CUSTOMER_MISMATCH');
    const old = await paidEndedSession(w, c1, { endedDaysAgo: 45 });
    const r2 = await w.api('front', 'POST', `/loyalty/customers/${c1}/stamps`, { sessionId: old });
    expect(r2.body.error.code).toBe('OUTSIDE_AWARD_WINDOW');
  });
});

describe('tier progression engine', () => {
  it('follows the exact card/reward rules through all four tiers and stops at maximum status', async () => {
    const c = (await registerCustomer(w)).id;
    const expectCards = { STANDARD: 2, GOLDEN: 3, DIAMOND: 3, LIGHT: 1 };
    let total = 0;
    const tierSeen: string[] = [];
    for (const t of TIERS) {
      for (let card = 1; card <= expectCards[t.code]; card++) {
        const before = await overview(w, c);
        expect(before.tier.code).toBe(t.code);
        expect(before.currentCard).toMatchObject({ tier: t.code, cardNumber: card, stampsEarned: 0 });
        expect(before.progress.completedCardsInTier).toBe(card - 1);
        for (let pos = 1; pos <= 10; pos++) {
          const r = await stamp(w, c);
          total++;
          expect(r.stampPosition).toBe(pos);
          const expectedReward = t.rewards[pos] ?? null;
          expect(r.reward?.type ?? null).toBe(expectedReward);
          const lastOfTier = pos === 10 && card === expectCards[t.code];
          expect(r.cardCompleted).toBe(pos === 10);
          if (lastOfTier && !t.final) expect(r.tierAdvancedTo).toBe(TIERS[TIERS.indexOf(t) + 1].code);
          else expect(r.tierAdvancedTo ?? null).toBe(null);
          expect(r.maxTierCompleted).toBe(lastOfTier && t.final);
        }
      }
      tierSeen.push(t.code);
    }
    expect(tierSeen).toEqual(['STANDARD', 'GOLDEN', 'DIAMOND', 'LIGHT']);
    const o = await overview(w, c);
    expect(total).toBe(90);
    expect(o.account).toMatchObject({ currentTier: 'LIGHT', isMaxTierCompleted: true, totalStamps: 90 });
    expect(o.progress.maxTierCompleted).toBe(true);
    expect(o.currentCard).toMatchObject({ tier: 'LIGHT', status: 'COMPLETED', stampsEarned: 10 });
    expect(o.completedCards).toHaveLength(9);

    // every reward exists exactly once per card position, and none were lost on tier advancement
    const byTier = (await pool.query(`SELECT tier, reward_type, count(*)::int n FROM loyalty_rewards WHERE account_id=$1 GROUP BY 1,2 ORDER BY 1,2`, [o.account.id])).rows;
    expect(byTier).toEqual([
      { tier: 'DIAMOND', reward_type: 'free_session', n: 12 },
      { tier: 'GOLDEN', reward_type: 'discount_50_percent', n: 3 },
      { tier: 'GOLDEN', reward_type: 'free_session', n: 9 },
      { tier: 'LIGHT', reward_type: 'discount_50_percent', n: 1 },
      { tier: 'LIGHT', reward_type: 'free_burger', n: 1 },
      { tier: 'STANDARD', reward_type: 'discount_50_percent', n: 2 },
      { tier: 'STANDARD', reward_type: 'free_session', n: 2 },
    ]);
    expect(o.availableRewards).toHaveLength(30);

    // nothing beyond the Light card: no second Light card, no more stamps
    const s = await paidEndedSession(w, c);
    const extra = await w.api('front', 'POST', `/loyalty/customers/${c}/stamps`, { sessionId: s });
    expect(extra.status).toBe(409);
    expect(extra.body.error.code).toBe('MAX_TIER_COMPLETED');
    const lightCards = (await pool.query(`SELECT count(*)::int n FROM loyalty_cards WHERE account_id=$1 AND tier='LIGHT'`, [o.account.id])).rows[0].n;
    expect(lightCards).toBe(1);
  }, 120_000);

  it('the database refuses a second Light card even if application checks were bypassed', async () => {
    const c = (await registerCustomer(w)).id;
    await stamp(w, c);
    const acc = (await pool.query('SELECT id FROM loyalty_accounts WHERE customer_id=$1', [c])).rows[0].id;
    await expect(pool.query(`INSERT INTO loyalty_cards (venue_id, account_id, tier, card_number, status, stamps_earned) VALUES ($1,$2,'LIGHT',2,'COMPLETED',10)`, [w.venueId, acc])).rejects.toThrow();
    await expect(pool.query(`INSERT INTO loyalty_cards (venue_id, account_id, tier, card_number) VALUES ($1,$2,'STANDARD',9)`, [w.venueId, acc])).rejects.toThrow(); // second active card
  });

  it('concurrent stamp requests serialize: one stamp per session, positions never collide or exceed the card', async () => {
    const c = (await registerCustomer(w)).id;
    const same = await paidEndedSession(w, c);
    const dup = await Promise.all([1, 2, 3, 4].map(() => w.api('front', 'POST', `/loyalty/customers/${c}/stamps`, { sessionId: same })));
    expect(dup.filter((r) => r.status === 201)).toHaveLength(1);
    expect(dup.filter((r) => r.status === 409).every((r) => r.body.error.code === 'ALREADY_STAMPED')).toBe(true);
    const sessions = [];
    for (let i = 0; i < 12; i++) sessions.push(await paidEndedSession(w, c));
    const res = await Promise.all(sessions.map((sid, i) => w.api(i % 2 ? 'front' : 'supervisor', 'POST', `/loyalty/customers/${c}/stamps`, { sessionId: sid })));
    expect(res.every((r) => r.status === 201)).toBe(true);
    const o = await overview(w, c);
    expect(o.account.totalStamps).toBe(13);
    expect(o.currentCard).toMatchObject({ cardNumber: 2, stampsEarned: 3 });
    const pos = (await pool.query(`SELECT card_id, stamp_position FROM loyalty_stamps WHERE account_id=$1 ORDER BY 1,2`, [o.account.id])).rows;
    expect(new Set(pos.map((p) => `${p.card_id}:${p.stamp_position}`)).size).toBe(13);
    const rewards = (await pool.query(`SELECT stamp_position FROM loyalty_rewards WHERE account_id=$1 ORDER BY earned_at, stamp_position`, [o.account.id])).rows.map((r) => r.stamp_position);
    expect(rewards.sort()).toEqual([10, 5]); // card 1: 50% OFF at 5, free session at 10; card 2 is at 3 stamps
  });
});

describe('reward redemption', () => {
  async function customerWithRewards() {
    const c = (await registerCustomer(w)).id;
    for (let i = 0; i < 10; i++) await stamp(w, c);
    const o = await overview(w, c);
    const discount = o.availableRewards.find((r: any) => r.type === 'discount_50_percent');
    const free = o.availableRewards.find((r: any) => r.type === 'free_session');
    return { c, discount, free };
  }
  async function pendingSession(customerId: string) {
    await acceptWaiver(w, customerId);
    const v = await w.api('front', 'POST', '/visits', { customerId });
    const s = await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: await productId(w, 60) });
    expect(s.body.status).toBe('PAYMENT_PENDING');
    return s.body.id as string;
  }

  it('a FREE SESSION pays for a session in full; it cannot be used twice, and that session earns no stamp', async () => {
    const { c, free } = await customerWithRewards();
    const look = await w.api('front', 'GET', `/loyalty/rewards/lookup?code=${free.code}`);
    expect(look.body).toMatchObject({ canRedeem: true, needsSession: true, customer: { id: c } });
    const sid = await pendingSession(c);
    const r = await w.api('front', 'POST', `/loyalty/rewards/${free.id}/redeem`, { sessionId: sid });
    expect(r.status).toBe(200);
    expect(r.body.session).toMatchObject({ status: 'READY', dueMinor: 0 });
    expect(r.body.reward.status).toBe('REDEEMED');
    const again = await w.api('front', 'POST', `/loyalty/rewards/${free.id}/redeem`, { sessionId: sid });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('REWARD_ALREADY_REDEEMED');
    await w.api('front', 'POST', `/sessions/${sid}/start`, {});
    const end = await w.api('front', 'POST', `/sessions/${sid}/end`, {});
    expect(end.body.loyalty).toMatchObject({ awarded: false, reason: 'SESSION_NOT_PAID' });
  });

  it('50% OFF halves the session price only; stacking with another reward on one session is refused', async () => {
    const { c, discount, free } = await customerWithRewards();
    const sid = await pendingSession(c);
    const r = await w.api('front', 'POST', `/loyalty/rewards/${discount.id}/redeem`, { sessionId: sid });
    expect(r.status).toBe(200);
    expect(r.body.session).toMatchObject({ status: 'PAYMENT_PENDING', priceMinor: 20000, dueMinor: 10000 });
    const stack = await w.api('front', 'POST', `/loyalty/rewards/${free.id}/redeem`, { sessionId: sid });
    expect(stack.status).toBe(409);
    expect(stack.body.error.code).toBe('REWARD_STACKING_NOT_ALLOWED');
    // paying the discounted amount completes the payment; the session still earns a stamp (paid, at 50%)
    expect((await w.api('front', 'POST', '/payments', { sessionId: sid, amountMinor: 10000, method: 'CASH' })).status).toBe(201);
    expect((await w.api('front', 'POST', `/sessions/${sid}/start`, {})).status).toBe(200);
    const end = await w.api('front', 'POST', `/sessions/${sid}/end`, {});
    expect(end.body.loyalty).toMatchObject({ awarded: true });
  });

  it('simultaneous redemptions of one reward succeed exactly once', async () => {
    const { c, free } = await customerWithRewards();
    const s1 = await pendingSession(c);
    const res = await Promise.all([1, 2, 3].map(() => w.api('front', 'POST', `/loyalty/rewards/${free.id}/redeem`, { sessionId: s1 })));
    expect(res.filter((r) => r.status === 200)).toHaveLength(1);
    expect(res.filter((r) => r.status === 409)).toHaveLength(2);
    const n = (await pool.query(`SELECT count(*)::int n FROM loyalty_events WHERE entity_id=$1 AND action='reward.redeemed'`, [free.id])).rows[0].n;
    expect(n).toBe(1);
  });

  it("refuses a reward on another customer's session, and on a session that already has a payment", async () => {
    const { free } = await customerWithRewards();
    const other = (await registerCustomer(w)).id;
    const sid = await pendingSession(other);
    const r = await w.api('front', 'POST', `/loyalty/rewards/${free.id}/redeem`, { sessionId: sid });
    expect(r.status).toBe(422);
    expect(r.body.error.code).toBe('REWARD_CUSTOMER_MISMATCH');
    const { c: c2, free: free2 } = await customerWithRewards();
    const sid2 = await pendingSession(c2);
    expect((await w.api('front', 'POST', '/payments', { sessionId: sid2, amountMinor: 5000, method: 'CASH' })).status).toBe(201);
    const r2 = await w.api('front', 'POST', `/loyalty/rewards/${free2.id}/redeem`, { sessionId: sid2 });
    expect(r2.status).toBe(409);
    expect(r2.body.error.code).toBe('SESSION_HAS_PAYMENTS');
    expect((await w.api('front', 'GET', `/loyalty/rewards/${free2.id}`)).body.reward.status).toBe('AVAILABLE');
  });

  it('cancelling the session a reward paid for gives the reward back (audited)', async () => {
    const { c, free } = await customerWithRewards();
    const sid = await pendingSession(c);
    await w.api('front', 'POST', `/loyalty/rewards/${free.id}/redeem`, { sessionId: sid });
    const cancel = await w.api('front', 'POST', `/sessions/${sid}/cancel`, { reason: 'customer left before skating' });
    expect(cancel.status).toBe(200);
    const v = await w.api('front', 'GET', `/loyalty/rewards/${free.id}`);
    expect(v.body.reward.status).toBe('AVAILABLE');
    const ev = (await pool.query(`SELECT action FROM loyalty_events WHERE entity_id=$1 ORDER BY id`, [free.id])).rows.map((r) => r.action);
    expect(ev).toEqual(['reward.earned', 'reward.redeemed', 'reward.restored']);
  });

  it('a FREE BURGER is a staff-confirmed handover without a session', async () => {
    const c = (await registerCustomer(w)).id;
    const acc = (await pool.query(`INSERT INTO loyalty_accounts (venue_id, customer_id, current_tier) VALUES ($1,$2,'LIGHT') RETURNING id`, [w.venueId, c])).rows[0].id;
    const card = (await pool.query(`INSERT INTO loyalty_cards (venue_id, account_id, tier, card_number) VALUES ($1,$2,'LIGHT',1) RETURNING id`, [w.venueId, acc])).rows[0].id;
    await pool.query('UPDATE loyalty_accounts SET current_card_id=$2 WHERE id=$1', [acc, card]);
    await pool.query('UPDATE loyalty_cards SET stamps_earned=9 WHERE id=$1', [card]);
    for (let p = 1; p <= 9; p++) {
      const sid = await paidEndedSession(w, c);
      await pool.query(`INSERT INTO loyalty_stamps (venue_id, account_id, card_id, stamp_position, session_id, award_method) VALUES ($1,$2,$3,$4,$5,'STAFF_VERIFIED')`, [w.venueId, acc, card, p, sid]);
    }
    const r = await stamp(w, c);
    expect(r).toMatchObject({ stampPosition: 10, maxTierCompleted: true, reward: { type: 'free_burger' } });
    const red = await w.api('front', 'POST', `/loyalty/rewards/${r.reward.id}/redeem`, { note: 'Classic burger' });
    expect(red.status).toBe(200);
    expect(red.body.reward).toMatchObject({ status: 'REDEEMED', redemptionNote: 'Classic burger' });
  });
});

describe('loyalty permissions and corrections', () => {
  it('roles without loyalty access cannot read, stamp, redeem or correct', async () => {
    const c = (await registerCustomer(w)).id;
    const r1 = await stamp(w, c);
    expect((await w.api('rental', 'GET', `/loyalty/customers/${c}`)).status).toBe(403);
    expect((await w.api('ps', 'GET', `/loyalty/customers/${c}`)).status).toBe(403);
    const sid = await paidEndedSession(w, c);
    expect((await w.api('rental', 'POST', `/loyalty/customers/${c}/stamps`, { sessionId: sid })).status).toBe(403);
    expect((await w.api('ps', 'POST', `/loyalty/customers/${c}/stamps`, { sessionId: sid })).status).toBe(403);
    const o = await overview(w, c);
    const stampId = o.currentCard.positions[0].stampId;
    // front desk can view and stamp, but not make corrections
    expect((await w.api('front', 'POST', `/loyalty/stamps/${stampId}/void`, { reason: 'payment refunded' })).status).toBe(403);
    void r1;
  });

  it('only the latest stamp on the active card can be voided, and the reward it unlocked goes with it', async () => {
    const c = (await registerCustomer(w)).id;
    for (let i = 0; i < 5; i++) await stamp(w, c);
    let o = await overview(w, c);
    const first = o.currentCard.positions[0].stampId;
    const fifth = o.currentCard.positions[4].stampId;
    const bad = await w.api('manager', 'POST', `/loyalty/stamps/${first}/void`, { reason: 'mistake' });
    expect(bad.status).toBe(409);
    expect(bad.body.error.code).toBe('STAMP_NOT_REVERSIBLE');
    const ok = await w.api('manager', 'POST', `/loyalty/stamps/${fifth}/void`, { reason: 'payment refunded' });
    expect(ok.status).toBe(200);
    o = await overview(w, c);
    expect(o.currentCard.stampsEarned).toBe(4);
    expect(o.availableRewards).toHaveLength(0);
    expect(o.rewards[0].status).toBe('VOIDED');
    const audit = (await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE action='loyalty.stamp_voided' AND entity_id=$1`, [fifth])).rows[0].n;
    expect(audit).toBe(1);
    // the next stamp refills position 5 and re-earns the reward
    const r = await stamp(w, c);
    expect(r).toMatchObject({ stampPosition: 5, reward: { type: 'discount_50_percent' } });
  });

  it("the customer's private card link shows their card without staff data, and stops working after erasure", async () => {
    const c = (await registerCustomer(w, 'front', { fullName: 'Selam Tesfaye' })).id;
    await stamp(w, c);
    const link = await w.api('front', 'POST', `/loyalty/customers/${c}/card-link`, {});
    expect(link.status).toBe(200);
    const pub = await w.app.inject({ method: 'GET', url: `/api/v1/public/loyalty/${link.body.token}` });
    expect(pub.statusCode).toBe(200);
    const body = pub.json();
    expect(body.firstName).toBe('Selam');
    expect(body.currentCard.stampsEarned).toBe(1);
    expect(JSON.stringify(body)).not.toContain('Tesfaye');
    expect(body.events).toBeUndefined();
    expect((await w.app.inject({ method: 'GET', url: '/api/v1/public/loyalty/not-a-real-token-123456789' })).statusCode).toBe(404);
    const rot = await w.api('front', 'POST', `/loyalty/customers/${c}/card-link`, { rotate: true });
    expect(rot.body.token).not.toBe(link.body.token);
    expect((await w.app.inject({ method: 'GET', url: `/api/v1/public/loyalty/${link.body.token}` })).statusCode).toBe(404);
    await w.api('owner', 'POST', `/customers/${c}/erase`, { reason: 'privacy request from customer' });
    expect((await w.app.inject({ method: 'GET', url: `/api/v1/public/loyalty/${rot.body.token}` })).statusCode).toBe(404);
  });
});

describe('password management', () => {
  it('staff can change their own password; other devices are signed out, this one stays in', async () => {
    const world = await makeWorld();
    const slugEmail = (await pool.query('SELECT email FROM users WHERE id=$1', [world.userIds.front])).rows[0].email;
    const second = await world.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: slugEmail, password: 'Passw0rd!Passw0rd' } });
    const otherToken = second.json().token;
    const wrong = await world.api('front', 'POST', '/auth/change-password', { currentPassword: 'nope-nope-nope', newPassword: 'BrandNewPass123' });
    expect(wrong.status).toBe(401);
    const weak = await world.api('front', 'POST', '/auth/change-password', { currentPassword: 'Passw0rd!Passw0rd', newPassword: 'short' });
    expect(weak.body.error.code).toBe('WEAK_PASSWORD');
    const ok = await world.api('front', 'POST', '/auth/change-password', { currentPassword: 'Passw0rd!Passw0rd', newPassword: 'BrandNewPass123' });
    expect(ok.status).toBe(200);
    expect((await world.api('front', 'GET', '/auth/me')).status).toBe(200);
    expect((await world.api(otherToken, 'GET', '/auth/me')).status).toBe(401);
    const relog = await world.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: slugEmail, password: 'BrandNewPass123' } });
    expect(relog.statusCode).toBe(200);
  });

  it("an owner can reset anyone's password, including their own without being signed out", async () => {
    const world = await makeWorld();
    const r = await world.api('owner', 'POST', `/staff/${world.userIds.front}/reset-password`, { password: 'ResetByOwner123' });
    expect(r.status).toBe(200);
    expect((await world.api('front', 'GET', '/auth/me')).status).toBe(401);
    const self = await world.api('owner', 'POST', `/staff/${world.userIds.owner}/reset-password`, { password: 'OwnerNewPass123' });
    expect(self.status).toBe(200);
    expect((await world.api('owner', 'GET', '/auth/me')).status).toBe(200);
    expect((await world.api('manager', 'POST', `/staff/${world.userIds.front}/reset-password`, { password: 'ManagerTry12345' })).status).toBe(403);
  });
});
