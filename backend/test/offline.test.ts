import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { randomUUID } from 'node:crypto';
import { pool } from '../src/db.js';
import { makeWorld, activeSession, readySession, addSkates, clock, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });
afterEach(() => clock.reset());

const sync = (who: string, commands: any[]) => w.api(who, 'POST', '/sync/commands', { commands }, { 'no-idem': '1' });

describe('offline command replay', () => {
  it('queued commands run through the same validated path; replays are duplicates, not repeats', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    clock.freeze('2026-09-30T17:40:00Z'); // reconnect time
    const requestId = randomUUID();
    const cmd = { requestId, command: 'END_SESSION', sessionId: a.sessionId, issuedAt: '2026-09-30T17:35:00Z', params: { reason: 'left while offline' } };
    const r1 = await sync('front', [cmd]);
    expect(r1.status).toBe(200);
    expect(r1.body.results[0].outcome).toBe('ACCEPTED');
    const s = (await pool.query('SELECT status, actual_end_at FROM sessions WHERE id=$1', [a.sessionId])).rows[0];
    expect(s.status).toBe('EARLY_EXIT');
    expect(new Date(s.actual_end_at).toISOString()).toBe('2026-09-30T17:35:00.000Z'); // honours when the staff member actually pressed END
    const ev = (await pool.query(`SELECT metadata FROM session_events WHERE session_id=$1 AND event_type='SESSION_ENDED'`, [a.sessionId])).rows[0];
    expect(ev.metadata.clientIssuedAt).toBe('2026-09-30T17:35:00.000Z');
    // the tablet retries the whole batch after a flaky reconnect
    const r2 = await sync('front', [cmd]);
    expect(r2.body.results[0].outcome).toBe('DUPLICATE');
    expect((await pool.query(`SELECT count(*)::int n FROM session_events WHERE session_id=$1 AND event_type='SESSION_ENDED'`, [a.sessionId])).rows[0].n).toBe(1);
  });

  it('client timestamps are clamped: cannot back-date before the start or forward-date into the future', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    clock.freeze('2026-09-30T17:30:00Z');
    await sync('front', [{ requestId: randomUUID(), command: 'END_SESSION', sessionId: a.sessionId, issuedAt: '2020-01-01T00:00:00Z' }]);
    expect(new Date((await pool.query('SELECT actual_end_at FROM sessions WHERE id=$1', [a.sessionId])).rows[0].actual_end_at).toISOString()).toBe('2026-09-30T17:00:00.000Z');
    const b = await activeSession(w);
    await sync('front', [{ requestId: randomUUID(), command: 'END_SESSION', sessionId: b.sessionId, issuedAt: '2031-01-01T00:00:00Z' }]);
    expect(new Date((await pool.query('SELECT actual_end_at FROM sessions WHERE id=$1', [b.sessionId])).rows[0].actual_end_at).toISOString()).toBe('2026-09-30T17:30:00.000Z');
  });

  it('conflicts are reported clearly and never silently overwrite newer state', async () => {
    const a = await activeSession(w);
    await w.api('manager', 'POST', `/sessions/${a.sessionId}/end`, {}); // another device already ended it
    const r = await sync('front', [
      { requestId: randomUUID(), command: 'END_SESSION', sessionId: a.sessionId },
      { requestId: randomUUID(), command: 'EXTEND_SESSION', sessionId: a.sessionId, params: { minutes: 30, payment: { method: 'CASH' } } },
    ]);
    expect(r.body.results[0].outcome).toBe('CONFLICT');
    expect(r.body.results[0].message).toMatch(/already been ended early|already ended|already been/i);
    expect(r.body.results[1].outcome).toBe('CONFLICT');
    expect((await pool.query(`SELECT count(*)::int n FROM payments WHERE session_id=$1 AND purpose='EXTENSION'`, [a.sessionId])).rows[0].n).toBe(0);
  });

  it('only an explicit allow-list can run offline; money, starts, refunds and settings need a live connection', async () => {
    const r = await readySession(w);
    const res = await sync('manager', [
      { requestId: randomUUID(), command: 'START_SESSION', sessionId: r.sessionId },
      { requestId: randomUUID(), command: 'REFUND_PAYMENT', params: { paymentId: r.paymentId } },
      { requestId: randomUUID(), command: 'CHANGE_SETTINGS', params: {} },
      { requestId: randomUUID(), command: 'END_SESSION' },
    ]);
    expect(res.body.results.map((x: any) => x.outcome)).toEqual(['REJECTED', 'REJECTED', 'REJECTED', 'REJECTED']);
    expect(res.body.results[0].code).toBe('OFFLINE_NOT_ALLOWED');
    expect(res.body.results[3].code).toBe('INVALID_COMMAND');
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [r.sessionId])).rows[0].status).toBe('READY');
  });

  it('permissions still apply during replay', async () => {
    const a = await activeSession(w);
    const res = await sync('rental', [{ requestId: randomUUID(), command: 'END_SESSION', sessionId: a.sessionId }]);
    expect(res.body.results[0].outcome).toBe('REJECTED');
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [a.sessionId])).rows[0].status).toBe('ACTIVE');
  });

  it('queues of pause/resume/equipment return replay in order', async () => {
    const [skate] = await addSkates(w, 1, 'OFF');
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w, { equipmentIds: [skate] });
    clock.freeze('2026-09-30T17:20:00Z');
    const res = await sync('front', [
      { requestId: randomUUID(), command: 'PAUSE_SESSION', sessionId: a.sessionId },
      { requestId: randomUUID(), command: 'RESUME_SESSION', sessionId: a.sessionId },
      { requestId: randomUUID(), command: 'END_SESSION', sessionId: a.sessionId },
      { requestId: randomUUID(), command: 'RETURN_EQUIPMENT', equipmentId: skate, params: { condition: 'GOOD' } },
    ]);
    expect(res.body.results.map((x: any) => x.outcome)).toEqual(['ACCEPTED', 'ACCEPTED', 'ACCEPTED', 'ACCEPTED']);
    // Standard rule: a returned rental skate needs cleaning before it can go out again.
    expect((await pool.query('SELECT status FROM equipment WHERE id=$1', [skate])).rows[0].status).toBe('NEEDS_CLEANING');
  });
});
