import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { pool } from '../src/db.js';
import { makeWorld, registerCustomer, readySession, productId, acceptWaiver, clock, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });
afterEach(() => clock.reset());

describe('waivers', () => {
  it('start requires acceptance of the CURRENT version; old acceptances are kept when a new version is published', async () => {
    const c = await registerCustomer(w);
    const v = await w.api('front', 'POST', '/visits', { customerId: c.id });
    const s = await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: await productId(w, 60) });
    await w.api('front', 'POST', '/payments', { sessionId: s.body.id, amountMinor: 20000, method: 'CASH' });
    const noWaiver = await w.api('front', 'POST', `/sessions/${s.body.id}/start`, {});
    expect(noWaiver.status).toBe(409);
    expect(noWaiver.body.error.code).toBe('WAIVER_REQUIRED');
    await acceptWaiver(w, c.id, 'front', v.body.id);
    const v1 = (await w.api('front', 'GET', '/waivers/current')).body.waiver;
    expect(v1.version).toBe(1);
    // publish v2
    const pub = await w.api('owner', 'POST', '/waivers/versions', { title: 'Updated rules', body: 'New rules and waiver text that is long enough to be valid.' });
    expect(pub.status).toBe(201);
    expect(pub.body.version).toBe(2);
    const stale = await w.api('front', 'POST', `/customers/${c.id}/waiver-acceptance`, { waiverVersionId: v1.id });
    expect(stale.status).toBe(409);
    expect(stale.body.error.code).toBe('WAIVER_OUTDATED');
    const again = await w.api('front', 'POST', `/sessions/${s.body.id}/start`, {});
    expect(again.body.error.code).toBe('WAIVER_REQUIRED'); // accepted v1, but v2 is current
    await acceptWaiver(w, c.id);
    expect((await w.api('front', 'POST', `/sessions/${s.body.id}/start`, {})).status).toBe(200);
    // both acceptances are retained, each bound to its own version; old text is untouched
    const acc = (await pool.query(`SELECT wv.version FROM waiver_acceptances wa JOIN waiver_versions wv ON wv.id=wa.waiver_version_id WHERE wa.customer_id=$1 ORDER BY wv.version`, [c.id])).rows;
    expect(acc.map((r) => r.version)).toEqual([1, 2]);
    await expect(pool.query(`UPDATE waiver_versions SET body='tampered' WHERE version=1 AND venue_id=$1`, [w.venueId])).rejects.toThrow(/immutable/);
    await expect(pool.query(`DELETE FROM waiver_versions WHERE venue_id=$1`, [w.venueId])).rejects.toThrow();
  });

  it('minors need guardian details; the workflow is enforced server-side', async () => {
    const c = await registerCustomer(w, 'front', { fullName: 'Young Skater', dateOfBirth: '2016-05-01', emergencyContact: { name: 'Mom', phone: '0911223344', isGuardian: true } });
    const profile = await w.api('front', 'GET', `/customers/${c.id}`);
    expect(profile.body.isMinor).toBe(true);
    expect(profile.body.emergencyContacts[0].isGuardian).toBe(true);
    const noGuardian = await w.api('front', 'POST', `/customers/${c.id}/waiver-acceptance`, {});
    expect(noGuardian.status).toBe(422);
    expect(noGuardian.body.error.code).toBe('GUARDIAN_REQUIRED');
    const ok = await w.api('front', 'POST', `/customers/${c.id}/waiver-acceptance`, { guardianName: 'Mulu Bekele', guardianPhone: '0911223344', signatureData: 'data:image/png;base64,AAAA' });
    expect(ok.status).toBe(201);
    const row = (await pool.query('SELECT for_minor, guardian_name, accepted_by_staff, device_id FROM waiver_acceptances WHERE id=$1', [ok.body.id])).rows[0];
    expect(row).toMatchObject({ for_minor: true, guardian_name: 'Mulu Bekele', accepted_by_staff: w.userIds.front_desk, device_id: w.deviceIds.front });
    // child price list applies
    await w.api('owner', 'POST', '/pricing', { kind: 'SESSION', name: 'Child 60', durationMinutes: 60, priceMinor: 15000, customerType: 'CHILD' });
    const prods = await w.api('front', 'GET', `/products?customerId=${c.id}`);
    expect(prods.body.sessions.some((p: any) => p.name === 'Child 60')).toBe(true);
    const adult = await registerCustomer(w);
    expect((await w.api('front', 'GET', `/products?customerId=${adult.id}`)).body.sessions.some((p: any) => p.name === 'Child 60')).toBe(false);
  });

  it('waiver requirement is a venue setting', async () => {
    const w2 = await makeWorld();
    await w2.api('owner', 'PUT', '/settings', { waiverRequired: false });
    const c = await registerCustomer(w2);
    const v = await w2.api('front', 'POST', '/visits', { customerId: c.id });
    const s = await w2.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: await productId(w2, 30) });
    await w2.api('front', 'POST', '/payments', { sessionId: s.body.id, amountMinor: 10000, method: 'CASH' });
    expect((await w2.api('front', 'POST', `/sessions/${s.body.id}/start`, {})).status).toBe(200);
  });
});

describe('pricing, capacity and settings', () => {
  it('prices are configurable, audited, and never rewrite existing sessions', async () => {
    const r = await readySession(w, { minutes: 90 });
    const rule = (await pool.query(`SELECT id FROM pricing_rules WHERE venue_id=$1 AND duration_minutes=90 AND kind='SESSION'`, [w.venueId])).rows[0].id;
    expect((await w.api('manager', 'PATCH', `/pricing/${rule}`, { priceMinor: 1 })).status).toBe(403); // managers cannot change pricing
    const up = await w.api('owner', 'PATCH', `/pricing/${rule}`, { priceMinor: 30000 });
    expect(up.body.priceMinor).toBe(30000);
    expect((await pool.query('SELECT price_minor FROM sessions WHERE id=$1', [r.sessionId])).rows[0].price_minor).toBe(28000);
    const au = (await pool.query(`SELECT before_data, after_data, actor_user_id FROM audit_logs WHERE entity_id=$1 AND action='pricing.changed'`, [rule])).rows[0];
    expect(au.before_data.priceMinor).toBe(28000);
    expect(au.after_data.priceMinor).toBe(30000);
    expect(au.actor_user_id).toBe(w.userIds.owner);
    await w.api('owner', 'PATCH', `/pricing/${rule}`, { active: false });
    const prods = await w.api('front', 'GET', '/products');
    expect(prods.body.sessions.some((p: any) => p.id === rule)).toBe(false);
    const c = await registerCustomer(w);
    const v = await w.api('front', 'POST', '/visits', { customerId: c.id });
    expect((await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: rule })).status).toBe(422);
  });

  it('weekend / holiday pricing rules apply by venue-local date', async () => {
    const w2 = await makeWorld();
    await w2.api('owner', 'POST', '/pricing', { kind: 'SESSION', name: 'Weekend 60', durationMinutes: 60, priceMinor: 25000, dayType: 'WEEKEND' });
    await pool.query(`UPDATE auth_sessions SET expires_at = now() + interval '30 days' WHERE venue_id=$1`, [w2.venueId]);
    clock.freeze('2026-10-03T10:00:00Z'); // Saturday in Addis
    const sat = await w2.api('front', 'GET', '/products');
    expect(sat.body.sessions.some((p: any) => p.name === 'Weekend 60')).toBe(true);
    clock.freeze('2026-10-01T10:00:00Z'); // Thursday
    const thu = await w2.api('front', 'GET', '/products');
    expect(thu.body.sessions.some((p: any) => p.name === 'Weekend 60')).toBe(false);
  });

  it('capacity changes are audited and take effect on the backend immediately', async () => {
    const w2 = await makeWorld({ capacity: 1 });
    const a = await readySession(w2), b = await readySession(w2);
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/start`, {});
    expect((await w2.api('front', 'POST', `/sessions/${b.sessionId}/start`, {})).body.error.code).toBe('VENUE_FULL');
    expect((await w2.api('front', 'PUT', '/capacity', { maxCapacity: 5 })).status).toBe(403);
    expect((await w2.api('owner', 'PUT', '/capacity', { maxCapacity: 5, reason: 'Opened second rink' })).status).toBe(200);
    expect((await w2.api('front', 'POST', `/sessions/${b.sessionId}/start`, {})).status).toBe(200);
    const au = (await pool.query(`SELECT before_data, after_data, reason FROM audit_logs WHERE venue_id=$1 AND action='capacity.changed'`, [w2.venueId])).rows[0];
    expect(au.before_data.maxCapacity).toBe(1);
    expect(au.after_data.maxCapacity).toBe(5);
    expect(au.reason).toBe('Opened second rink');
  });

  it('settings changes are validated and audited with before/after', async () => {
    const bad = await w.api('owner', 'PUT', '/settings', { warnings: [{ minutes: 0, level: 'PURPLE' }] });
    expect(bad.status).toBe(422);
    expect((await w.api('owner', 'PUT', '/settings', { notASetting: 1 })).status).toBe(422);
    const ok = await w.api('owner', 'PUT', '/settings', { extensionOptionsMinutes: [10, 20], earlyExitGraceSeconds: 30 });
    expect(ok.body.settings.extensionOptionsMinutes).toEqual([10, 20]);
    const au = (await pool.query(`SELECT before_data, after_data FROM audit_logs WHERE venue_id=$1 AND action='settings.changed' ORDER BY id DESC LIMIT 1`, [w.venueId])).rows[0];
    expect(au.before_data.extensionOptionsMinutes).toEqual([15, 30, 60]);
    expect(au.after_data.extensionOptionsMinutes).toEqual([10, 20]);
    await w.api('owner', 'PUT', '/settings', { extensionOptionsMinutes: [15, 30, 60], earlyExitGraceSeconds: 60 });
  });

  it('operating hours and wristbands are enforced when configured', async () => {
    const w2 = await makeWorld();
    await w2.api('owner', 'PUT', '/settings', { enforceOperatingHours: true, wristbands: { enabled: true, colors: ['BLUE', 'GREEN'] } });
    clock.freeze('2026-09-30T02:00:00Z'); // 05:00 local: closed
    const a = await readySession(w2);
    const closed = await w2.api('front', 'POST', `/sessions/${a.sessionId}/start`, {});
    expect(closed.body.error.code).toBe('VENUE_CLOSED');
    clock.freeze('2026-09-30T10:00:00Z'); // 13:00 local: open
    const ok = await w2.api('front', 'POST', `/sessions/${a.sessionId}/start`, { wristband: 'BLUE' });
    expect(ok.status).toBe(200);
    expect(ok.body.wristband).toBe('BLUE');
    const w3 = await makeWorld();
    const b = await readySession(w3);
    expect((await w3.api('front', 'POST', `/sessions/${b.sessionId}/start`, { wristband: 'BLUE' })).body.error.code).toBe('WRISTBANDS_DISABLED');
  });

  it('devices: register, record in audit/events, disabled devices are not attributed', async () => {
    const d = await w.api('manager', 'POST', '/devices', { name: 'TEST-TABLET-9', deviceType: 'FRONT_DESK' });
    expect(d.status).toBe(201);
    expect((await w.api('front', 'POST', '/devices', { name: 'X-1', deviceType: 'OTHER' })).status).toBe(403);
    const me = await w.api('front', 'GET', '/auth/me', undefined, { 'x-device-id': d.body.id });
    expect(me.body.deviceId).toBe(d.body.id);
    await w.api('manager', 'PATCH', `/devices/${d.body.id}`, { status: 'DISABLED' });
    const me2 = await w.api('front', 'GET', '/auth/me', undefined, { 'x-device-id': d.body.id });
    expect(me2.body.deviceId).not.toBe(d.body.id);
    const other = await makeWorld();
    const foreign = await w.api('front', 'GET', '/auth/me', undefined, { 'x-device-id': other.deviceIds.front });
    expect(foreign.body.deviceId).not.toBe(other.deviceIds.front);
  });
});
