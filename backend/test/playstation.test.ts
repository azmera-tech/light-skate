import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { pool } from '../src/db.js';
import { processGamingTimers } from '../src/modules/playstation.js';
import { storage } from '../src/storage/index.js';
import { makeWorld, makePng, registerCustomer, clock, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld(); });
afterEach(() => clock.reset());

let seq = 0;
const GAME = 2500; // 25 ETB per game, in minor units
async function newConsole(world: World = w, over: Record<string, unknown> = {}) {
  const r = await world.api('owner', 'POST', '/playstation/consoles', { code: `PS-${++seq}-${Math.floor(Math.random() * 1e6)}`, name: `Console ${seq}`, model: 'PS5', ...over });
  if (r.status !== 201) throw new Error('console failed ' + JSON.stringify(r.body));
  return r.body.id as string;
}
async function newPackage(world: World = w, over: Record<string, unknown> = {}) {
  const r = await world.api('owner', 'POST', '/playstation/packages', { name: '30 minutes', pricingType: 'DURATION', durationMinutes: 30, priceMinor: 10000, ...over });
  if (r.status !== 201) throw new Error('package failed ' + JSON.stringify(r.body));
  return r.body.id as string;
}
const perGamePackage = (world: World = w, over: Record<string, unknown> = {}) => newPackage(world, { name: 'Per game', pricingType: 'PER_GAME', gamesPerUnit: 1, gameLabel: 'game', durationMinutes: undefined, priceMinor: GAME, ...over });
/** Opens a session: starts immediately and unpaid, no payment involved. */
async function open(opts: { consoleId?: string; packageId?: string; quantity?: number; who?: string; world?: World } = {}) {
  const world = opts.world ?? w;
  const consoleId = opts.consoleId ?? await newConsole(world);
  const packageId = opts.packageId ?? await newPackage(world);
  const r = await world.api(opts.who ?? 'ps', 'POST', '/playstation/sessions', { consoleId, packageId, quantity: opts.quantity, walkInName: 'Walk-in player' });
  if (r.status !== 201) throw new Error('session failed ' + JSON.stringify(r.body));
  return { consoleId, packageId, id: r.body.session.id as string, body: r.body };
}
const addGames = (id: string, n = 1, who = 'ps', world: World = w) => world.api(who, 'POST', `/playstation/sessions/${id}/games`, { delta: n });
const detail = async (id: string, who = 'ps', world: World = w) => (await world.api(who, 'GET', `/playstation/sessions/${id}`)).body;
const pay = (id: string, body: Record<string, unknown>, who = 'ps', world: World = w) => world.api(who, 'POST', `/playstation/sessions/${id}/payments`, body);
let imgSeq = 0;
const proofImage = () => makePng(100 + ++imgSeq, 100 + imgSeq); // each call is a different file
const payWithProof = (id: string, q: Record<string, string | number>, img: Buffer = proofImage(), who = 'ps', world: World = w) =>
  world.api(who, 'POST', `/playstation/sessions/${id}/payments/with-proof?${new URLSearchParams(Object.entries(q).map(([k, v]) => [k, String(v)]))}`, img);

describe('A. a session starts without any payment', () => {
  it('opens ACTIVE and unpaid, with the unit price snapshotted and a 0 ETB paid amount', async () => {
    const s = await open({ packageId: await perGamePackage(), quantity: 0 });
    expect(s.body.session).toMatchObject({ status: 'ACTIVE', paymentStatus: 'UNPAID', paidMinor: 0, totalMinor: 0, balanceMinor: 0, quantity: 0, gamesCount: 0, unitPriceMinor: GAME });
    expect(s.body.session.startedAt).toBeTruthy();
    expect(s.body.payments).toHaveLength(0);
    const cons = await w.api('ps', 'GET', '/playstation/consoles');
    expect(cons.body.consoles.find((c: any) => c.id === s.consoleId)).toMatchObject({ state: 'IN_USE', session: { status: 'ACTIVE', unitPriceMinor: GAME } });
  });

  it('a timed package bills its full price from the start and the countdown begins immediately', async () => {
    clock.freeze('2026-10-24T10:00:00Z');
    const s = await open({ packageId: await newPackage(w, { durationMinutes: 30, priceMinor: 10000 }) });
    expect(s.body.session).toMatchObject({ status: 'ACTIVE', totalMinor: 10000, balanceMinor: 10000, paidMinor: 0, expectedEndAt: '2026-10-24T10:30:00.000Z', remainingSeconds: 1800 });
  });

  it('a registered customer or a walk-in name is required, and inactive packages cannot be sold', async () => {
    const c = await newConsole();
    expect((await w.api('ps', 'POST', '/playstation/sessions', { consoleId: c, packageId: await newPackage() })).body.error.code).toBe('PLAYER_REQUIRED');
    const off = await newPackage(w, { active: false });
    expect((await w.api('ps', 'POST', '/playstation/sessions', { consoleId: c, packageId: off, walkInName: 'X' })).body.error.code).toBe('PACKAGE_UNAVAILABLE');
    const cust = await registerCustomer(w, 'front', { fullName: 'Hanna Bekele' });
    const r = await w.api('ps', 'POST', '/playstation/sessions', { consoleId: c, packageId: await newPackage(), customerId: cust.id });
    expect(r.body.session.playerName).toBe('Hanna Bekele');
  });
});

describe('B. live game tracking', () => {
  it('five taps of + Add Game give 5 games and 125 ETB, and the count survives a reload', async () => {
    const s = await open({ packageId: await perGamePackage() });
    for (let i = 1; i <= 5; i++) {
      const r = await addGames(s.id);
      expect(r.status).toBe(200);
      expect(r.body.session).toMatchObject({ quantity: i, gamesCount: i, totalMinor: i * GAME, paidMinor: 0, balanceMinor: i * GAME });
    }
    const d = await detail(s.id);
    expect(d.session).toMatchObject({ quantity: 5, gamesCount: 5, unitPriceMinor: GAME, totalMinor: 12500, paidMinor: 0, balanceMinor: 12500, paymentStatus: 'UNPAID' });
    const board = (await w.api('ps', 'GET', '/playstation/consoles')).body.consoles.find((c: any) => c.id === s.consoleId);
    expect(board.session).toMatchObject({ gamesCount: 5, totalMinor: 12500, balanceMinor: 12500, unitPriceMinor: GAME });
  });

  it('simultaneous taps from two devices each count exactly once', async () => {
    const s = await open({ packageId: await perGamePackage() });
    const res = await Promise.all(Array.from({ length: 12 }, (_, i) => addGames(s.id, 1, i % 2 ? 'ps' : 'owner')));
    expect(res.every((r) => r.status === 200)).toBe(true);
    expect(new Set(res.map((r) => r.body.session.quantity)).size).toBe(12); // every tap saw a distinct count
    expect((await detail(s.id)).session).toMatchObject({ quantity: 12, totalMinor: 12 * GAME });
    const events = (await pool.query(`SELECT count(*)::int n FROM ps_session_events WHERE ps_session_id=$1 AND event_type='GAMES_ADDED'`, [s.id])).rows[0].n;
    expect(events).toBe(12);
  });

  it('a repeated request with the same idempotency key does not count twice', async () => {
    const s = await open({ packageId: await perGamePackage() });
    const key = { 'idempotency-key': '11111111-1111-4111-8111-' + String(++seq).padStart(12, '0') };
    const a = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games`, { delta: 1 }, key);
    const b = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games`, { delta: 1 }, key);
    expect(a.status).toBe(200);
    expect(b.headers['idempotent-replay']).toBe('true');
    expect((await detail(s.id)).session.quantity).toBe(1);
  });

  it('removing a game is an audited correction: needs a reason, never goes below zero or below what was paid', async () => {
    const s = await open({ packageId: await perGamePackage() });
    await addGames(s.id, 3);
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games`, { delta: -1 })).body.error.code).toBe('REASON_REQUIRED');
    const ok = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games`, { delta: -1, reason: 'tapped twice by mistake' });
    expect(ok.body.session).toMatchObject({ quantity: 2, totalMinor: 2 * GAME });
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games`, { delta: -5, reason: 'too many' })).body.error.code).toBe('QUANTITY_NEGATIVE');
    expect((await pool.query(`SELECT reason FROM audit_logs WHERE action='ps.games_corrected' AND entity_id=$1`, [s.id])).rows.map((r) => r.reason)).toEqual(['tapped twice by mistake']);
    await pay(s.id, { amountMinor: 2 * GAME, method: 'CASH' });
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games`, { delta: -1, reason: 'after payment' })).body.error.code).toBe('BELOW_PAYMENTS');
    expect(((await addGames(s.id)).body.session)).toMatchObject({ quantity: 3, balanceMinor: GAME, paymentStatus: 'PARTIALLY_PAID' });
  });

  it('the price is the one snapshotted at start: later package edits do not change a running session', async () => {
    const pkg = await perGamePackage();
    const s = await open({ packageId: pkg });
    await addGames(s.id, 2);
    await w.api('owner', 'PATCH', `/playstation/packages/${pkg}`, { priceMinor: 9900 });
    const r = await addGames(s.id);
    expect(r.body.session).toMatchObject({ unitPriceMinor: GAME, totalMinor: 3 * GAME });
  });

  it('only per-game sessions take games, and a finished bill can only be corrected by an admin', async () => {
    const timed = await open();
    expect((await addGames(timed.id)).body.error.code).toBe('NOT_PER_GAME');
    const s = await open({ packageId: await perGamePackage() });
    await addGames(s.id, 2);
    await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s.id}/games`, { delta: 1 })).status).toBe(403);
    const fix = await w.api('owner', 'POST', `/playstation/sessions/${s.id}/games`, { delta: 1, reason: 'game forgotten at checkout' });
    expect(fix.body.session).toMatchObject({ quantity: 3, totalMinor: 3 * GAME });
  });
});

describe('C. ending a session and paying cash', () => {
  it('ends with the right final total, then cash settles the balance', async () => {
    const s = await open({ packageId: await perGamePackage() });
    await addGames(s.id, 5);
    const end = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    expect(end.body.session).toMatchObject({ status: 'COMPLETED', totalMinor: 12500, paidMinor: 0, balanceMinor: 12500, paymentStatus: 'UNPAID' });
    expect((await w.api('ps', 'GET', '/playstation/consoles')).body.consoles.find((c: any) => c.id === s.consoleId).state).toBe('AVAILABLE'); // released even though unpaid
    const paid = await pay(s.id, { amountMinor: 12500, method: 'CASH', tenderedMinor: 15000 });
    expect(paid.status).toBe(201);
    expect(paid.body.changeMinor).toBe(2500);
    expect(paid.body.payment).toMatchObject({ status: 'PAID', verificationRequired: false, hasProof: false });
    expect(paid.body.session).toMatchObject({ balanceMinor: 0, paidMinor: 12500, paymentStatus: 'PAID' });
  });

  it('supports partial cash payments, refuses overpayment, and never lets the balance go negative', async () => {
    const s = await open({ packageId: await perGamePackage() });
    await addGames(s.id, 4); // 100 ETB
    await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    const p1 = await pay(s.id, { amountMinor: 4000, method: 'CASH' });
    expect(p1.body.session).toMatchObject({ balanceMinor: 6000, paymentStatus: 'PARTIALLY_PAID' });
    expect((await pay(s.id, { amountMinor: 7000, method: 'CASH' })).body.error.code).toBe('PAYMENT_EXCEEDS_DUE');
    expect((await pay(s.id, { amountMinor: 5000, method: 'CASH', tenderedMinor: 4000 })).body.error.code).toBe('INVALID_TENDERED');
    const p2 = await pay(s.id, { amountMinor: 6000, method: 'CASH' });
    expect(p2.body.session).toMatchObject({ balanceMinor: 0, paymentStatus: 'PAID' });
    expect((await pay(s.id, { amountMinor: 100, method: 'CASH' })).body.error.code).toBe('NOTHING_DUE');
    expect((await detail(s.id)).payments).toHaveLength(2);
  });

  it('a session ended with no games closes with no charge', async () => {
    const s = await open({ packageId: await perGamePackage() });
    const end = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    expect(end.body.session).toMatchObject({ status: 'COMPLETED', totalMinor: 0, balanceMinor: 0, paymentStatus: 'PAID' });
  });
});

describe('D. non-cash payments with evidence', () => {
  async function endedSession(games = 5) {
    const s = await open({ packageId: await perGamePackage() });
    await addGames(s.id, games);
    await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    return s.id;
  }

  it('requires a reference and (by default for Bank transfer / Telebirr) a screenshot, and the payment waits for verification', async () => {
    const id = await endedSession();
    expect((await pay(id, { amountMinor: 12500, method: 'TELEBIRR' })).body.error.code).toBe('PAYMENT_REFERENCE_REQUIRED');
    const noProof = await pay(id, { amountMinor: 12500, method: 'TELEBIRR', reference: 'TB100200300' });
    expect(noProof.body.error.code).toBe('PROOF_REQUIRED');
    const ok = await payWithProof(id, { amountMinor: 12500, method: 'TELEBIRR', reference: 'TB100200300' });
    expect(ok.status).toBe(201);
    expect(ok.body.payment).toMatchObject({ status: 'PENDING', verificationRequired: true, hasProof: true, reference: 'TB100200300' });
    // not treated as received: the balance is untouched until someone verifies it
    expect(ok.body.session).toMatchObject({ balanceMinor: 12500, paidMinor: 0, pendingMinor: 12500, toCollectMinor: 0, paymentStatus: 'PENDING', status: 'COMPLETED' });
    expect((await pay(id, { amountMinor: 100, method: 'CASH' })).body.error.code).toBe('NOTHING_DUE'); // no double-paying while pending
    const rev = (await w.api('ps', 'GET', '/playstation/overview')).body;
    expect(rev.pendingVerification.count).toBeGreaterThan(0);
  });

  it('rejects non-image evidence and the same screenshot or transaction number used twice', async () => {
    const a = await endedSession(2), b = await endedSession(2);
    const img = proofImage();
    expect((await payWithProof(a, { amountMinor: 5000, method: 'BANK_TRANSFER', reference: 'FT-1' }, Buffer.from('not an image at all'))).status).toBeGreaterThanOrEqual(400);
    expect((await payWithProof(a, { amountMinor: 5000, method: 'BANK_TRANSFER', reference: 'FT-1' }, img)).status).toBe(201);
    expect((await payWithProof(b, { amountMinor: 5000, method: 'BANK_TRANSFER', reference: 'FT-2' }, img)).body.error.code).toBe('PROOF_ALREADY_USED');
    expect((await payWithProof(b, { amountMinor: 5000, method: 'BANK_TRANSFER', reference: 'ft-1' }, proofImage())).body.error.code).toBe('TRANSACTION_ALREADY_USED');
    // the failed attempts left nothing behind: no payment rows, no orphaned files
    expect((await pool.query(`SELECT count(*)::int n FROM ps_payments WHERE ps_session_id=$1`, [b])).rows[0].n).toBe(0);
  });

  it('Card and Other do not need a bank transaction id; proof is optional unless the admin requires it', async () => {
    const id = await endedSession(2);
    const card = await pay(id, { amountMinor: 2500, method: 'CARD', reference: 'POS-RCPT-9' });
    expect(card.status).toBe(201);
    expect(card.body.payment).toMatchObject({ status: 'PENDING', hasProof: false });
    const other = await pay(id, { amountMinor: 2500, method: 'OTHER' });
    expect(other.status).toBe(201);
    // an admin can require proof for any method
    const settings = (await w.api('owner', 'GET', '/playstation/settings')).body.settings;
    await w.api('owner', 'PUT', '/playstation/settings', { ...settings, proofRequiredMethods: ['BANK_TRANSFER', 'TELEBIRR', 'CARD'] });
    const id2 = await endedSession(1);
    expect((await pay(id2, { amountMinor: 2500, method: 'CARD', reference: 'POS-1' })).body.error.code).toBe('PROOF_REQUIRED');
    await w.api('owner', 'PUT', '/playstation/settings', settings);
  });

  it('cash never needs evidence, and evidence can be added later to a pending payment', async () => {
    const id = await endedSession(2);
    const settings = (await w.api('owner', 'GET', '/playstation/settings')).body.settings;
    await w.api('owner', 'PUT', '/playstation/settings', { ...settings, proofRequiredMethods: [] });
    const p = await pay(id, { amountMinor: 5000, method: 'BANK_TRANSFER', reference: 'FT-LATE-1' });
    expect(p.body.payment).toMatchObject({ status: 'PENDING', hasProof: false });
    const up = await w.api('ps', 'POST', `/playstation/payments/${p.body.payment.id}/proof`, proofImage());
    expect(up.status).toBe(201);
    expect((await detail(id)).payments[0].hasProof).toBe(true);
    await w.api('owner', 'PUT', '/playstation/settings', settings);
  });
});

describe('E. administrator verification', () => {
  async function pending(opts: { who?: string; games?: number } = {}) {
    const s = await open({ packageId: await perGamePackage(), who: opts.who });
    await addGames(s.id, opts.games ?? 5, opts.who ?? 'ps');
    await w.api(opts.who ?? 'ps', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    const p = await payWithProof(s.id, { amountMinor: (opts.games ?? 5) * GAME, method: 'TELEBIRR', reference: 'TB' + (++seq) + Date.now() }, proofImage(), opts.who ?? 'ps');
    return { sessionId: s.id, paymentId: p.body.payment.id as string };
  }

  it('an administrator reviews the evidence and verifies: the payment becomes received and the balance drops', async () => {
    const { sessionId, paymentId } = await pending();
    const queue = (await w.api('admin', 'GET', '/playstation/payments?status=PENDING')).body;
    const row = queue.payments.find((p: any) => p.id === paymentId);
    expect(row).toMatchObject({ status: 'PENDING', method: 'TELEBIRR', amountMinor: 12500, hasProof: true, playerName: 'Walk-in player', recordedByName: 'PLAYSTATION_MANAGER User' });
    const img = await w.api('admin', 'GET', `/playstation/payments/${paymentId}/proof`);
    expect(img.status).toBe(200);
    expect(img.headers['content-type']).toBe('image/png');
    expect(img.headers['cache-control']).toContain('no-store');
    const before = (await w.api('admin', 'GET', '/playstation/overview')).body.revenueToday.netMinor;
    const v = await w.api('admin', 'POST', `/playstation/payments/${paymentId}/verify`, {});
    expect(v.status).toBe(200);
    expect(v.body).toMatchObject({ status: 'PAID', balanceMinor: 0 });
    const d = await detail(sessionId);
    expect(d.session).toMatchObject({ balanceMinor: 0, paidMinor: 12500, pendingMinor: 0, paymentStatus: 'PAID' });
    expect(d.payments[0]).toMatchObject({ status: 'PAID', confirmedByName: 'ADMIN User' });
    expect((await w.api('admin', 'GET', '/playstation/overview')).body.revenueToday.netMinor).toBe(before + 12500); // revenue only now
    expect((await w.api('admin', 'POST', `/playstation/payments/${paymentId}/verify`, {})).body.error.code).toBe('PAYMENT_NOT_PENDING'); // no double verification
    expect((await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE action='ps.payment_verified' AND entity_id=$1`, [paymentId])).rows[0].n).toBe(1);
  });

  it('rejecting needs a reason, keeps the evidence and the debt, and lets the employee submit a corrected payment', async () => {
    const { sessionId, paymentId } = await pending();
    expect((await w.api('admin', 'POST', `/playstation/payments/${paymentId}/reject`, {})).status).toBe(400);
    const rej = await w.api('admin', 'POST', `/playstation/payments/${paymentId}/reject`, { reason: 'Amount on the screenshot is 100 ETB, not 125' });
    expect(rej.body).toMatchObject({ status: 'REJECTED', balanceMinor: 12500 });
    const d = await detail(sessionId);
    expect(d.session).toMatchObject({ balanceMinor: 12500, paidMinor: 0, pendingMinor: 0, paymentStatus: 'UNPAID' });
    expect(d.payments[0]).toMatchObject({ status: 'REJECTED', rejectReason: 'Amount on the screenshot is 100 ETB, not 125', hasProof: true, rejectedByName: 'ADMIN User' });
    expect((await w.api('admin', 'GET', `/playstation/payments/${paymentId}/proof`)).status).toBe(200); // evidence retained
    expect((await pool.query(`SELECT reason FROM audit_logs WHERE action='ps.payment_rejected' AND entity_id=$1`, [paymentId])).rows[0].reason).toContain('100 ETB');
    expect((await pay(sessionId, { amountMinor: 12500, method: 'CASH' })).body.session.balanceMinor).toBe(0); // paid properly instead
    // the rejected evidence image can still not back another payment, and the employee is told over realtime
    const ev = await pool.query(`SELECT payload FROM outbox_events WHERE event_type='PS_PAYMENT_REJECTED' AND aggregate_id=$1`, [paymentId]);
    expect(ev.rows[0].payload.recordedBy).toBe(w.userIds.ps);
  });

  it('only authorised users may verify; nobody verifies their own payment', async () => {
    const { paymentId } = await pending();
    for (const who of ['ps', 'manager', 'supervisor', 'front', 'rental']) {
      expect((await w.api(who, 'POST', `/playstation/payments/${paymentId}/verify`, {})).status).toBe(403);
      expect((await w.api(who, 'POST', `/playstation/payments/${paymentId}/reject`, { reason: 'nope nope' })).status).toBe(403);
      expect((await w.api(who, 'GET', '/playstation/payments')).status).toBe(403);
    }
    expect((await w.api('manager', 'GET', `/playstation/payments/${paymentId}/proof`)).status).toBe(403); // evidence is private
    expect((await w.api('ps', 'GET', `/playstation/payments/${paymentId}/proof`)).status).toBe(200); // ...but the employee sees their own
    // an owner who recorded a payment cannot approve it
    const s = await open({ packageId: await perGamePackage(), who: 'owner' });
    await addGames(s.id, 2, 'owner');
    await w.api('owner', 'POST', `/playstation/sessions/${s.id}/finish`, {});
    const mine = await payWithProof(s.id, { amountMinor: 5000, method: 'BANK_TRANSFER', reference: 'SELF-' + Date.now() }, proofImage(), 'owner');
    const self = await w.api('owner', 'POST', `/playstation/payments/${mine.body.payment.id}/verify`, {});
    expect(self.status).toBe(403);
    expect(self.body.error.code).toBe('SELF_VERIFICATION');
    expect((await w.api('admin', 'POST', `/playstation/payments/${mine.body.payment.id}/verify`, {})).status).toBe(200);
  });

  it('simultaneous verify and reject of one payment: exactly one wins', async () => {
    const { paymentId } = await pending();
    const res = await Promise.all([
      w.api('admin', 'POST', `/playstation/payments/${paymentId}/verify`, {}), w.api('owner', 'POST', `/playstation/payments/${paymentId}/reject`, { reason: 'looks edited' }),
      w.api('admin', 'POST', `/playstation/payments/${paymentId}/verify`, {}),
    ]);
    expect(res.filter((r) => r.status === 200)).toHaveLength(1);
    expect(res.filter((r) => r.status === 409).every((r) => r.body.error.code === 'PAYMENT_NOT_PENDING')).toBe(true);
  });

  it('an employee can withdraw their own pending payment; the record and evidence stay', async () => {
    const { sessionId, paymentId } = await pending();
    expect((await w.api('ps', 'POST', `/playstation/payments/${paymentId}/cancel`, {})).status).toBe(200);
    expect((await detail(sessionId)).payments[0]).toMatchObject({ status: 'CANCELLED', hasProof: true });
    expect((await detail(sessionId)).session.balanceMinor).toBe(12500);
  });

  it('with verification switched off, non-cash payments count as received immediately', async () => {
    const settings = (await w.api('owner', 'GET', '/playstation/settings')).body.settings;
    await w.api('owner', 'PUT', '/playstation/settings', { ...settings, verifyNonCash: false });
    const s = await open({ packageId: await perGamePackage() });
    await addGames(s.id, 2);
    const p = await payWithProof(s.id, { amountMinor: 5000, method: 'TELEBIRR', reference: 'AUTO-' + Date.now() });
    expect(p.body.payment).toMatchObject({ status: 'PAID', verificationRequired: false });
    await w.api('owner', 'PUT', '/playstation/settings', settings);
  });

  it('evidence files are stored privately under a server-generated key', async () => {
    const { paymentId } = await pending();
    const row = (await pool.query('SELECT proof_key FROM ps_payments WHERE id=$1', [paymentId])).rows[0];
    expect(row.proof_key).toMatch(/\/psproof\/[0-9a-f-]{36}\.png$/);
    expect(await storage.exists(row.proof_key)).toBe(true);
    expect((await w.app.inject({ method: 'GET', url: `/api/v1/playstation/payments/${paymentId}/proof` })).statusCode).toBe(401);
  });
});

describe('timed sessions (post-paid)', () => {
  it('pause freezes the clock, extending adds billable time without any payment, early finish needs a reason', async () => {
    clock.freeze('2026-10-24T10:00:00Z');
    const pkg30 = await newPackage(w, { name: '30 min', durationMinutes: 30, priceMinor: 10000 });
    const pkg15 = await newPackage(w, { name: '15 min', durationMinutes: 15, priceMinor: 6000 });
    const s = await open({ packageId: pkg30 });
    clock.advance(10 * 60_000);
    await w.api('ps', 'POST', `/playstation/sessions/${s.id}/pause`, { reason: 'controller battery' });
    clock.advance(5 * 60_000);
    expect((await detail(s.id)).session.remainingSeconds).toBe(1200);
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s.id}/resume`, {})).body.session.expectedEndAt).toBe('2026-10-24T10:35:00.000Z');
    const ext = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/extend`, { packageId: pkg15 });
    expect(ext.body.session).toMatchObject({ totalMinor: 16000, balanceMinor: 16000, paidMinor: 0, expectedEndAt: '2026-10-24T10:50:00.000Z' });
    expect(ext.body.items.map((i: any) => [i.kind, i.packageName, i.totalMinor])).toEqual([['INITIAL', '30 min', 10000], ['EXTENSION', '15 min', 6000]]);
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, {})).body.error.code).toBe('REASON_REQUIRED');
    const fin = await w.api('ps', 'POST', `/playstation/sessions/${s.id}/finish`, { reason: 'customer had to leave' });
    expect(fin.body.session).toMatchObject({ status: 'COMPLETED', balanceMinor: 16000 });
    const g = await perGamePackage();
    const s2 = await open({ packageId: pkg30 });
    expect((await w.api('ps', 'POST', `/playstation/sessions/${s2.id}/extend`, { packageId: g })).body.error.code).toBe('PACKAGE_TYPE_MISMATCH');
  });

  it('warns once before the end and once when time is up; the session stays open for staff', async () => {
    clock.freeze('2026-10-24T12:00:00Z');
    const s = await open({ packageId: await newPackage(w, { durationMinutes: 30 }) });
    clock.advance(26 * 60_000);
    await processGamingTimers(w.venueId, clock.now());
    await processGamingTimers(w.venueId, clock.now());
    clock.advance(5 * 60_000);
    await processGamingTimers(w.venueId, clock.now());
    await processGamingTimers(w.venueId, clock.now());
    const ev = (await pool.query(`SELECT event_type FROM ps_session_events WHERE ps_session_id=$1 AND event_type IN ('TIME_WARNING','TIME_UP') ORDER BY id`, [s.id])).rows.map((r) => r.event_type);
    expect(ev).toEqual(['TIME_WARNING', 'TIME_UP']);
    expect((await detail(s.id)).session).toMatchObject({ status: 'ACTIVE', remainingSeconds: -60 });
  });
});

describe('cancelling', () => {
  it('only an unplayed, unpaid session can be cancelled', async () => {
    const pkg = await perGamePackage();
    const fresh = await open({ packageId: pkg });
    expect((await w.api('ps', 'POST', `/playstation/sessions/${fresh.id}/cancel`, { reason: 'wrong console picked' })).body.session.status).toBe('CANCELLED');
    const played = await open({ packageId: pkg });
    await addGames(played.id);
    expect((await w.api('ps', 'POST', `/playstation/sessions/${played.id}/cancel`, { reason: 'changed my mind' })).body.error.code).toBe('SESSION_ALREADY_PLAYED');
    const paid = await open({ packageId: pkg });
    await pay(paid.id, { amountMinor: 1, method: 'CASH' }).catch(() => null);
    expect((await w.api('ps', 'POST', `/playstation/sessions/${paid.id}/cancel`, {})).status).toBe(400);
  });
});

describe('outstanding balances, reports and permissions', () => {
  it('outstanding lists every session still owing money, on a verified-money basis', async () => {
    const world = await makeWorld();
    const c1 = await newConsole(world), c2 = await newConsole(world), c3 = await newConsole(world);
    const pkg = await perGamePackage(world);
    const mk = async (c: string, games: number) => { const s = await open({ world, consoleId: c, packageId: pkg }); await addGames(s.id, games, 'ps', world); return s.id; };
    const a = await mk(c1, 4), b = await mk(c2, 2), c = await mk(c3, 1);
    await world.api('ps', 'POST', `/playstation/sessions/${b}/finish`, {});
    await pay(a, { amountMinor: 10000, method: 'CASH' }, 'ps', world);
    await world.api('ps', 'POST', `/playstation/sessions/${c}/finish`, {});
    await payWithProof(c, { amountMinor: 2500, method: 'TELEBIRR', reference: 'OUT-' + Date.now() }, proofImage(), 'ps', world);
    const lr = await world.api('ps', 'GET', '/playstation/sessions?outstanding=true'); if (lr.status !== 200) throw new Error(JSON.stringify(lr.body)); const list = lr.body.sessions;
    expect(list.map((s: any) => s.id).sort()).toEqual([b, c].sort()); // a is paid, b owes, c is only pending verification
    expect(list.find((s: any) => s.id === b)).toMatchObject({ balanceMinor: 5000, status: 'COMPLETED' });
    expect(list.find((s: any) => s.id === c)).toMatchObject({ balanceMinor: 2500, pendingMinor: 2500 });
    const ov = (await world.api('ps', 'GET', '/playstation/overview')).body;
    expect(ov.outstanding).toMatchObject({ sessions: 2, minor: 7500 });
    expect(ov.pendingVerification).toMatchObject({ count: 1, minor: 2500 });
    expect(ov.revenueToday.netMinor).toBe(10000); // cash only; the pending Telebirr payment is not revenue
    const today = ov.date;
    const rep = (await world.api('owner', 'GET', `/playstation/reports?from=${today}&to=${today}`)).body;
    expect(rep.totals.netMinor).toBe(10000);
  });

  it('refunds stay admin-only and do not re-open the debt', async () => {
    const s = await open({ packageId: await perGamePackage() });
    await addGames(s.id, 4);
    const p = await pay(s.id, { amountMinor: 10000, method: 'CASH' });
    expect((await w.api('ps', 'POST', `/playstation/payments/${p.body.payment.id}/refund`, { amountMinor: 2500, reason: 'one game was a glitch' })).status).toBe(403);
    const r = await w.api('owner', 'POST', `/playstation/payments/${p.body.payment.id}/refund`, { amountMinor: 2500, reason: 'one game was a glitch' });
    expect(r.status).toBe(200);
    const d = await detail(s.id);
    expect(d.session).toMatchObject({ paymentStatus: 'PARTIALLY_REFUNDED', paidMinor: 7500, balanceMinor: 0 });
  });

  it('the PlayStation Manager still cannot manage packages, consoles, settings or reports; others have no access', async () => {
    const pkg = await newPackage();
    expect((await w.api('ps', 'PATCH', `/playstation/packages/${pkg}`, { priceMinor: 1 })).status).toBe(403);
    expect((await w.api('ps', 'POST', '/playstation/consoles', { code: 'Z9', name: 'z' })).status).toBe(403);
    expect((await w.api('ps', 'GET', '/playstation/reports?from=2026-01-01&to=2026-01-02')).status).toBe(403);
    for (const who of ['manager', 'supervisor', 'front', 'rental']) expect((await w.api(who, 'GET', '/playstation/overview')).status).toBe(403);
  });

  it('simultaneous session requests can never allocate one console twice', async () => {
    const consoleId = await newConsole();
    const packageId = await newPackage();
    const res = await Promise.all([1, 2, 3, 4].map((i) => w.api(i % 2 ? 'ps' : 'owner', 'POST', '/playstation/sessions', { consoleId, packageId, walkInName: `P${i}` })));
    expect(res.filter((r) => r.status === 201)).toHaveLength(1);
    expect(res.filter((r) => r.status === 409).every((r) => r.body.error.code === 'CONSOLE_IN_USE')).toBe(true);
  });

  it('package price changes never alter sold sessions; sold packages are archived instead of deleted', async () => {
    const pkg = await newPackage(w, { priceMinor: 10000 });
    const s = await open({ packageId: pkg });
    await w.api('owner', 'PATCH', `/playstation/packages/${pkg}`, { priceMinor: 15000 });
    expect((await detail(s.id)).session.totalMinor).toBe(10000);
    expect((await w.api('owner', 'DELETE', `/playstation/packages/${pkg}`)).body).toMatchObject({ archived: true });
    expect((await detail(s.id)).items).toHaveLength(1);
  });

  it('a console under maintenance cannot take a session and an in-use console cannot be taken offline', async () => {
    const m = await newConsole(w, { status: 'MAINTENANCE' });
    expect((await w.api('ps', 'POST', '/playstation/sessions', { consoleId: m, packageId: await newPackage(), walkInName: 'B' })).body.error.code).toBe('CONSOLE_UNAVAILABLE');
    const s = await open();
    expect((await w.api('owner', 'PATCH', `/playstation/consoles/${s.consoleId}`, { status: 'MAINTENANCE' })).body.error.code).toBe('CONSOLE_IN_USE');
  });
});
