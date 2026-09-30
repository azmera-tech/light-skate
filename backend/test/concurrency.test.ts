import { describe, it, expect, beforeAll } from 'vitest';
import { randomUUID } from 'node:crypto';
import { pool } from '../src/db.js';
import { makeWorld, readySession, activeSession, registerCustomer, addSkates, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });

describe('capacity under simultaneous starts', () => {
  it('never exceeds capacity when many staff start sessions at once', async () => {
    const w2 = await makeWorld({ capacity: 3 });
    const ready = [];
    for (let i = 0; i < 10; i++) ready.push(await readySession(w2));
    const results = await Promise.all(ready.map((r, i) => w2.api(i % 2 ? 'front' : 'manager', 'POST', `/sessions/${r.sessionId}/start`, {})));
    const ok = results.filter((r) => r.status === 200);
    const full = results.filter((r) => r.status === 409);
    expect(ok).toHaveLength(3);
    expect(full).toHaveLength(7);
    expect(full.every((r) => r.body.error.code === 'VENUE_FULL')).toBe(true);
    const occ = (await pool.query(`SELECT count(*)::int n FROM sessions WHERE venue_id=$1 AND status='ACTIVE'`, [w2.venueId])).rows[0].n;
    expect(occ).toBe(3);
    // the losers are intact and can start later
    const losers = ready.filter((_, i) => results[i].status === 409);
    expect((await pool.query('SELECT status FROM sessions WHERE id = ANY($1)', [losers.map((l) => l.sessionId)])).rows.every((r) => r.status === 'READY')).toBe(true);
  });

  it('the same session started from two devices at once starts exactly once', async () => {
    const r = await readySession(w);
    const res = await Promise.all([w.api('front', 'POST', `/sessions/${r.sessionId}/start`, {}), w.api('manager', 'POST', `/sessions/${r.sessionId}/start`, {}), w.api('front', 'POST', `/sessions/${r.sessionId}/start`, {})]);
    expect(res.filter((x) => x.status === 200)).toHaveLength(1);
    expect(res.filter((x) => x.status === 409).every((x) => x.body.error.code === 'SESSION_ALREADY_STARTED')).toBe(true);
    const starts = (await pool.query(`SELECT count(*)::int n FROM session_events WHERE session_id=$1 AND event_type='SESSION_STARTED'`, [r.sessionId])).rows[0].n;
    expect(starts).toBe(1);
  });

  it('database guarantees one live session per customer even if application checks were bypassed', async () => {
    const a = await activeSession(w);
    const v2 = (await pool.query(`INSERT INTO visits (venue_id, visit_number, customer_id, local_date) VALUES ($1,$2,$3,'2026-01-01') RETURNING id`, [w.venueId, 'X-' + randomUUID(), a.customerId])).rows[0].id;
    await expect(pool.query(
      `INSERT INTO sessions (venue_id, visit_id, customer_id, status, product_name, price_minor, currency, original_duration_seconds, current_duration_seconds)
       VALUES ($1,$2,$3,'ACTIVE','x',0,'ETB',60,60)`, [w.venueId, v2, a.customerId])).rejects.toThrow(/sessions_one_live_per_customer/);
  });
});

describe('equipment under simultaneous assignment', () => {
  it('two staff issue the same skate at once: exactly one succeeds with a clear message', async () => {
    const [skate] = await addSkates(w, 1, 'CONC');
    const [a, b] = [await activeSession(w), await activeSession(w)];
    const [r1, r2] = await Promise.all([
      w.api('front', 'POST', `/equipment/${skate}/assign`, { sessionId: a.sessionId }),
      w.api('rental', 'POST', `/equipment/${skate}/assign`, { sessionId: b.sessionId }),
    ]);
    const statuses = [r1.status, r2.status].sort();
    expect(statuses).toEqual([200, 409]);
    const loser = r1.status === 409 ? r1 : r2;
    expect(loser.body.error.code).toBe('EQUIPMENT_UNAVAILABLE');
    expect(loser.body.error.message).toBe('CONC-001 is no longer available.');
    const open = (await pool.query(`SELECT count(*)::int n FROM equipment_assignments WHERE equipment_id=$1 AND returned_at IS NULL`, [skate])).rows[0].n;
    expect(open).toBe(1);
  });

  it('many staff race for a handful of skates: no unit is ever double-assigned', async () => {
    const skates = await addSkates(w, 3, 'RACE');
    const sessions = [];
    for (let i = 0; i < 6; i++) sessions.push(await activeSession(w));
    const jobs = sessions.flatMap((s) => skates.map((k) => w.api('rental', 'POST', `/equipment/${k}/assign`, { sessionId: s.sessionId })));
    await Promise.all(jobs);
    const rows = (await pool.query(`SELECT equipment_id, count(*)::int n FROM equipment_assignments WHERE equipment_id = ANY($1) AND returned_at IS NULL GROUP BY equipment_id`, [skates])).rows;
    expect(rows).toHaveLength(3);
    expect(rows.every((r) => r.n === 1)).toBe(true);
  });

  it('start with equipment is atomic: if one unit is unavailable nothing is created or issued', async () => {
    const [free, taken] = await addSkates(w, 2, 'ATOM');
    const other = await activeSession(w);
    await w.api('front', 'POST', `/equipment/${taken}/assign`, { sessionId: other.sessionId });
    const r = await readySession(w);
    const res = await w.api('front', 'POST', `/sessions/${r.sessionId}/start`, { equipmentIds: [free, taken] });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('EQUIPMENT_UNAVAILABLE');
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [r.sessionId])).rows[0].status).toBe('READY');
    expect((await pool.query('SELECT status FROM equipment WHERE id=$1', [free])).rows[0].status).toBe('AVAILABLE');
    expect((await pool.query(`SELECT count(*)::int n FROM session_events WHERE session_id=$1 AND event_type='SESSION_STARTED'`, [r.sessionId])).rows[0].n).toBe(0);
    expect((await pool.query(`SELECT count(*)::int n FROM outbox_events WHERE aggregate_id=$1 AND event_type='SESSION_STARTED'`, [r.sessionId])).rows[0].n).toBe(0);
  });
});

describe('simultaneous modification of one session', () => {
  it('end vs end: one wins, the other gets a clear conflict', async () => {
    const a = await activeSession(w);
    const res = await Promise.all([w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {}), w.api('manager', 'POST', `/sessions/${a.sessionId}/end`, {})]);
    expect(res.map((r) => r.status).sort()).toEqual([200, 409]);
    const loser = res.find((r) => r.status === 409)!;
    expect(loser.body.error.message).toMatch(/already been/);
    expect((await pool.query(`SELECT count(*)::int n FROM session_events WHERE session_id=$1 AND event_type='SESSION_ENDED'`, [a.sessionId])).rows[0].n).toBe(1);
  });

  it('end vs extend from two tablets: final state is consistent with whichever ran last', async () => {
    const a = await activeSession(w);
    const res = await Promise.all([
      w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {}),
      w.api('manager', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 30, payment: { method: 'CASH' } }),
    ]);
    const s = (await pool.query('SELECT status FROM sessions WHERE id=$1', [a.sessionId])).rows[0].status;
    const ended = res[0].status === 200, extended = res[1].status === 200;
    expect(ended).toBe(true);
    if (extended) expect(s).toBe('EARLY_EXIT'); // extend ran first, then end
    else { expect(res[1].status).toBe(409); expect(res[1].body.error.code).toBe('SESSION_INVALID_TRANSITION'); }
    // a rejected extension must not leave a payment or extension row behind
    const ext = (await pool.query('SELECT count(*)::int n FROM session_extensions WHERE session_id=$1', [a.sessionId])).rows[0].n;
    const pays = (await pool.query(`SELECT count(*)::int n FROM payments WHERE session_id=$1 AND purpose='EXTENSION'`, [a.sessionId])).rows[0].n;
    expect(ext).toBe(extended ? 1 : 0);
    expect(pays).toBe(extended ? 1 : 0);
  });

  it('two simultaneous extensions both apply, serially (no lost update)', async () => {
    const a = await activeSession(w);
    const before = new Date((await pool.query('SELECT scheduled_end_at FROM sessions WHERE id=$1', [a.sessionId])).rows[0].scheduled_end_at).getTime();
    const res = await Promise.all([
      w.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 30, payment: { method: 'CASH' } }),
      w.api('manager', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 15, payment: { method: 'CASH' } }),
    ]);
    expect(res.every((r) => r.status === 200)).toBe(true);
    const after = new Date((await pool.query('SELECT scheduled_end_at FROM sessions WHERE id=$1', [a.sessionId])).rows[0].scheduled_end_at).getTime();
    expect(after - before).toBe(45 * 60_000);
  });

  it('simultaneous payments cannot overpay a session', async () => {
    const c = await registerCustomer(w);
    const r = await readySession(w, { customerId: c.id }).catch(() => null);
    void r;
    const c2 = await registerCustomer(w);
    const { acceptWaiver, productId } = await import('./helpers.js');
    await acceptWaiver(w, c2.id);
    const v = await w.api('front', 'POST', '/visits', { customerId: c2.id });
    const s = await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: await productId(w, 60) });
    const res = await Promise.all(Array.from({ length: 5 }, () => w.api('front', 'POST', '/payments', { sessionId: s.body.id, amountMinor: 20000, method: 'CASH' })));
    expect(res.filter((x) => x.status === 201)).toHaveLength(1);
    const total = (await pool.query(`SELECT COALESCE(sum(amount_minor),0)::int t FROM payments WHERE session_id=$1`, [s.body.id])).rows[0].t;
    expect(total).toBe(20000);
  });
});
