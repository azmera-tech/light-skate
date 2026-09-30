import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { pool } from '../src/db.js';
import { makeWorld, registerCustomer, readySession, activeSession, addSkates, makePng, clock, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });
afterEach(() => clock.reset());

describe('daily history, customer history, reports (derived from real records)', () => {
  it('builds a consistent picture from visits, sessions, payments and equipment', async () => {
    const w2 = await makeWorld({ capacity: 50 });
    const [skate] = await addSkates(w2, 1, 'HIST');
    clock.freeze('2026-09-30T17:00:00Z'); // 20:00 local
    const a = await activeSession(w2, { equipmentIds: [skate] });
    await w2.api('front', 'POST', `/customers/${a.customerId}/photos?purpose=VISIT&visitId=${a.visitId}`, makePng(200, 200));
    clock.freeze('2026-09-30T17:50:00Z');
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/extend`, { minutes: 30, payment: { method: 'CASH' } });
    clock.freeze('2026-09-30T18:40:00Z');
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    await w2.api('rental', 'POST', `/equipment/${skate}/return`, { condition: 'GOOD' });
    const b = await activeSession(w2);                       // still skating
    const cancelled = await readySession(w2);
    await w2.api('front', 'POST', `/sessions/${cancelled.sessionId}/cancel`, { reason: 'left queue' });
    const pendingOnly = await registerCustomer(w2);
    const v = await w2.api('front', 'POST', '/visits', { customerId: pendingOnly.id });
    void v; void b;

    const day = await w2.api('front', 'GET', '/visits?date=2026-09-30');
    expect(day.body.date).toBe('2026-09-30');
    const row = day.body.visits.find((x: any) => x.visitId === a.visitId);
    expect(row).toMatchObject({ fullName: 'Abebe Kebede', sessionStatus: 'COMPLETED', equipment: 'HIST-001', staffName: 'FRONT_DESK User', paidMinor: 30000, visitStatus: 'COMPLETED' });
    expect(row.phoneE164).toMatch(/^\+2519/);
    expect(row.photoId).toBeTruthy();
    expect(row.customerCode).toMatch(/^LS-C\d{6}$/);
    expect(row.visitNumber).toMatch(/^LS-20260930-/);
    const filter = async (f: string) => (await w2.api('front', 'GET', `/visits?date=2026-09-30&filter=${f}`)).body.visits.length;
    expect(await filter('all')).toBe(4);
    expect(await filter('completed')).toBe(1);
    expect(await filter('active')).toBe(1);
    expect(await filter('cancelled')).toBe(1);
    expect((await w2.api('front', 'GET', '/visits?date=2026-09-29')).body.visits).toHaveLength(0);
    // rental staff can see history but not payment amounts
    const rentalView = await w2.api('rental', 'GET', '/visits?date=2026-09-30');
    expect(rentalView.body.visits[0].paidMinor).toBeNull();

    // visit timeline: every step, in order, attributed
    const tl = await w2.api('front', 'GET', `/visits/${a.visitId}`);
    const kinds = tl.body.timeline.map((e: any) => `${e.source}:${e.eventType}`);
    expect(kinds).toEqual(expect.arrayContaining(['session:SESSION_CREATED', 'payment:PAYMENT_PAID', 'session:SESSION_STARTED', 'equipment:ISSUED', 'session:SESSION_EXTENDED', 'session:SESSION_ENDED', 'equipment:RETURNED', 'session:VISIT_COMPLETED']));
    const times = tl.body.timeline.map((e: any) => new Date(e.occurredAt).getTime());
    expect([...times].sort((x, y) => x - y)).toEqual(times);
    expect(tl.body.timeline.find((e: any) => e.eventType === 'SESSION_STARTED').deviceName).toBe('FRONT-DESK-01');

    // customer profile + history derive from the same records
    const prof = await w2.api('front', 'GET', `/customers/${a.customerId}`);
    expect(prof.body.stats).toMatchObject({ visitCount: 1, totalSpentMinor: 30000, equipmentIssuedCount: 1 });
    expect(prof.body.stats.totalSkatingSeconds).toBe(100 * 60);
    const hist = await w2.api('front', 'GET', `/customers/${a.customerId}/history`);
    expect(hist.body.history[0]).toMatchObject({ sessionStatus: 'COMPLETED', paidMinor: 30000, equipment: 'HIST-001', productName: 'Standard' });

    // daily report
    const rep = await w2.api('manager', 'GET', '/reports/daily?date=2026-09-30');
    expect(rep.body.visitors).toBe(2 + 0); // a + b checked in (cancelled/pending never entered)
    expect(rep.body.sessions).toMatchObject({ started: 2, completed: 1, active: 1, cancelled: 1 });
    expect(rep.body.sessions.extensions).toBe(1);
    expect(rep.body.revenue.chargesMinor).toBe(20000 + 10000 + 20000 + 20000); // a + ext + b + cancelled(paid, not refunded)
    expect(rep.body.revenue.refundsMinor).toBe(0);
    expect(rep.body.revenue.byMethod[0]).toMatchObject({ method: 'CASH' });
    expect(rep.body.equipment.issues).toBe(1);
    expect(rep.body.averageSessionSeconds).toBe(6000);
    expect(rep.body.hourlyStarts).toEqual([{ hour: 20, sessions: 1 }, { hour: 21, sessions: 1 }]);
    expect(rep.body.capacityUtilizationPercent).toBeGreaterThan(0);
    expect((await w2.api('front', 'GET', '/reports/daily')).status).toBe(403);
    const range = await w2.api('manager', 'GET', '/reports/range?from=2026-09-28&to=2026-10-02&group=day');
    expect(range.body.rows).toEqual([expect.objectContaining({ period: '2026-09-30', sessionsStarted: 2, revenueMinor: 70000 })]);
    const monthly = await w2.api('manager', 'GET', '/reports/range?from=2026-09-01&to=2026-10-31&group=month');
    expect(monthly.body.rows[0].period).toBe('2026-09-01');
    expect((await w2.api('manager', 'GET', '/reports/range?from=2026-10-02&to=2026-09-01')).status).toBe(400);
  });

  it("'today' is the venue's local date, not the UTC date", async () => {
    const w2 = await makeWorld();
    clock.freeze('2026-09-30T21:30:00Z'); // 00:30 on 1 Oct in Addis
    const a = await readySession(w2);
    const d1 = await w2.api('front', 'GET', '/visits?date=2026-10-01');
    expect(d1.body.visits.map((v: any) => v.visitId)).toContain(a.visitId);
    expect((await w2.api('front', 'GET', '/visits?date=2026-09-30')).body.visits).toHaveLength(0);
    expect((await w2.api('front', 'GET', '/visits')).body.date).toBe('2026-10-01');
    expect((await w2.api('front', 'GET', '/dashboard')).body.localDate).toBe('2026-10-01');
    expect(a.visitId).toBeTruthy();
  });

  it('audit log is filterable, attributed, complete and append-only', async () => {
    const a = await activeSession(w);
    await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    const log = await w.api('owner', 'GET', `/audit?entityType=session&entityId=${a.sessionId}`);
    const actions = log.body.entries.map((e: any) => e.action);
    expect(actions).toEqual(expect.arrayContaining(['session.created', 'session.started', 'session.ended']));
    const started = log.body.entries.find((e: any) => e.action === 'session.started');
    expect(started).toMatchObject({ actorName: 'FRONT_DESK User', deviceName: 'FRONT-DESK-01' });
    expect(started.requestId).toBeTruthy();
    expect((await w.api('owner', 'GET', '/audit?action=payment.')).body.entries.every((e: any) => e.action.startsWith('payment.'))).toBe(true);
    expect((await w.api('front', 'GET', '/audit')).status).toBe(403);
    await expect(pool.query('UPDATE audit_logs SET action=$1 WHERE venue_id=$2', ['x', w.venueId])).rejects.toThrow(/append-only/);
    await expect(pool.query('DELETE FROM audit_logs WHERE venue_id=$1', [w.venueId])).rejects.toThrow(/append-only/);
    await expect(pool.query('UPDATE session_events SET event_type=$1 WHERE session_id=$2', ['x', a.sessionId])).rejects.toThrow(/append-only/);
  });

  it('customers can be found by name, code, phone fragment, or id; search needs at least 2 chars', async () => {
    const c = await registerCustomer(w, 'front', { fullName: 'Tigist Haile', phone: '0966123456' });
    const code = (await w.api('front', 'GET', `/customers/${c.id}`)).body.customerCode;
    for (const q of ['tigist', 'Haile', '0966123', '966123456', code, c.id]) {
      const r = await w.api('front', 'GET', `/customers?q=${encodeURIComponent(q)}`);
      expect(r.body.customers.map((x: any) => x.id), q).toContain(c.id);
    }
    expect((await w.api('front', 'GET', '/customers?q=t')).body.customers).toEqual([]);
  });
});

describe('day close', () => {
  it('is blocked by open work, reconciles cash, and the closing record is preserved', async () => {
    const w2 = await makeWorld();
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w2);
    const blocked = await w2.api('manager', 'POST', '/day-close', { date: '2026-09-30', countedCashMinor: 20000 });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('DAY_CLOSE_BLOCKED');
    expect(blocked.body.error.message).toMatch(/1 active session/);
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    const prev = await w2.api('manager', 'GET', '/day-close/preview?date=2026-09-30');
    expect(prev.body).toMatchObject({ expectedCashMinor: 20000, blockers: [], checks: { activeSessions: 0, unreturnedSkates: 0 } });
    const short = await w2.api('manager', 'POST', '/day-close', { date: '2026-09-30', countedCashMinor: 19000 });
    expect(short.status).toBe(422);
    const ok = await w2.api('manager', 'POST', '/day-close', { date: '2026-09-30', countedCashMinor: 19000, notes: '10 ETB short, change error' });
    expect(ok.status).toBe(201);
    expect(ok.body.differenceMinor).toBe(-1000);
    expect((await w2.api('manager', 'POST', '/day-close', { date: '2026-09-30', countedCashMinor: 20000 })).body.error.code).toBe('DAY_ALREADY_CLOSED');
    await expect(pool.query('UPDATE day_closes SET counted_cash_minor=1 WHERE venue_id=$1', [w2.venueId])).rejects.toThrow(/append-only/);
    expect((await w2.api('front', 'POST', '/day-close', { countedCashMinor: 0 })).status).toBe(403);
    expect((await w2.api('manager', 'GET', '/day-closes')).body.closes).toHaveLength(1);
  });
});

describe('dashboard', () => {
  it('answers: who is skating, how many inside, who is about to finish, who expired, spaces left, waiting, equipment out', async () => {
    const w2 = await makeWorld({ capacity: 10 });
    const [sk] = await addSkates(w2, 2, 'DASH');
    clock.freeze('2026-09-30T17:00:00Z');
    const a = await activeSession(w2, { equipmentIds: [sk] });
    const b = await activeSession(w2, { minutes: 30 });
    const waiting = await readySession(w2);
    clock.freeze('2026-09-30T17:20:00Z');
    const { processSessionTimers } = await import('../src/modules/sessions.js');
    await processSessionTimers(w2.venueId, clock.now()); // b has 10 minutes left -> expiring
    clock.freeze('2026-09-30T17:31:00Z');
    await processSessionTimers(w2.venueId, clock.now()); // b expired
    const d = (await w2.api('manager', 'GET', '/dashboard')).body;
    expect(d.capacity).toMatchObject({ occupancy: 2, max: 10, available: 8, full: false });
    expect(d.rink).toEqual({ normal: 1, expiring: 0, expired: 1 });
    expect(d.waiting).toBe(1);
    expect(d.equipment.out).toBe(1);
    expect(d.today.visitors).toBe(2);
    expect(d.today.revenueMinor).toBe(50000);
    const byId = Object.fromEntries(d.liveSessions.map((s: any) => [s.id, s]));
    expect(byId[a.sessionId]).toMatchObject({ status: 'ACTIVE', customerName: 'Abebe Kebede', equipment: 'DASH-001', remainingSeconds: 1740 });
    expect(byId[b.sessionId].status).toBe('EXPIRED');
    expect(byId[b.sessionId].remainingSeconds).toBe(-60);
    expect(d.liveSessions[0].id).toBe(b.sessionId); // most urgent first
    const ws = (await w2.api('manager', 'GET', '/sessions?group=waiting')).body.sessions;
    expect(ws.map((s: any) => s.id)).toEqual([waiting.sessionId]);
    expect(d.serverTime).toBe('2026-09-30T17:31:00.000Z');
  });
});
