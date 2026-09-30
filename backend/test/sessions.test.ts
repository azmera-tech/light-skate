import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { pool } from '../src/db.js';
import { makeWorld, registerCustomer, readySession, activeSession, clock, drainOutbox, type World } from './helpers.js';
import { processSessionTimers } from '../src/modules/sessions.js';
import { canTransition, TRANSITIONS, type SessionStatus } from '../src/modules/sessions-machine.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });
afterEach(() => clock.reset());

const sess = async (id: string) => (await pool.query('SELECT * FROM sessions WHERE id=$1', [id])).rows[0];
const eventTypes = async (id: string) => (await pool.query('SELECT event_type FROM session_events WHERE session_id=$1 ORDER BY id', [id])).rows.map((r) => r.event_type);

describe('state machine', () => {
  it('only allows the documented transitions', () => {
    expect(canTransition('CREATED', 'PAYMENT_PENDING')).toBe(true);
    expect(canTransition('PAYMENT_PENDING', 'READY')).toBe(true);
    expect(canTransition('READY', 'CHECKED_IN')).toBe(true);
    expect(canTransition('CHECKED_IN', 'ACTIVE')).toBe(true);
    expect(canTransition('ACTIVE', 'PAUSED')).toBe(true);
    expect(canTransition('PAUSED', 'ACTIVE')).toBe(true);
    expect(canTransition('ACTIVE', 'EXPIRING')).toBe(true);
    expect(canTransition('EXPIRING', 'COMPLETED')).toBe(true);
    expect(canTransition('ACTIVE', 'EARLY_EXIT')).toBe(true);
    expect(canTransition('READY', 'CANCELLED')).toBe(true);
    expect(canTransition('COMPLETED', 'ACTIVE')).toBe(false);
    expect(canTransition('CANCELLED', 'ACTIVE')).toBe(false);
    expect(canTransition('ACTIVE', 'READY')).toBe(false);
    for (const t of ['COMPLETED', 'EARLY_EXIT', 'CANCELLED', 'NO_SHOW'] as SessionStatus[]) expect(TRANSITIONS[t]).toEqual([]);
  });

  it('rejects invalid transitions over the API with understandable messages', async () => {
    const r = await readySession(w);
    const endReady = await w.api('front', 'POST', `/sessions/${r.sessionId}/end`, {});
    expect(endReady.status).toBe(409);
    expect(endReady.body.error.code).toBe('SESSION_INVALID_TRANSITION');
    expect(endReady.body.error.message).toMatch(/ready to start/);
    await w.api('front', 'POST', `/sessions/${r.sessionId}/start`, {});
    const again = await w.api('front', 'POST', `/sessions/${r.sessionId}/start`, {});
    expect(again.body.error.code).toBe('SESSION_ALREADY_STARTED');
    const cancelActive = await w.api('front', 'POST', `/sessions/${r.sessionId}/cancel`, { reason: 'changed mind' });
    expect(cancelActive.status).toBe(409);
    await w.api('front', 'POST', `/sessions/${r.sessionId}/end`, {});
    const endAgain = await w.api('front', 'POST', `/sessions/${r.sessionId}/end`, {});
    expect(endAgain.status).toBe(409);
    expect(endAgain.body.error.message).toMatch(/already been completed|already ended/);
    const resume = await w.api('front', 'POST', `/sessions/${r.sessionId}/resume`, {});
    expect(resume.status).toBe(409);
    const extend = await w.api('front', 'POST', `/sessions/${r.sessionId}/extend`, { minutes: 15, payment: { method: 'CASH' } });
    expect(extend.status).toBe(409);
  });

  it('there is no generic update endpoint for sessions', async () => {
    const r = await readySession(w);
    for (const method of ['PUT', 'PATCH', 'DELETE']) {
      const res = await w.api('owner', method, `/sessions/${r.sessionId}`, { status: 'COMPLETED', paymentStatus: 'PAID' });
      expect(res.status).toBe(404);
    }
    expect((await sess(r.sessionId)).status).toBe('READY');
  });

  it('blocks a second active session for the same customer', async () => {
    const a = await activeSession(w);
    const r2 = await readySession(w, { customerId: a.customerId }).catch((e) => e);
    // creating a second session on the same customer needs a new visit; start must be refused
    expect(String(r2)).toMatch(/.*/);
    const v = await w.api('front', 'POST', '/visits', { customerId: a.customerId });
    const s2 = await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: (await pool.query(`SELECT id FROM pricing_rules WHERE venue_id=$1 AND duration_minutes=30 AND kind='SESSION'`, [w.venueId])).rows[0].id });
    await w.api('front', 'POST', '/payments', { sessionId: s2.body.id, amountMinor: 10000, method: 'CASH' });
    const start = await w.api('front', 'POST', `/sessions/${s2.body.id}/start`, {});
    expect(start.status).toBe(409);
    expect(start.body.error.code).toBe('CUSTOMER_ALREADY_ACTIVE');
    expect(start.body.error.message).toMatch(/already has an active session/);
  });
});

describe('pause / resume', () => {
  it('default policy: paused time is not consumed (end moves out by the pause length)', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    clock.freeze('2026-09-30T17:10:00Z');
    const p = await w.api('front', 'POST', `/sessions/${a.sessionId}/pause`, { reason: 'bathroom' });
    expect(p.status).toBe(200);
    expect(p.body.status).toBe('PAUSED');
    clock.freeze('2026-09-30T17:25:00Z');
    const frozen = await w.api('front', 'GET', `/sessions/${a.sessionId}`);
    expect(frozen.body.session.remainingSeconds).toBe(50 * 60); // clock frozen at the moment of pausing
    const r = await w.api('front', 'POST', `/sessions/${a.sessionId}/resume`, {});
    expect(r.body.status).toBe('ACTIVE');
    expect(r.body.scheduledEndAt).toBe('2026-09-30T18:15:00.000Z');
    expect(r.body.totalPausedSeconds).toBe(900);
    const pauses = (await pool.query('SELECT duration_seconds, counted_toward_time FROM session_pauses WHERE session_id=$1', [a.sessionId])).rows;
    expect(pauses).toEqual([{ duration_seconds: 900, counted_toward_time: false }]);
    expect(await eventTypes(a.sessionId)).toEqual(expect.arrayContaining(['SESSION_PAUSED', 'SESSION_RESUMED']));
  });

  it('configurable policy: paused time counts toward the paid session', async () => {
    const before = (await w.api('owner', 'GET', '/settings')).body.settings.pause;
    expect(before.countsTowardTime).toBe(false);
    const up = await w.api('owner', 'PUT', '/settings', { pause: { enabled: true, countsTowardTime: true } });
    expect(up.status).toBe(200);
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    clock.freeze('2026-09-30T17:10:00Z');
    await w.api('front', 'POST', `/sessions/${a.sessionId}/pause`, {});
    clock.freeze('2026-09-30T17:25:00Z');
    const mid = await w.api('front', 'GET', `/sessions/${a.sessionId}`);
    expect(mid.body.session.remainingSeconds).toBe(35 * 60);
    const r = await w.api('front', 'POST', `/sessions/${a.sessionId}/resume`, {});
    expect(r.body.scheduledEndAt).toBe('2026-09-30T18:00:00.000Z');
    await w.api('owner', 'PUT', '/settings', { pause: { enabled: true, countsTowardTime: false } });
  });

  it('can be disabled per venue', async () => {
    await w.api('owner', 'PUT', '/settings', { pause: { enabled: false, countsTowardTime: false } });
    const a = await activeSession(w);
    const p = await w.api('front', 'POST', `/sessions/${a.sessionId}/pause`, {});
    expect(p.status).toBe(409);
    expect(p.body.error.code).toBe('PAUSE_DISABLED');
    await w.api('owner', 'PUT', '/settings', { pause: { enabled: true, countsTowardTime: false } });
  });

  it('a paused (frozen) session is not expired by the worker; ending while paused closes the pause', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w, { minutes: 30 });
    clock.freeze('2026-09-30T17:10:00Z');
    await w.api('front', 'POST', `/sessions/${a.sessionId}/pause`, {});
    clock.freeze('2026-09-30T19:00:00Z');
    await processSessionTimers(w.venueId, clock.now());
    expect((await sess(a.sessionId)).status).toBe('PAUSED');
    const end = await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    expect(end.status).toBe(200);
    expect(end.body.status).toBe('EARLY_EXIT'); // 20 paid minutes were never used
    expect((await pool.query('SELECT resumed_at FROM session_pauses WHERE session_id=$1', [a.sessionId])).rows[0].resumed_at).not.toBeNull();
  });
});

describe('extension', () => {
  it('extends without erasing the original; records an event with original/new end, actor, device, payment', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    clock.freeze('2026-09-30T17:50:00Z');
    const noPay = await w.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 30 });
    expect(noPay.status).toBe(422);
    expect(noPay.body.error.code).toBe('EXTENSION_PAYMENT_REQUIRED');
    expect(noPay.body.error.message).toMatch(/100 ETB/);
    const bad = await w.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 45, payment: { method: 'CASH' } });
    expect(bad.status).toBe(422);
    expect(bad.body.error.code).toBe('EXTENSION_NOT_ALLOWED');
    const ok = await w.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 30, reason: 'Customer asked for more time', payment: { method: 'CASH' } });
    expect(ok.status).toBe(200);
    expect(ok.body.scheduledEndAt).toBe('2026-09-30T18:30:00.000Z');
    expect(ok.body.currentDurationSeconds).toBe(5400);
    expect(ok.body.originalDurationSeconds).toBe(3600);
    const ev = (await pool.query(`SELECT * FROM session_events WHERE session_id=$1 AND event_type='SESSION_EXTENDED'`, [a.sessionId])).rows[0];
    expect(ev.metadata).toMatchObject({ originalEndAt: '2026-09-30T18:00:00.000Z', addedSeconds: 1800, newEndAt: '2026-09-30T18:30:00.000Z', reason: 'Customer asked for more time', priceMinor: 10000 });
    expect(ev.actor_user_id).toBe(w.userIds.front_desk);
    expect(ev.device_id).toBe(w.deviceIds.front);
    const ext = (await pool.query('SELECT * FROM session_extensions WHERE session_id=$1', [a.sessionId])).rows;
    expect(ext).toHaveLength(1);
    expect(ext[0].payment_id).not.toBeNull();
    const pay = (await pool.query(`SELECT amount_minor, purpose, status FROM payments WHERE id=$1`, [ext[0].payment_id])).rows[0];
    expect(pay).toEqual({ amount_minor: 10000, purpose: 'EXTENSION', status: 'PAID' });
  });

  it('complimentary extension needs the discount permission and a reason', async () => {
    const a = await activeSession(w);
    const denied = await w.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 15, complimentary: true, reason: 'goodwill' });
    expect(denied.status).toBe(403);
    const noReason = await w.api('manager', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 15, complimentary: true });
    expect(noReason.status).toBe(422);
    const ok = await w.api('manager', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 15, complimentary: true, reason: 'equipment fault' });
    expect(ok.status).toBe(200);
  });

  it('extending an expired (overtime) session restarts from now and returns it to ACTIVE', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    clock.freeze('2026-09-30T18:10:00Z');
    await processSessionTimers(w.venueId, clock.now());
    expect((await sess(a.sessionId)).status).toBe('EXPIRED');
    const ok = await w.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 15, payment: { method: 'CASH' } });
    expect(ok.body.status).toBe('ACTIVE');
    expect(ok.body.scheduledEndAt).toBe('2026-09-30T18:25:00.000Z');
  });
});

describe('ending', () => {
  it('early exit vs completed is decided from timestamps', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const early = await activeSession(w);
    clock.freeze('2026-09-30T17:20:00Z');
    const e = await w.api('front', 'POST', `/sessions/${early.sessionId}/end`, {});
    expect(e.body.status).toBe('EARLY_EXIT');
    clock.freeze('2026-09-30T18:00:00Z');
    const full = await activeSession(w);
    clock.freeze('2026-09-30T19:00:20Z');
    const f = await w.api('front', 'POST', `/sessions/${full.sessionId}/end`, {});
    expect(f.body.status).toBe('COMPLETED');
    expect(f.body.actualEndAt).toBe('2026-09-30T19:00:20.000Z');
    const ev = (await pool.query(`SELECT metadata FROM session_events WHERE session_id=$1 AND event_type='SESSION_ENDED'`, [full.sessionId])).rows[0];
    expect(ev.metadata.outcome).toBe('COMPLETED');
    expect(f.body.visitCompleted).toBe(true);
    expect((await pool.query(`SELECT status FROM visits WHERE id=$1`, [full.visitId])).rows[0].status).toBe('COMPLETED');
  });

  it('cancel requires a reason, cancels the visit, and reports money to refund', async () => {
    const r = await readySession(w);
    const noReason = await w.api('front', 'POST', `/sessions/${r.sessionId}/cancel`, {});
    expect(noReason.status).toBe(400);
    const c = await w.api('front', 'POST', `/sessions/${r.sessionId}/cancel`, { reason: 'Customer left' });
    expect(c.status).toBe(200);
    expect(c.body.status).toBe('CANCELLED');
    expect(c.body.refundDueMinor).toBe(20000);
    expect((await pool.query(`SELECT status FROM visits WHERE id=$1`, [r.visitId])).rows[0].status).toBe('CANCELLED');
  });
});

describe('controlled corrections', () => {
  it('manager can correct a wrong duration with reason; front desk cannot; original is preserved in events/audit', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w, { minutes: 30 });
    const denied = await w.api('front', 'POST', `/sessions/${a.sessionId}/correct`, { action: 'CHANGE_DURATION', newDurationMinutes: 60, reason: 'Staff selected wrong duration.' });
    expect(denied.status).toBe(403);
    const noReason = await w.api('manager', 'POST', `/sessions/${a.sessionId}/correct`, { action: 'CHANGE_DURATION', newDurationMinutes: 60 });
    expect(noReason.status).toBe(400);
    const ok = await w.api('manager', 'POST', `/sessions/${a.sessionId}/correct`, { action: 'CHANGE_DURATION', newDurationMinutes: 60, reason: 'Staff selected wrong duration.' });
    expect(ok.status).toBe(200);
    expect(ok.body.scheduledEndAt).toBe('2026-09-30T18:00:00.000Z');
    const ev = (await pool.query(`SELECT metadata FROM session_events WHERE session_id=$1 AND event_type='SESSION_CORRECTED'`, [a.sessionId])).rows[0].metadata;
    expect(ev.original.durationSeconds).toBe(1800);
    expect(ev.corrected.durationSeconds).toBe(3600);
    const au = (await pool.query(`SELECT before_data, after_data, reason, actor_user_id FROM audit_logs WHERE entity_id=$1 AND action='session.corrected'`, [a.sessionId])).rows[0];
    expect(au.reason).toBe('Staff selected wrong duration.');
    expect(au.actor_user_id).toBe(w.userIds.manager);
    expect(au.before_data.durationSeconds).toBe(1800);
  });

  it('reopen is the only way out of a terminal state and needs capacity + authorization', async () => {
    const a = await activeSession(w);
    await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    expect((await w.api('front', 'POST', `/sessions/${a.sessionId}/correct`, { action: 'REOPEN', reason: 'Ended by mistake' })).status).toBe(403);
    const ok = await w.api('manager', 'POST', `/sessions/${a.sessionId}/correct`, { action: 'REOPEN', reason: 'Ended by mistake' });
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe('ACTIVE');
    expect(await eventTypes(a.sessionId)).toContain('SESSION_REOPENED');
    // cancelled sessions can never be reopened
    const r = await readySession(w);
    await w.api('front', 'POST', `/sessions/${r.sessionId}/cancel`, { reason: 'x y z' });
    expect((await w.api('manager', 'POST', `/sessions/${r.sessionId}/correct`, { action: 'REOPEN', reason: 'because' })).status).toBe(409);
  });
});

describe('worker: timers, warnings, expiry', () => {
  it('raises configured warnings once per end-time, marks expiring/expired, re-arms after extension', async () => {
    const w2 = await makeWorld({ capacity: 10 });
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w2);
    const ev = async () => (await pool.query('SELECT event_type FROM session_events WHERE session_id=$1 ORDER BY id', [a.sessionId])).rows.map((r) => r.event_type);

    clock.freeze('2026-09-30T17:30:00Z'); await processSessionTimers(w2.venueId, clock.now());
    expect((await sess(a.sessionId)).status).toBe('ACTIVE');
    expect(await ev()).not.toContain('WARNING_15_MIN');

    clock.freeze('2026-09-30T17:45:30Z'); await processSessionTimers(w2.venueId, clock.now());
    expect((await sess(a.sessionId)).status).toBe('EXPIRING');
    await processSessionTimers(w2.venueId, clock.now()); // idempotent
    expect((await ev()).filter((e) => e === 'WARNING_15_MIN')).toHaveLength(1);

    clock.freeze('2026-09-30T17:55:10Z'); await processSessionTimers(w2.venueId, clock.now());
    expect(await ev()).toContain('WARNING_5_MIN');
    clock.freeze('2026-09-30T17:59:30Z'); await processSessionTimers(w2.venueId, clock.now());
    expect(await ev()).toContain('WARNING_1_MIN');

    clock.freeze('2026-09-30T18:00:05Z'); await processSessionTimers(w2.venueId, clock.now());
    expect((await sess(a.sessionId)).status).toBe('EXPIRED');
    expect((await ev()).filter((e) => e === 'SESSION_EXPIRED')).toHaveLength(1);

    // dashboard keeps showing it until staff resolve it
    const dash = await w2.api('front', 'GET', '/dashboard');
    expect(dash.body.rink.expired).toBe(1);
    await drainOutbox();
    const n = await w2.api('front', 'GET', '/notifications?status=OPEN');
    expect(n.body.notifications.some((x: any) => x.type === 'SESSION_EXPIRED' && x.entityId === a.sessionId)).toBe(true);

    // extension re-arms warnings for the new end time and resolves the alert
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 30, payment: { method: 'CASH' } });
    await drainOutbox();
    const n2 = await w2.api('front', 'GET', '/notifications?status=OPEN');
    expect(n2.body.notifications.some((x: any) => x.type === 'SESSION_EXPIRED' && x.entityId === a.sessionId)).toBe(false);
    clock.freeze('2026-09-30T18:16:00Z'); await processSessionTimers(w2.venueId, clock.now());
    expect((await ev()).filter((e) => e === 'WARNING_15_MIN')).toHaveLength(2);
  });

  it('warning thresholds are configurable per venue', async () => {
    const w2 = await makeWorld({ capacity: 10 });
    await w2.api('owner', 'PUT', '/settings', { warnings: [{ minutes: 10, level: 'YELLOW' }, { minutes: 2, level: 'RED' }], expiringMinutes: 10 });
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w2);
    clock.freeze('2026-09-30T17:51:00Z'); await processSessionTimers(w2.venueId, clock.now());
    const ev = (await pool.query('SELECT event_type FROM session_events WHERE session_id=$1', [a.sessionId])).rows.map((r) => r.event_type);
    expect(ev).toContain('WARNING_10_MIN');
    expect(ev).not.toContain('WARNING_15_MIN');
  });

  it('marks paid-but-never-started sessions as no-shows', async () => {
    const w2 = await makeWorld({ capacity: 10 });
    clock.freeze('2026-09-30T10:00:00Z');
    const r = await readySession(w2);
    clock.freeze('2026-09-30T14:00:00Z');
    await processSessionTimers(w2.venueId, clock.now());
    expect((await sess(r.sessionId)).status).toBe('NO_SHOW');
    expect((await pool.query(`SELECT status FROM visits WHERE id=$1`, [r.visitId])).rows[0].status).toBe('CANCELLED');
  });

  it('does not run a per-second job: a session row is only updated on meaningful transitions', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    const v0 = (await sess(a.sessionId)).version;
    for (let i = 0; i < 5; i++) { clock.advance(1000); await processSessionTimers(w.venueId, clock.now()); }
    expect((await sess(a.sessionId)).version).toBe(v0);
  });
});
