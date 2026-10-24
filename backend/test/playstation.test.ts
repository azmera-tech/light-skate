import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { pool } from '../src/db.js';
import { processGamingTimers } from '../src/modules/playstation.js';
import { makeWorld, registerCustomer, clock, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld(); });
afterEach(() => clock.reset());

let consoleSeq = 0;
async function newConsole(world: World = w, over: Record<string, unknown> = {}) {
  const r = await world.api('owner', 'POST', '/playstation/consoles', { code: `PS-${++consoleSeq}-${Math.floor(Math.random() * 1e6)}`, name: `Console ${consoleSeq}`, model: 'PS5', ...over });
  if (r.status !== 201) throw new Error('console failed ' + JSON.stringify(r.body));
  return r.body.id as string;
}
async function newPackage(world: World = w, over: Record<string, unknown> = {}) {
  const r = await world.api('owner', 'POST', '/playstation/packages', { name: '30 minutes', pricingType: 'DURATION', durationMinutes: 30, priceMinor: 10000, ...over });
  if (r.status !== 201) throw new Error('package failed ' + JSON.stringify(r.body));
  return r.body.id as string;
}
async function paidSession(opts: { consoleId?: string; packageId?: string; quantity?: number; who?: string } = {}) {
  const consoleId = opts.consoleId ?? await newConsole();
  const packageId = opts.packageId ?? await newPackage();
  const r = await w.api(opts.who ?? 'ps', 'POST', '/playstation/sessions', { consoleId, packageId, quantity: opts.quantity, walkInName: 'Walk-in player', payment: { method: 'CASH' } });
  if (r.status !== 201) throw new Error('session failed ' + JSON.stringify(r.body));
  return { consoleId, packageId, id: r.body.session.id as string, body: r.body };
}

describe('package management (admin only)', () => {
  it('accepts any valid duration and price, supports per-game packages, and validates input', async () => {
    const timed = await w.api('owner', 'POST', '/playstation/packages', { name: 'Odd slot', pricingType: 'DURATION', durationMinutes: 37, priceMinor: 12345 });
    expect(timed.status).toBe(201);
    expect(timed.body).toMatchObject({ durationMinutes: 37, priceMinor: 12345, gamesPerUnit: null, active: true });
    const game = await w.api('owner', 'POST', '/playstation/packages', { name: 'One game', pricingType: 'PER_GAME', gamesPerUnit: 1, gameLabel: 'FIFA match', priceMinor: 5000 });
    expect(game.body).toMatchObject({ pricingType: 'PER_GAME', gamesPerUnit: 1, durationMinutes: null, gameLabel: 'FIFA match' });
    expect((await w.api('owner', 'POST', '/playstation/packages', { name: 'Free?', pricingType: 'DURATION', durationMinutes: 30, priceMinor: 0 })).status).toBe(400);
    const noDur = await w.api('owner', 'POST', '/playstation/packages', { name: 'No duration', pricingType: 'DURATION', priceMinor: 1000 });
    expect(noDur.body.error.code).toBe('INVALID_DURATION');
    const noGames = await w.api('owner', 'POST', '/playstation/packages', { name: 'No games', pricingType: 'PER_GAME', priceMinor: 1000 });
    expect(noGames.body.error.code).toBe('INVALID_GAME_COUNT');
  });

  it('PlayStation Managers cannot create, re-price, or delete packages; other roles have no access at all', async () => {
    const pkg = await newPackage();
    expect((await w.api('ps', 'POST', '/playstation/packages', { name: 'x', pricingType: 'DURATION', durationMinutes: 10, priceMinor: 100 })).status).toBe(403);
    expect((await w.api('ps', 'PATCH', `/playstation/packages/${pkg}`, { priceMinor: 1 })).status).toBe(403);
    expect((await w.api('ps', 'DELETE', `/playstation/packages/${pkg}`)).status).toBe(403);
    expect((await w.api('ps', 'PUT', '/playstation/settings', { warningMinutes: 1, requirePaymentBeforeStart: false, pauseEnabled: true })).status).toBe(403);
    expect((await w.api('ps', 'GET', '/playstation/reports?from=2026-01-01&to=2026-01-02')).status).toBe(403);
    expect((await w.api('ps', 'GET', '/playstation/overview')).status).toBe(200);
    for (const who of ['manager', 'supervisor', 'front', 'rental']) {
      expect((await w.api(who, 'GET', '/playstation/overview')).status).toBe(403);
      expect((await w.api(who, 'GET', '/playstation/consoles')).status).toBe(403);
    }
    // ...and the PlayStation Manager has no access to the skating side or admin screens
    expect((await w.api('ps', 'GET', '/sessions')).status).toBe(403);
    expect((await w.api('ps', 'GET', '/staff')).status).toBe(403);
    expect((await w.api('ps', 'GET', '/customers')).status).toBe(403);
  });

  it('price changes never alter sessions already sold; sold packages are archived instead of deleted', async () => {
    const pkg = await newPackage(w, { priceMinor: 10000 });
    const s = await paidSession({ packageId: pkg });
    const up = await w.api('owner', 'PATCH', `/playstation/packages/${pkg}`, { priceMinor: 15000 });
    expect(up.body.priceMinor).toBe(15000);
    const detail = await w.api('ps', 'GET', `/playstation/sessions/${s.id}`);
    expect(detail.body.session.totalMinor).toBe(10000);
    expect(detail.body.items[0]).toMatchObject({ unitPriceMinor: 10000, packageName: '30 minutes' });
    const del = await w.api('owner', 'DELETE', `/playstation/packages/${pkg}`);
    expect(del.body).toMatchObject({ archived: true, deleted: false });
    expect((await w.api('ps', 'GET', `/playstation/sessions/${s.id}`)).body.items).toHaveLength(1);
    const unused = await newPackage();
    expect((await w.api('owner', 'DELETE', `/playstation/packages/${unused}`)).body).toMatchObject({ deleted: true });
    // archived/inactive packages cannot be sold
    const off = await newPackage(w, { active: false });
    const r = await w.api('ps', 'POST', '/playstation/sessions', { consoleId: await newConsole(), packageId: off, walkInName: 'A' });
    expect(r.body.error.code).toBe('PACKAGE_UNAVAILABLE');
    const r2 = await w.api('ps', 'POST', '/playstation/sessions', { consoleId: await newConsole(), packageId: pkg, walkInName: 'A' });
    expect(r2.body.error.code).toBe('PACKAGE_UNAVAILABLE');
  });
});

describe('consoles', () => {
  it('a console under maintenance or inactive cannot take a session; an in-use console cannot be taken offline', async () => {
    const pkg = await newPackage();
    const m = await newConsole(w, { status: 'MAINTENANCE' });
    const r = await w.api('ps', 'POST', '/playstation/sessions', { consoleId: m, packageId: pkg, walkInName: 'B' });
    expect(r.body.error.code).toBe('CONSOLE_UNAVAILABLE');
    const s = await paidSession({ packageId: pkg });
    const off = await w.api('owner', 'PATCH', `/playstation/consoles/${s.consoleId}`, { status: 'MAINTENANCE' });
    expect(off.status).toBe(409);
    expect(off.body.error.code).toBe('CONSOLE_IN_USE');
    const dup = await w.api('owner', 'POST', '/playstation/consoles', { code: (await pool.query('SELECT code FROM ps_consoles WHERE id=$1', [s.consoleId])).rows[0].code.toLowerCase(), name: 'Dup' });
    expect(dup.body.error.code).toBe('CONSOLE_CODE_TAKEN');
  });

  it('simultaneous session requests can never allocate one console twice', async () => {
    const consoleId = await newConsole();
    const packageId = await newPackage();
    const res = await Promise.all([1, 2, 3, 4].map((i) => w.api(i % 2 ? 'ps' : 'owner', 'POST', '/playstation/sessions', { consoleId, packageId, walkInName: `P${i}` })));
    expect(res.filter((r) => r.status === 201)).toHaveLength(1);
    expect(res.filter((r) => r.status === 409).every((r) => r.body.error.code === 'CONSOLE_IN_USE')).toBe(true);
    const open = (await pool.query(`SELECT count(*)::int n FROM ps_sessions WHERE console_id=$1 AND status <> 'CANCELLED'`, [consoleId])).rows[0].n;
    expect(open).toBe(1);
    // and the database itself refuses a second open session on the console
    await expect(pool.query(`INSERT INTO ps_sessions (venue_id, session_number, console_id, walk_in_name, pricing_type, status) VALUES ($1,'X-1',$2,'x','DURATION','READY')`, [w.venueId, consoleId])).rejects.toThrow();
  });
});

describe('timed sessions', () => {
  it('runs the full lifecycle on server time: pay, start, pause/resume, extend, finish, console released', async () => {
    clock.freeze('2026-10-24T10:00:00Z');
    const pkg30 = await newPackage(w, { name: '30 min', durationMinutes: 30, priceMinor: 10000 });
    const pkg15 = await newPackage(w, { name: '15 min', durationMinutes: 15, priceMinor: 6000 });
    const s = await paidSession({ packageId: pkg30 });
    expect(s.body.session).toMatchObject({ status: 'READY', paymentStatus: 'PAID', totalMinor: 10000 });
    const start = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/start`, {});
    expect(start.body.session.expectedEndAt).toBe('2026-10-24T10:30:00.000Z');
    expect(start.body.session.remainingSeconds).toBe(1800);

    clock.advance(10 * 60_000);
    await w.api('ps', 'POST', `/playstation/sessions/${s.id}/pause`, { reason: 'controller battery' });
    clock.advance(5 * 60_000);
    const paused = await w.api('ps', 'GET', `/playstation/sessions/${s.id}`);
    expect(paused.body.session.remainingSeconds).toBe(1200); // frozen while paused
    const resumed = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/resume`, {});
    expect(resumed.body.session.expectedEndAt).toBe('2026-10-24T10:35:00.000Z');

    const ext = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/extend`, { packageId: pkg15, payment: { method: 'CASH' } });
    expect(ext.status).toBe(200);
    expect(ext.body.session).toMatchObject({ totalMinor: 16000, paymentStatus: 'PAID', expectedEndAt: '2026-10-24T10:50:00.000Z' });
    expect(ext.body.items.map((i: any) => [i.kind, i.packageName, i.totalMinor])).toEqual([['INITIAL', '30 min', 10000], ['EXTENSION', '15 min', 6000]]);
    expect(ext.body.payments).toHaveLength(2);

    const early = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    expect(early.body.error.code).toBe('REASON_REQUIRED');
    const fin = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, { reason: 'customer had to leave' });
    expect(fin.body.session.status).toBe('COMPLETED');
    const cons = await w.api('ps', 'GET', '/playstation/consoles');
    expect(cons.body.consoles.find((c: any) => c.id === s.consoleId).state).toBe('AVAILABLE');
    const ev = fin.body.events.map((e: any) => e.eventType);
    expect(ev).toEqual(expect.arrayContaining(['SESSION_CREATED', 'PAYMENT_RECEIVED', 'PAYMENT_COMPLETE', 'SESSION_STARTED', 'SESSION_PAUSED', 'SESSION_RESUMED', 'SESSION_EXTENDED', 'SESSION_FINISHED']));
    // a time extension must use a time package
    const g = await newPackage(w, { name: 'Game', pricingType: 'PER_GAME', gamesPerUnit: 1, durationMinutes: undefined });
    const s2 = await paidSession({ packageId: pkg30 });
    const bad = await w.api('ps', 'POST', `/playstation/sessions/${s2.id}/extend`, { packageId: g, payment: { method: 'CASH' } });
    expect(bad.body.error.code).toBe('PACKAGE_TYPE_MISMATCH');
  });

  it('cannot start before payment, refuses overpayment, and keeps unverified payments pending until confirmed', async () => {
    const consoleId = await newConsole();
    const packageId = await newPackage(w, { priceMinor: 10000 });
    const c = await w.api('ps', 'POST', '/playstation/sessions', { consoleId, packageId, walkInName: 'C' });
    expect(c.body.session).toMatchObject({ status: 'PENDING_PAYMENT', paymentStatus: 'UNPAID', dueMinor: 10000 });
    const id = c.body.session.id;
    expect((await w.api('ps', 'POST', `/playstation/sessions/${id}/start`, {})).body.error.code).toBe('PAYMENT_INCOMPLETE');
    expect((await w.api('ps', 'POST', `/playstation/sessions/${id}/payments`, { amountMinor: 20000, method: 'CASH' })).body.error.code).toBe('PAYMENT_EXCEEDS_DUE');
    expect((await w.api('ps', 'POST', `/playstation/sessions/${id}/payments`, { amountMinor: 10000, method: 'TELEBIRR' })).body.error.code).toBe('PAYMENT_REFERENCE_REQUIRED');
    const pend = await w.api('ps', 'POST', `/playstation/sessions/${id}/payments`, { amountMinor: 10000, method: 'TELEBIRR', confirmed: false });
    expect(pend.body.session).toMatchObject({ status: 'PENDING_PAYMENT', paymentStatus: 'PENDING' });
    expect((await w.api('ps', 'POST', `/playstation/sessions/${id}/start`, {})).body.error.code).toBe('PAYMENT_INCOMPLETE');
    expect((await w.api('ps', 'POST', `/playstation/payments/${pend.body.payment.id}/confirm`, {})).body.error.code).toBe('PAYMENT_REFERENCE_REQUIRED');
    const conf = await w.api('ps', 'POST', `/playstation/payments/${pend.body.payment.id}/confirm`, { reference: 'TB12345' });
    expect(conf.body.session).toMatchObject({ status: 'READY', paymentStatus: 'PAID' });
    expect((await w.api('ps', 'POST', `/playstation/sessions/${id}/start`, {})).status).toBe(200);
  });

  it('warns once before the end and once when time is up', async () => {
    clock.freeze('2026-10-24T12:00:00Z');
    const s = await paidSession({ packageId: await newPackage(w, { durationMinutes: 30 }) });
    await w.api('ps', 'POST', `/playstation/sessions/${s.id}/start`, {});
    clock.advance(26 * 60_000);
    await processGamingTimers(w.venueId, clock.now());
    await processGamingTimers(w.venueId, clock.now());
    clock.advance(5 * 60_000);
    await processGamingTimers(w.venueId, clock.now());
    await processGamingTimers(w.venueId, clock.now());
    const ev = (await pool.query(`SELECT event_type FROM ps_session_events WHERE ps_session_id=$1 AND event_type IN ('TIME_WARNING','TIME_UP') ORDER BY id`, [s.id])).rows.map((r) => r.event_type);
    expect(ev).toEqual(['TIME_WARNING', 'TIME_UP']);
    const d = await w.api('ps', 'GET', `/playstation/sessions/${s.id}`);
    expect(d.body.session.status).toBe('ACTIVE'); // staff finish it; the console isn't silently released
    expect(d.body.session.remainingSeconds).toBe(-60);
  });
});

describe('per-game sessions', () => {
  it('tracks games purchased/completed without a countdown and finishes when the last game is played', async () => {
    const pkg = await newPackage(w, { name: 'One game', pricingType: 'PER_GAME', gamesPerUnit: 1, durationMinutes: undefined, priceMinor: 5000 });
    const s = await paidSession({ packageId: pkg, quantity: 3 });
    expect(s.body.session).toMatchObject({ totalMinor: 15000, gamesPurchased: 3, gamesRemaining: 3 });
    await w.api('ps', 'POST', `/playstation/sessions/${s.id}/start`, {});
    const g2 = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games-complete`, { count: 2 });
    expect(g2.body).toMatchObject({ autoFinished: false, session: { gamesCompleted: 2, gamesRemaining: 1, remainingSeconds: null, expectedEndAt: null } });
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games-complete`, { count: 2 })).body.error.code).toBe('GAMES_EXCEEDED');
    const ext = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/extend`, { packageId: pkg, quantity: 1, payment: { method: 'CASH' } });
    expect(ext.body.session).toMatchObject({ gamesPurchased: 4, totalMinor: 20000 });
    const g4 = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games-complete`, { count: 2 });
    expect(g4.body).toMatchObject({ autoFinished: true, session: { status: 'COMPLETED', gamesCompleted: 4 } });
  });
});

describe('money: refunds, cancellation and revenue', () => {
  it('revenue counts only money actually received, minus refunds; only admins can refund', async () => {
    const world = await makeWorld();
    const consoleA = (await world.api('owner', 'POST', '/playstation/consoles', { code: 'A1', name: 'A' })).body.id;
    const consoleB = (await world.api('owner', 'POST', '/playstation/consoles', { code: 'B1', name: 'B' })).body.id;
    const pkg = (await world.api('owner', 'POST', '/playstation/packages', { name: '60 min', pricingType: 'DURATION', durationMinutes: 60, priceMinor: 18000 })).body.id;
    const paid = await world.api('ps', 'POST', '/playstation/sessions', { consoleId: consoleA, packageId: pkg, walkInName: 'Paid', payment: { method: 'CASH' } });
    await world.api('ps', 'POST', '/playstation/sessions', { consoleId: consoleB, packageId: pkg, walkInName: 'Unpaid' });
    let ov = (await world.api('ps', 'GET', '/playstation/overview')).body;
    expect(ov.revenueToday).toEqual({ collectedMinor: 18000, refundedMinor: 0, netMinor: 18000 });
    expect(ov.outstanding).toEqual({ sessions: 1, minor: 18000 });
    expect(ov.consoles).toMatchObject({ total: 2, inUse: 2, available: 0 });
    const payId = paid.body.payments[0].id;
    expect((await world.api('ps', 'POST', `/playstation/payments/${payId}/refund`, { amountMinor: 5000, reason: 'controller broke' })).status).toBe(403);
    const ref = await world.api('owner', 'POST', `/playstation/payments/${payId}/refund`, { amountMinor: 5000, reason: 'controller broke' });
    expect(ref.body.session.paymentStatus).toBe('PARTIALLY_REFUNDED');
    ov = (await world.api('owner', 'GET', '/playstation/overview')).body;
    expect(ov.revenueToday).toEqual({ collectedMinor: 18000, refundedMinor: 5000, netMinor: 13000 });
    const today = ov.date;
    const rep = (await world.api('owner', 'GET', `/playstation/reports?from=${today}&to=${today}`)).body;
    expect(rep.totals).toMatchObject({ collectedMinor: 18000, refundedMinor: 5000, netMinor: 13000 });
    expect(rep.byPackage[0]).toMatchObject({ packageName: '60 min', timesSold: 2, soldMinor: 36000 });
    expect(rep.byEmployee.find((e: any) => e.userId === world.userIds.ps)).toMatchObject({ sessionsOpened: 2, collectedMinor: 18000 });
    expect((await world.api('owner', 'POST', `/playstation/payments/${payId}/refund`, { amountMinor: 50000, reason: 'too much' })).body.error.code).toBe('REFUND_EXCEEDS_PAYMENT');
  });

  it('a session can be cancelled only before it starts; history keeps it', async () => {
    const s = await paidSession();
    const c = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/cancel`, { reason: 'customer changed their mind' });
    expect(c.body).toMatchObject({ refundDueMinor: 10000, session: { status: 'CANCELLED' } });
    const s2 = await paidSession();
    await w.api('ps', 'POST', `/playstation/sessions/${s2.id}/start`, {});
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s2.id}/cancel`, { reason: 'too late now' })).body.error.code).toBe('SESSION_INVALID_TRANSITION');
    const hist = await w.api('ps', 'GET', '/playstation/sessions?status=CANCELLED');
    expect(hist.body.sessions.some((x: any) => x.id === s.id)).toBe(true);
  });

  it('operators can attach a registered customer by exact phone, without general customer access', async () => {
    const cust = await registerCustomer(w, 'front', { fullName: 'Hanna Bekele' });
    const look = await w.api('ps', 'GET', `/playstation/customer-lookup?phone=${encodeURIComponent(cust.phone)}`);
    expect(look.body.customers).toEqual([expect.objectContaining({ id: cust.id, fullName: 'Hanna Bekele' })]);
    expect(Object.keys(look.body.customers[0]).sort()).toEqual(['customerCode', 'fullName', 'id']);
    const r = await w.api('ps', 'POST', '/playstation/sessions', { consoleId: await newConsole(), packageId: await newPackage(), customerId: cust.id });
    expect(r.body.session.playerName).toBe('Hanna Bekele');
  });
});
