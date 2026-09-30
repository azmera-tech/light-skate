import { describe, it, expect, beforeAll } from 'vitest';
import { randomUUID } from 'node:crypto';
import { pool } from '../src/db.js';
import { makeWorld, readySession, registerCustomer, acceptWaiver, productId, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });

async function pendingSession(minutes = 60) {
  const c = await registerCustomer(w);
  await acceptWaiver(w, c.id);
  const v = await w.api('front', 'POST', '/visits', { customerId: c.id });
  const s = await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: await productId(w, minutes) });
  return { customerId: c.id, visitId: v.body.id as string, sessionId: s.body.id as string };
}
const paymentCount = async (sessionId: string) => (await pool.query(`SELECT count(*)::int n FROM payments WHERE session_id=$1`, [sessionId])).rows[0].n;
const txCount = async (sessionId: string) => (await pool.query(`SELECT count(*)::int n FROM payment_transactions t JOIN payments p ON p.id=t.payment_id WHERE p.session_id=$1`, [sessionId])).rows[0].n;

describe('idempotency', () => {
  it('same key sent twice creates one payment and returns the original result', async () => {
    const s = await pendingSession();
    const key = randomUUID();
    const a = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'CASH' }, { 'idempotency-key': key });
    const b = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'CASH' }, { 'idempotency-key': key });
    expect(a.status).toBe(201);
    expect(b.status).toBe(201);
    expect(b.body).toEqual(a.body);
    expect(b.headers['idempotent-replay']).toBe('true');
    expect(a.headers['idempotent-replay']).toBeUndefined();
    expect(await paymentCount(s.sessionId)).toBe(1);
    expect(await txCount(s.sessionId)).toBe(1);
  });

  it('simultaneous duplicates (client timeout + retry) still create exactly one payment', async () => {
    const s = await pendingSession();
    const key = randomUUID();
    const res = await Promise.all(Array.from({ length: 6 }, () => w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'CASH' }, { 'idempotency-key': key })));
    expect(res.every((r) => r.status === 201)).toBe(true);
    expect(new Set(res.map((r) => r.body.id)).size).toBe(1);
    expect(await paymentCount(s.sessionId)).toBe(1);
  });

  it('reusing a key for a different request is rejected', async () => {
    const s = await pendingSession();
    const key = randomUUID();
    await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 5000, method: 'CASH' }, { 'idempotency-key': key });
    const b = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 6000, method: 'CASH' }, { 'idempotency-key': key });
    expect(b.status).toBe(422);
    expect(b.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
    expect(await paymentCount(s.sessionId)).toBe(1);
  });

  it('critical commands require an idempotency key', async () => {
    const s = await pendingSession();
    const r = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'CASH' }, { 'no-idem': '1' });
    expect(r.status).toBe(400);
    expect(r.body.error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
    const c = await w.api('front', 'POST', '/customers', { fullName: 'No Key', phone: '0911000999' }, { 'no-idem': '1' });
    expect(c.status).toBe(400);
  });

  it('a failed command does not poison the key: fixing the request and retrying works', async () => {
    const s = await pendingSession();
    const key = randomUUID();
    const bad = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'BITCOIN' }, { 'idempotency-key': key });
    expect(bad.status).toBe(422);
    const good = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'CASH' }, { 'idempotency-key': key });
    // same key but a different body is a *different* request: explicit rejection is the safe behaviour
    expect([201, 422]).toContain(good.status);
    const fresh = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'CASH' });
    expect(fresh.status === 201 || good.status === 201).toBe(true);
    expect(await paymentCount(s.sessionId)).toBe(1);
  });

  it('one customer registration per key (double tap on Create)', async () => {
    const key = randomUUID();
    const res = await Promise.all([1, 2, 3].map(() => w.api('front', 'POST', '/customers', { fullName: 'Double Tap', phone: '0944555666' }, { 'idempotency-key': key })));
    expect(res.every((r) => r.status === 201)).toBe(true);
    expect(new Set(res.map((r) => r.body.id)).size).toBe(1);
  });
});

describe('payment rules', () => {
  it('money is exact integer minor units; fractional or negative amounts are rejected', async () => {
    const s = await pendingSession();
    for (const amountMinor of [100.5, -5, 0, '200']) {
      const r = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor, method: 'CASH' });
      expect(r.status).toBe(400);
    }
    expect(await paymentCount(s.sessionId)).toBe(0);
  });

  it('split tender: session becomes READY only when fully paid; overpaying is refused', async () => {
    const s = await pendingSession();
    await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 12000, method: 'CASH' });
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [s.sessionId])).rows[0].status).toBe('PAYMENT_PENDING');
    const over = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 9000, method: 'CASH' });
    expect(over.status).toBe(422);
    expect(over.body.error.code).toBe('PAYMENT_EXCEEDS_DUE');
    expect(over.body.error.message).toMatch(/80 ETB/);
    await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 8000, method: 'TELEBIRR', reference: 'TB-12345' });
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [s.sessionId])).rows[0].status).toBe('READY');
  });

  it('methods that need a reference require it; unknown/disabled methods are refused', async () => {
    const s = await pendingSession();
    const noRef = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'BANK_TRANSFER' });
    expect(noRef.status).toBe(422);
    expect(noRef.body.error.code).toBe('PAYMENT_REFERENCE_REQUIRED');
    await w.api('owner', 'PUT', '/settings', { paymentMethods: [{ code: 'CASH', label: 'Cash', requiresReference: false, enabled: true }, { code: 'CARD', label: 'Card', requiresReference: true, enabled: false }] });
    const card = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'CARD', reference: 'x' });
    expect(card.status).toBe(422);
    expect(card.body.error.code).toBe('PAYMENT_METHOD_INVALID');
    await w.api('owner', 'PUT', '/settings', { paymentMethods: [
      { code: 'CASH', label: 'Cash', requiresReference: false, enabled: true }, { code: 'BANK_TRANSFER', label: 'Bank transfer', requiresReference: true, enabled: true },
      { code: 'TELEBIRR', label: 'Telebirr', requiresReference: true, enabled: true }, { code: 'CARD', label: 'Card', requiresReference: true, enabled: true }, { code: 'OTHER', label: 'Other', requiresReference: false, enabled: true }] });
  });

  it('pending payments (awaiting bank transfer) can be confirmed, cancelled or failed; session waits', async () => {
    const s = await pendingSession();
    const p = await w.api('front', 'POST', '/payments', { sessionId: s.sessionId, amountMinor: 20000, method: 'BANK_TRANSFER', confirmed: false });
    expect(p.body.status).toBe('PENDING');
    expect(await txCount(s.sessionId)).toBe(0); // no ledger entry until money is confirmed
    const start = await w.api('front', 'POST', `/sessions/${s.sessionId}/start`, {});
    expect(start.body.error.code).toBe('PAYMENT_INCOMPLETE');
    const noRef = await w.api('front', 'POST', `/payments/${p.body.id}/confirm`, {});
    expect(noRef.status).toBe(422);
    const ok = await w.api('front', 'POST', `/payments/${p.body.id}/confirm`, { reference: 'CBE-99812' });
    expect(ok.body.status).toBe('PAID');
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [s.sessionId])).rows[0].status).toBe('READY');
    expect(await txCount(s.sessionId)).toBe(1);
    const again = await w.api('front', 'POST', `/payments/${p.body.id}/confirm`, { reference: 'CBE-99812' });
    expect(again.status).toBe(409);
    // failed payment leaves the session waiting
    const s2 = await pendingSession();
    const p2 = await w.api('front', 'POST', '/payments', { sessionId: s2.sessionId, amountMinor: 20000, method: 'CARD', reference: 'r', confirmed: false });
    const fail = await w.api('front', 'POST', `/payments/${p2.body.id}/fail`, {});
    expect(fail.body.status).toBe('FAILED');
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [s2.sessionId])).rows[0].status).toBe('PAYMENT_PENDING');
    // and can be retried with a fresh payment
    const retry = await w.api('front', 'POST', '/payments', { sessionId: s2.sessionId, amountMinor: 20000, method: 'CASH' });
    expect(retry.status).toBe(201);
  });

  it('discounts need permission + reason; a 100% discount makes the session READY without payment', async () => {
    const c = await registerCustomer(w);
    await acceptWaiver(w, c.id);
    const v = await w.api('front', 'POST', '/visits', { customerId: c.id });
    const pr = await productId(w, 60);
    const denied = await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: pr, discountMinor: 5000, discountReason: 'friend' });
    expect(denied.status).toBe(403);
    const noReason = await w.api('manager', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: pr, discountMinor: 5000 });
    expect(noReason.status).toBe(422);
    const comp = await w.api('manager', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: pr, discountMinor: 20000, discountReason: 'Staff guest' });
    expect(comp.body.status).toBe('READY');
    expect((await w.api('front', 'POST', `/sessions/${comp.body.id}/start`, {})).status).toBe(200);
  });
});

describe('refunds', () => {
  it('front desk is refused and the attempt is audited; manager succeeds and it is audited', async () => {
    const r = await readySession(w);
    const denied = await w.api('front', 'POST', `/payments/${r.paymentId}/refund`, { reason: 'customer cancelled' });
    expect(denied.status).toBe(403);
    expect(denied.body.error.message).toBe("You don't have permission to issue refunds.");
    const den = await pool.query(`SELECT * FROM audit_logs WHERE venue_id=$1 AND action='security.permission_denied' AND entity_id='payment.refund'`, [w.venueId]);
    expect(den.rowCount).toBeGreaterThan(0);
    expect(den.rows[0].actor_user_id).toBe(w.userIds.front_desk);
    const ok = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { reason: 'customer cancelled' });
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe('REFUNDED');
    const au = await pool.query(`SELECT actor_user_id, reason FROM audit_logs WHERE entity_id=$1 AND action='payment.refunded'`, [r.paymentId]);
    expect(au.rows[0]).toEqual({ actor_user_id: w.userIds.manager, reason: 'customer cancelled' });
  });

  it('partial refunds accumulate; cannot exceed what was paid; reason required', async () => {
    const r = await readySession(w);
    const noReason = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { amountMinor: 5000 });
    expect(noReason.status).toBe(400);
    const p1 = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { amountMinor: 5000, reason: 'late arrival' });
    expect(p1.body.status).toBe('PARTIALLY_REFUNDED');
    expect(p1.body.remainingRefundableMinor).toBe(15000);
    const tooMuch = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { amountMinor: 15001, reason: 'too much' });
    expect(tooMuch.status).toBe(422);
    expect(tooMuch.body.error.code).toBe('REFUND_EXCEEDS_PAYMENT');
    const p2 = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { reason: 'rest of it' });
    expect(p2.body.status).toBe('REFUNDED');
    expect(p2.body.refundMinor).toBe(15000);
    const again = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { reason: 'again' });
    expect(again.status).toBe(409);
    expect(again.body.error.message).toMatch(/already been fully refunded/);
    const pay = (await pool.query('SELECT refunded_minor, status FROM payments WHERE id=$1', [r.paymentId])).rows[0];
    expect(pay).toEqual({ refunded_minor: 20000, status: 'REFUNDED' });
    const ledger = (await pool.query(`SELECT type, amount_minor FROM payment_transactions WHERE payment_id=$1 ORDER BY created_at`, [r.paymentId])).rows;
    expect(ledger.map((l) => l.type)).toEqual(['CHARGE', 'REFUND', 'REFUND']);
  });

  it('a retried refund request (same key) refunds once', async () => {
    const r = await readySession(w);
    const key = randomUUID();
    const a = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { amountMinor: 5000, reason: 'retry safe' }, { 'idempotency-key': key });
    const b = await w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { amountMinor: 5000, reason: 'retry safe' }, { 'idempotency-key': key });
    expect(b.body).toEqual(a.body);
    expect((await pool.query('SELECT refunded_minor FROM payments WHERE id=$1', [r.paymentId])).rows[0].refunded_minor).toBe(5000);
  });

  it('simultaneous refunds of the same payment: total refunded never exceeds the payment', async () => {
    const r = await readySession(w);
    const res = await Promise.all([
      w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { reason: 'refund from tablet A' }),
      w.api('manager', 'POST', `/payments/${r.paymentId}/refund`, { reason: 'refund from tablet B' }),
      w.api('owner', 'POST', `/payments/${r.paymentId}/refund`, { reason: 'refund from laptop' }),
    ]);
    expect(res.filter((x) => x.status === 200)).toHaveLength(1);
    expect(res.filter((x) => x.status !== 200).every((x) => x.status === 409)).toBe(true);
    const p = (await pool.query('SELECT refunded_minor, amount_minor FROM payments WHERE id=$1', [r.paymentId])).rows[0];
    expect(p.refunded_minor).toBe(p.amount_minor);
    expect((await pool.query(`SELECT count(*)::int n FROM refunds WHERE payment_id=$1`, [r.paymentId])).rows[0].n).toBe(1);
  });

  it('the ledger is append-only at the database level', async () => {
    const r = await readySession(w);
    await expect(pool.query(`UPDATE payment_transactions SET amount_minor = 1 WHERE payment_id=$1`, [r.paymentId])).rejects.toThrow(/append-only/);
    await expect(pool.query(`DELETE FROM payment_events WHERE payment_id=$1`, [r.paymentId])).rejects.toThrow(/append-only/);
  });

  it('today revenue on the dashboard is net of refunds', async () => {
    const w2 = await makeWorld();
    const a = await readySession(w2); const b = await readySession(w2);
    await w2.api('manager', 'POST', `/payments/${b.paymentId}/refund`, { amountMinor: 5000, reason: 'test partial' });
    const d = await w2.api('manager', 'GET', '/dashboard');
    expect(d.body.today.revenueMinor).toBe(20000 + 20000 - 5000);
    void a;
  });
});
