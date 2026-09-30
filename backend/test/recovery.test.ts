import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import WebSocket from 'ws';
import { pool } from '../src/db.js';
import { makeWorld, readySession, activeSession, clock, sleep, drainOutbox, type World } from './helpers.js';
import { processOutbox, outboxHooks } from '../src/worker/outbox.js';
import { buildApp } from '../src/app.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });
afterEach(() => { clock.reset(); outboxHooks.beforeDispatch = undefined; });

describe('outbox: worker failure never loses or duplicates work', () => {
  it('session stays COMPLETED while the worker is down; event is delivered once after restart', async () => {
    const a = await activeSession(w);
    await drainOutbox();
    const end = await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    expect(end.status).toBe(200);
    // "worker is unavailable": nothing has processed the outbox yet
    const pending = (await pool.query(`SELECT id, processed_at FROM outbox_events WHERE aggregate_id=$1 AND event_type='SESSION_ENDED'`, [a.sessionId])).rows;
    expect(pending).toHaveLength(1);
    expect(pending[0].processed_at).toBeNull();
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [a.sessionId])).rows[0].status).toBe('EARLY_EXIT');
    // worker comes back
    await drainOutbox();
    expect((await pool.query('SELECT processed_at FROM outbox_events WHERE id=$1', [pending[0].id])).rows[0].processed_at).not.toBeNull();
    // running it again (two workers, or a restart) is harmless
    expect(await drainOutbox()).toBe(0);
    expect((await pool.query(`SELECT count(*)::int n FROM session_events WHERE session_id=$1 AND event_type='SESSION_ENDED'`, [a.sessionId])).rows[0].n).toBe(1);
  });

  it('a failing downstream delivery is retried with backoff and does not affect business state', async () => {
    const a = await activeSession(w);
    await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    let failures = 0;
    outboxHooks.beforeDispatch = (e) => { if (e.event_type === 'SESSION_ENDED') { failures++; throw new Error('notification service down'); } };
    await drainOutbox();
    const row = (await pool.query(`SELECT processed_at, attempt_count, last_error, available_at FROM outbox_events WHERE aggregate_id=$1 AND event_type='SESSION_ENDED'`, [a.sessionId])).rows[0];
    expect(failures).toBeGreaterThan(0);
    expect(row.processed_at).toBeNull();
    expect(row.attempt_count).toBe(1);
    expect(row.last_error).toMatch(/notification service down/);
    expect(new Date(row.available_at).getTime()).toBeGreaterThan(Date.now());
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [a.sessionId])).rows[0].status).toBe('EARLY_EXIT');
    // other events were not blocked by the poisoned one
    const other = await activeSession(w);
    await drainOutbox();
    expect((await pool.query(`SELECT processed_at FROM outbox_events WHERE aggregate_id=$1 AND event_type='SESSION_STARTED'`, [other.sessionId])).rows[0].processed_at).not.toBeNull();
    // service recovers; after the backoff the event goes through exactly once
    outboxHooks.beforeDispatch = undefined;
    clock.freeze(new Date(Date.now() + 10 * 60_000));
    await drainOutbox();
    const after = (await pool.query(`SELECT processed_at FROM outbox_events WHERE aggregate_id=$1 AND event_type='SESSION_ENDED'`, [a.sessionId])).rows[0];
    expect(after.processed_at).not.toBeNull();
  });

  it('notifications are created once per event even if processing is repeated', async () => {
    const w2 = await makeWorld({ capacity: 1 });
    const a = await readySession(w2);
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/start`, {});
    await drainOutbox();
    await pool.query(`UPDATE outbox_events SET processed_at=NULL WHERE venue_id=$1`, [w2.venueId]); // force reprocessing
    await drainOutbox();
    const n = (await pool.query(`SELECT count(*)::int n FROM notifications WHERE venue_id=$1 AND type='CAPACITY_FULL'`, [w2.venueId])).rows[0].n;
    expect(n).toBe(1);
  });
});

describe('restarts', () => {
  it('API restart: sessions, timers and outbox survive; nothing is duplicated', async () => {
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w);
    const before = (await pool.query('SELECT * FROM sessions WHERE id=$1', [a.sessionId])).rows[0];
    const second = await buildApp({ embeddedWorker: false }); // a fresh process on the same DB
    clock.freeze('2026-09-30T17:30:00Z');
    const r = await second.app.inject({ method: 'GET', url: `/api/v1/sessions/${a.sessionId}`, headers: { authorization: `Bearer ${w.tokens.front}` } });
    expect(r.json().session.status).toBe('ACTIVE');
    expect(r.json().session.remainingSeconds).toBe(1800);
    expect(new Date(before.started_at).toISOString()).toBe('2026-09-30T17:00:00.000Z');
    // tokens issued before the restart remain valid (sessions live in the DB, not in process memory)
    expect(r.statusCode).toBe(200);
    await second.close();
    expect((await pool.query(`SELECT count(*)::int n FROM sessions WHERE visit_id=$1`, [a.visitId])).rows[0].n).toBe(1);
  });

  it('idempotency survives a restart: a retried request after a crash returns the original result', async () => {
    const r = await readySession(w);
    const key = 'restart-safe-key-0001';
    const first = await w.api('front', 'POST', `/sessions/${r.sessionId}/start`, {}, { 'idempotency-key': key });
    expect(first.status).toBe(200);
    const second = await buildApp({ embeddedWorker: false });
    const again = await second.app.inject({ method: 'POST', url: `/api/v1/sessions/${r.sessionId}/start`, headers: { authorization: `Bearer ${w.tokens.front}`, 'idempotency-key': key }, payload: {} });
    expect(again.statusCode).toBe(200);
    expect(again.headers['idempotent-replay']).toBe('true');
    expect(again.json().startedAt).toBe(first.body.startedAt);
    await second.close();
  });
});

describe('realtime', () => {
  async function connect(url: string, token: string) {
    const ws = new WebSocket(url.replace('http', 'ws') + '/api/v1/realtime');
    const messages: any[] = [];
    ws.on('message', (d) => messages.push(JSON.parse(d.toString())));
    await new Promise((res, rej) => { ws.on('open', res); ws.on('error', rej); });
    ws.send(JSON.stringify({ type: 'auth', token }));
    for (let i = 0; i < 50 && !messages.some((m) => m.type === 'ready'); i++) await sleep(20);
    return { ws, messages };
  }
  const waitFor = async (messages: any[], pred: (m: any) => boolean, ms = 3000) => {
    for (let i = 0; i < ms / 25; i++) { const m = messages.find(pred); if (m) return m; await sleep(25); }
    return null;
  };

  it('devices receive small operational events without personal data; other venues receive nothing', async () => {
    const other = await makeWorld();
    const built = await buildApp({ embeddedWorker: false });
    await built.app.listen({ port: 0, host: '127.0.0.1' });
    const addr = built.app.server.address() as any;
    const url = `http://127.0.0.1:${addr.port}`;
    try {
      const deviceB = await connect(url, w.tokens.manager);
      const stranger = await connect(url, other.tokens.owner);
      const bad = new WebSocket(url.replace('http', 'ws') + '/api/v1/realtime');
      const closed = new Promise<number>((res) => bad.on('close', (c) => res(c)));
      await new Promise((res) => bad.on('open', res));
      bad.send(JSON.stringify({ type: 'auth', token: 'totally-invalid-token' }));
      expect(await closed).toBe(4401);

      // Device A starts a session (through the API of the same DB); the worker delivers the outbox.
      const a = await activeSession(w);
      await drainOutbox();
      const started = await waitFor(deviceB.messages, (m) => m.type === 'event' && m.event === 'SESSION_STARTED' && m.payload?.sessionId === a.sessionId);
      expect(started).not.toBeNull();
      const cap = await waitFor(deviceB.messages, (m) => m.event === 'CAPACITY_CHANGED' && m.payload?.occupancy !== undefined);
      expect(cap).not.toBeNull();
      const text = JSON.stringify(deviceB.messages);
      expect(text).not.toMatch(/Abebe|phone|\+251|photo|amountMinor|email/i);
      // Device B ends it; device A would see SESSION_ENDED
      await w.api('manager', 'POST', `/sessions/${a.sessionId}/end`, {});
      await drainOutbox();
      expect(await waitFor(deviceB.messages, (m) => m.event === 'SESSION_ENDED' && m.payload?.sessionId === a.sessionId)).not.toBeNull();
      expect(stranger.messages.filter((m) => m.type === 'event')).toHaveLength(0);
      deviceB.ws.close(); stranger.ws.close();
    } finally { await built.close(); }
  });

  it('after a disconnect the database is still correct; reconnecting clients reconcile by refetching', async () => {
    const a = await activeSession(w);
    // nobody is listening when these happen
    await w.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 15, payment: { method: 'CASH' } });
    await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    await drainOutbox();
    // a device that reconnects now just reads current state
    const dash = await w.api('manager', 'GET', '/dashboard');
    expect(dash.body.liveSessions.map((s: any) => s.id)).not.toContain(a.sessionId);
    const one = await w.api('manager', 'GET', `/sessions/${a.sessionId}`);
    expect(one.body.session.status).toBe('EARLY_EXIT');
    expect(one.body.events.map((e: any) => e.eventType)).toEqual(expect.arrayContaining(['SESSION_EXTENDED', 'SESSION_ENDED']));
  });
});
