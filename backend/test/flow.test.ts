import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { pool } from '../src/db.js';
import { makeWorld, registerCustomer, acceptWaiver, productId, readySession, activeSession, makePng, clock, type World } from './helpers.js';
import { processOutbox } from '../src/worker/outbox.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 60 }); });
afterEach(() => clock.reset());

describe('acceptance: new customer flow', () => {
  it('phone -> name -> photo -> waiver -> 60 min -> payment -> start', async () => {
    clock.freeze('2026-09-30T17:00:00Z'); // 20:00 Addis time
    const c = await registerCustomer(w, 'front', { fullName: 'Hana Tesfaye', phone: '0912345678' });
    expect(c.phone).toBe('+251912345678');

    const v = await w.api('front', 'POST', '/visits', { customerId: c.id });
    expect(v.status).toBe(201);
    expect(v.body.visitNumber).toMatch(/^LS-20260930-\d{5}$/);

    const photo = await w.api('front', 'POST', `/customers/${c.id}/photos?purpose=VISIT&visitId=${v.body.id}`, makePng(200, 200));
    expect(photo.status).toBe(201);
    expect(photo.body.mimeType).toBe('image/png');

    await acceptWaiver(w, c.id, 'front', v.body.id);
    const s = await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: await productId(w, 60) });
    expect(s.status).toBe(201);
    expect(s.body.status).toBe('PAYMENT_PENDING');
    expect(s.body.priceMinor).toBe(20000);

    // cannot start before paying
    const early = await w.api('front', 'POST', `/sessions/${s.body.id}/start`, {});
    expect(early.status).toBe(409);
    expect(early.body.error.code).toBe('PAYMENT_INCOMPLETE');

    const pay = await w.api('front', 'POST', '/payments', { sessionId: s.body.id, amountMinor: 20000, method: 'CASH' });
    expect(pay.status).toBe(201);
    expect(pay.body.status).toBe('PAID');

    const start = await w.api('front', 'POST', `/sessions/${s.body.id}/start`, {});
    expect(start.status).toBe(200);
    expect(start.body.status).toBe('ACTIVE');
    expect(start.body.startedAt).toBe('2026-09-30T17:00:00.000Z');
    expect(start.body.scheduledEndAt).toBe('2026-09-30T18:00:00.000Z'); // 21:00 local
    expect(start.body.occupancy).toBe(1);

    // customer + visit + payment rows, event + audit trails, outbox entry
    expect((await pool.query('SELECT count(*)::int n FROM customers WHERE venue_id=$1 AND phone_e164=$2', [w.venueId, '+251912345678'])).rows[0].n).toBe(1);
    const evs = (await pool.query('SELECT event_type FROM session_events WHERE session_id=$1 ORDER BY id', [s.body.id])).rows.map((r) => r.event_type);
    expect(evs).toEqual(['SESSION_CREATED', 'PAYMENT_REQUESTED', 'PAYMENT_CONFIRMED', 'CHECKED_IN', 'SESSION_STARTED']);
    const audits = (await pool.query(`SELECT action FROM audit_logs WHERE venue_id=$1 AND entity_id=$2`, [w.venueId, s.body.id])).rows.map((r) => r.action);
    expect(audits).toContain('session.started');
    expect(audits).toContain('session.created');
    const ob = await pool.query(`SELECT event_type FROM outbox_events WHERE venue_id=$1 AND aggregate_id=$2`, [w.venueId, s.body.id]);
    expect(ob.rows.map((r) => r.event_type)).toContain('SESSION_STARTED');

    // dashboard reflects it immediately
    const dash = await w.api('front', 'GET', '/dashboard');
    expect(dash.body.capacity.occupancy).toBe(1);
    expect(dash.body.liveSessions.map((x: any) => x.id)).toContain(s.body.id);
    expect(dash.body.localDate).toBe('2026-09-30');
  });

  it('returning customer: one customer record, two visits', async () => {
    const c = await registerCustomer(w, 'front', { fullName: 'Dawit Tadesse', phone: '0922000111' });
    const first = await readySession(w, { customerId: c.id });
    await w.api('front', 'POST', `/sessions/${first.sessionId}/start`, {});
    await w.api('front', 'POST', `/sessions/${first.sessionId}/end`, {});

    // look up by the equivalent phone format
    const found = await w.api('front', 'GET', '/customers?q=%2B251922000111');
    expect(found.body.customers).toHaveLength(1);
    expect(found.body.customers[0].id).toBe(c.id);
    const found2 = await w.api('front', 'GET', '/customers?q=251922000111');
    expect(found2.body.customers[0].id).toBe(c.id);

    const second = await readySession(w, { customerId: c.id });
    expect(second.visitId).not.toBe(first.visitId);
    expect((await pool.query('SELECT count(*)::int n FROM customers WHERE phone_e164=$1 AND venue_id=$2', ['+251922000222'.replace('222', '111'), w.venueId])).rows[0].n).toBe(1);
    expect((await pool.query('SELECT count(*)::int n FROM visits WHERE customer_id=$1', [c.id])).rows[0].n).toBe(2);
  });

  it('warns about possible duplicates across phone formats and lets staff confirm', async () => {
    await registerCustomer(w, 'front', { fullName: 'Sara Alemu', phone: '0933444555' });
    const dup = await w.api('front', 'POST', '/customers', { fullName: 'Sara A.', phone: '+251933444555' });
    expect(dup.status).toBe(409);
    expect(dup.body.error.code).toBe('POSSIBLE_DUPLICATE');
    expect(dup.body.error.message).toBe('Possible existing customer found.');
    expect(dup.body.error.details.candidates[0].fullName).toBe('Sara Alemu');
    const ok = await w.api('front', 'POST', '/customers', { fullName: 'Sara (daughter)', phone: '251933444555', confirmDistinct: true });
    expect(ok.status).toBe(201);
  });

  it('rejects malformed phone numbers', async () => {
    const r = await w.api('front', 'POST', '/customers', { fullName: 'Bad Phone', phone: '12345' });
    expect(r.status).toBe(422);
    expect(r.body.error.code).toBe('INVALID_PHONE');
  });
});

describe('acceptance: timer', () => {
  it('stores timestamps; remaining time is derived, survives refresh/another device/server restart', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    clock.freeze('2026-09-30T17:30:00Z'); // 30 minutes later
    const one = await w.api('front', 'GET', `/sessions/${a.sessionId}`);
    expect(one.body.session.scheduledEndAt).toBe('2026-09-30T18:00:00.000Z');
    expect(one.body.session.remainingSeconds).toBe(1800);
    // "another device": a different user/device reads the same authoritative state
    const other = await w.api('manager', 'GET', `/sessions/${a.sessionId}`);
    expect(other.body.session.remainingSeconds).toBe(1800);
    // "server restart": a brand-new app instance on the same database sees the identical session
    const { buildApp } = await import('../src/app.js');
    const second = await buildApp({ embeddedWorker: false });
    const res = await second.app.inject({ method: 'GET', url: `/api/v1/sessions/${a.sessionId}`, headers: { authorization: `Bearer ${w.tokens.front}` } });
    expect(res.json().session.remainingSeconds).toBe(1800);
    expect(res.json().session.status).toBe('ACTIVE');
    await second.close();
    const n = (await pool.query(`SELECT count(*)::int n FROM sessions WHERE visit_id=$1`, [a.visitId])).rows[0].n;
    expect(n).toBe(1);
  });
});

describe('acceptance: capacity', () => {
  it('enforces capacity on the backend and reports VENUE FULL', async () => {
    const w2 = await makeWorld({ capacity: 2 });
    const a = await readySession(w2), b = await readySession(w2), c = await readySession(w2);
    expect((await w2.api('front', 'POST', `/sessions/${a.sessionId}/start`, {})).body.occupancy).toBe(1);
    expect((await w2.api('front', 'POST', `/sessions/${b.sessionId}/start`, {})).body.occupancy).toBe(2);
    const full = await w2.api('front', 'POST', `/sessions/${c.sessionId}/start`, {});
    expect(full.status).toBe(409);
    expect(full.body.error.code).toBe('VENUE_FULL');
    expect(full.body.error.message).toMatch(/full/i);
    // nothing half-created
    expect((await pool.query(`SELECT status FROM sessions WHERE id=$1`, [c.sessionId])).rows[0].status).toBe('READY');
    // a manager with override permission can start with a reason; front desk cannot
    const noReason = await w2.api('manager', 'POST', `/sessions/${c.sessionId}/start`, {});
    expect(noReason.status).toBe(409);
    const ovr = await w2.api('manager', 'POST', `/sessions/${c.sessionId}/start`, { overrideCapacityReason: 'Staff party guest' });
    expect(ovr.status).toBe(200);
    expect((await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE venue_id=$1 AND action='capacity.overridden'`, [w2.venueId])).rows[0].n).toBe(1);
    // ending a session frees the space
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    const dash = await w2.api('front', 'GET', '/dashboard');
    expect(dash.body.capacity.occupancy).toBe(2);
  });

  it('dashboard shows full state', async () => {
    const w3 = await makeWorld({ capacity: 1 });
    const a = await readySession(w3);
    await w3.api('front', 'POST', `/sessions/${a.sessionId}/start`, {});
    const d = await w3.api('front', 'GET', '/dashboard');
    expect(d.body.capacity).toMatchObject({ occupancy: 1, max: 1, available: 0, full: true });
  });
});
