/**
 * Demo data. Everything here is clearly fake ("Demo ..." names, 0911-000-xxx phone numbers, *.demo e-mail).
 * Data is created through the real service layer so events, audit rows and outbox entries are genuine.
 */
import { pool, withTx, closePool, one } from './db.js';
import { migrate } from './migrate.js';
import { ensurePermissions, createVenue, createUser } from './bootstrap.js';
import type { Ctx } from './shared/ctx.js';
import type { AuthUser } from './auth/service.js';
import { createCustomer } from './modules/customers.js';
import { acceptWaiver } from './modules/waivers.js';
import { createVisit } from './modules/visits.js';
import { createSession, startSession, endSession, pauseSession, cancelSession, extendSession, processSessionTimers } from './modules/sessions.js';
import { recordPayment, refundPayment } from './modules/payments.js';
import { createEquipment, assignEquipment, returnEquipment, reportDamage, markOutOfService } from './modules/equipment.js';
import { createIncident, transitionIncident } from './modules/incidents.js';
import { storeCustomerPhoto } from './modules/photos.js';
import { updateSettings, registerDevice } from './modules/admin.js';
import { closeDay } from './modules/dayclose.js';
import { demoAvatarPng } from './storage/demoimage.js';
import { localDateIn, addDaysToDate } from './shared/time.js';

const PASSWORD = process.env.DEMO_PASSWORD ?? 'LightSkate-Demo-2026!';
const SLUG = 'light-skate-demo';

async function loadAuth(userId: string, deviceId: string | null): Promise<AuthUser> {
  const r = await one<any>(pool, `SELECT u.id, u.venue_id, u.email, u.full_name, u.role_id, r.code AS role_code,
      COALESCE((SELECT array_agg(permission_code) FROM role_permissions WHERE role_id=u.role_id),'{}') AS perms
      FROM users u JOIN roles r ON r.id=u.role_id WHERE u.id=$1`, [userId]);
  return { id: r.id, venueId: r.venue_id, email: r.email, fullName: r.full_name, roleId: r.role_id, roleCode: r.role_code, permissions: new Set<string>(r.perms), deviceId, authSessionId: 'seed' };
}

async function main() {
  await migrate();
  await ensurePermissions(pool);
  if (await one(pool, 'SELECT 1 FROM venues WHERE slug=$1', [SLUG])) {
    console.log(`Demo venue "${SLUG}" already exists — nothing to do. (Drop the database to re-seed.)`);
    return;
  }
  const venueId = await createVenue(pool, { name: 'Light Skate Demo Venue', slug: SLUG, capacity: 60 });
  const staffDefs = [
    ['owner', 'Demo Owner', 'OWNER'], ['manager', 'Demo Manager (Hana)', 'MANAGER'], ['supervisor', 'Demo Supervisor', 'SUPERVISOR'],
    ['frontdesk', 'Demo Front Desk (Dawit)', 'FRONT_DESK'], ['rental', 'Demo Rental Staff (Sara)', 'RENTAL_STAFF'],
  ] as const;
  const uid: Record<string, string> = {};
  for (const [k, name, role] of staffDefs) uid[k] = await createUser(pool, venueId, { email: `${k}@lightskate.demo`, fullName: name, password: PASSWORD, roleCode: role });

  const dev: Record<string, string> = {};
  const auth: Record<string, AuthUser> = {};
  async function run<T>(who: string, at: Date, fn: (ctx: Ctx) => Promise<T>, deviceKey?: string): Promise<T> {
    const a = auth[who] ?? (auth[who] = await loadAuth(uid[who], null));
    return withTx((db) => fn({ db, user: { ...a, deviceId: deviceKey ? dev[deviceKey] : null }, venueId, deviceId: deviceKey ? dev[deviceKey] : null, requestId: 'seed', ip: null, now: at }));
  }
  const now = new Date();
  const ago = (min: number) => new Date(now.getTime() - min * 60_000);
  const plus = (d: Date, min: number) => new Date(d.getTime() + min * 60_000);

  for (const [key, name, type] of [['front', 'FRONT-DESK-01', 'FRONT_DESK'], ['rental', 'RENTAL-DESK-01', 'RENTAL_DESK'], ['mgr', 'MANAGER-TABLET-01', 'MANAGER']] as const) {
    dev[key] = (await run('owner', ago(600), (c) => registerDevice(c, { name, deviceType: type }))).id;
  }
  await run('owner', ago(600), (c) => updateSettings(c, { emergency: {
    ambulance: '907', police: '991', fire: '939', venueContact: '+251 11 000 0000 (Demo)', manager: '+251 91 100 0000 (Demo Manager)',
    address: 'Demo Venue, Bole, Addis Ababa (fictional address)', firstAid: 'First-aid kit: under the front counter. Trained first-aider on shift: Demo Manager.' } }));

  // ---- equipment: 36 skates
  const skates: { id: string; code: string }[] = [];
  for (let i = 1; i <= 36; i++) {
    const code = `SKATE-${String(i).padStart(3, '0')}`;
    const e = await run('owner', ago(600), (c) => createEquipment(c, { code, size: String(33 + (i % 12)), condition: i % 9 === 0 ? 'FAIR' : 'GOOD', location: 'Rental counter' }));
    skates.push({ id: e.id, code });
  }
  const skate = (n: number) => skates[n - 1].id;

  // ---- customers
  const people = [
    ['Demo Abebe Kebede', '0911000001'], ['Demo Hana Tesfaye', '0911000002'], ['Demo Dawit Tadesse', '0911000003'], ['Demo Sara Alemu', '0911000004'],
    ['Demo Tigist Haile', '0911000005'], ['Demo Yonas Bekele', '0911000006'], ['Demo Meron Girma', '0911000007'], ['Demo Kaleb Mulugeta', '0911000008'],
    ['Demo Selam Desta', '0911000009'], ['Demo Biruk Fikre', '0911000010'], ['Demo Liya Assefa', '0911000011', '2015-06-12'], ['Demo Nahom Tsegaye', '0911000012', '2014-02-03'],
  ] as const;
  const cust: string[] = [];
  for (let i = 0; i < people.length; i++) {
    const [fullName, phone, dob] = people[i] as any;
    const c = await run('frontdesk', ago(60 * 24 * 14), (ctx) => createCustomer(ctx, { fullName, phone, dateOfBirth: dob, emergencyContact: { name: `Demo Guardian of ${fullName.replace('Demo ', '')}`, phone: '0911999000', relationship: dob ? 'Parent' : 'Friend', isGuardian: !!dob } }), 'front');
    cust.push(c.id);
    await run('frontdesk', ago(60 * 24 * 14), (ctx) => storeCustomerPhoto(ctx, { customerId: c.id, purpose: 'PROFILE', bytes: demoAvatarPng((i * 31) % 360) }, { keys: [] }), 'front');
    await run('frontdesk', ago(60 * 24 * 14), (ctx) => acceptWaiver(ctx, c.id, dob ? { guardianName: 'Demo Guardian', guardianPhone: '0911999000', signatureData: null } : {}), 'front');
  }

  const products = Object.fromEntries((await pool.query(`SELECT duration_minutes d, id FROM pricing_rules WHERE venue_id=$1 AND kind='SESSION'`, [venueId])).rows.map((r) => [r.d, r.id]));
  const methods: [string, string | null][] = [['CASH', null], ['TELEBIRR', 'TB-'], ['BANK_TRANSFER', 'CBE-'], ['CARD', 'POS-'], ['CASH', null]];
  let refSeq = 1000;

  /** create visit+session+payment at `at`, optionally start. Returns ids. */
  async function checkIn(i: number, minutes: number, at: Date, opts: { start?: boolean; pay?: boolean | 'partial'; method?: number; equip?: number[]; by?: string } = {}) {
    const by = opts.by ?? 'frontdesk';
    const cid = cust[i];
    const visit = await run(by, at, (c) => createVisit(c, { customerId: cid }), 'front');
    const s = await run(by, at, (c) => createSession(c, { visitId: visit.id, pricingRuleId: products[minutes] }), 'front');
    let payment: any = null;
    if (opts.pay !== false) {
      const [method, prefix] = methods[opts.method ?? i % methods.length];
      const amount = opts.pay === 'partial' ? Math.floor(s.priceMinor / 2) : s.priceMinor;
      payment = await run(by, plus(at, 0.5), (c) => recordPayment(c, { sessionId: s.id, amountMinor: amount, method, reference: prefix ? prefix + ++refSeq : null }), 'front');
    }
    if (opts.start) await run(by, plus(at, 1), (c) => startSession(c, s.id, { equipmentIds: opts.equip?.map(skate) }), 'front');
    return { visitId: visit.id, sessionId: s.id as string, paymentId: payment?.id as string | undefined, customerId: cid };
  }

  // ---- history: previous 6 days
  let n = 0;
  for (let day = 6; day >= 1; day--) {
    const count = 4 + ((day * 3) % 5);
    for (let k = 0; k < count; k++) {
      const minutes = [30, 60, 60, 90, 120][k % 5];
      const at = new Date(now.getTime() - day * 86400_000);
      at.setUTCHours(13 + (k % 6), (k * 11) % 60, 0, 0); // 16:00–21:00 Addis
      const i = (n++) % cust.length;
      const r = await checkIn(i, minutes, at, { start: true, method: n % 5, equip: [((n * 7) % 30) + 1] });
      const end = plus(at, 1 + minutes - (k % 4 === 0 ? 12 : 0) + (k % 5 === 1 ? 4 : 0));
      await run('frontdesk', end, (c) => endSession(c, r.sessionId), 'front');
      await run('rental', plus(end, 1), (c) => returnEquipment(c, skate(((n * 7) % 30) + 1), { condition: 'GOOD' }), 'rental');
    }
  }
  // close the day before yesterday through the real workflow
  const tz = 'Africa/Addis_Ababa';
  const twoDaysAgo = addDaysToDate(localDateIn(tz, now), -2);
  const prev = await run('manager', ago(60), async (c) => (await import('./modules/dayclose.js')).dayClosePreview(c, twoDaysAgo), 'mgr');
  await run('manager', ago(59), (c) => closeDay(c, { date: twoDaysAgo, countedCashMinor: prev.expectedCashMinor, notes: 'Demo close' }), 'mgr');

  // ---- today: completed sessions
  const done1 = await checkIn(0, 60, ago(200), { start: true, method: 0, equip: [31] });
  await run('frontdesk', ago(139), (c) => endSession(c, done1.sessionId), 'front');
  await run('rental', ago(137), (c) => returnEquipment(c, skate(31), { condition: 'GOOD' }), 'rental');
  const done2 = await checkIn(1, 30, ago(150), { start: true, method: 1, equip: [32] });
  await run('frontdesk', ago(118), (c) => endSession(c, done2.sessionId), 'front');
  await run('rental', ago(117), (c) => returnEquipment(c, skate(32), { condition: 'DAMAGED', note: 'Broken front wheel' }), 'rental');
  await run('manager', ago(100), (c) => reportDamage(c, skate(33), { issue: 'Cracked heel cup', startMaintenance: true }), 'mgr');
  await run('manager', ago(100), (c) => markOutOfService(c, skate(34), { reason: 'Frame unsafe — pending replacement' }), 'mgr');
  const done3 = await checkIn(2, 90, ago(170), { start: true, method: 2, equip: [35] });
  await run('frontdesk', ago(155), (c) => extendSession(c, done3.sessionId, { minutes: 30, payment: { method: 'CASH' } }), 'front');
  await run('frontdesk', ago(45), (c) => endSession(c, done3.sessionId), 'front');
  await run('rental', ago(44), (c) => returnEquipment(c, skate(35), { condition: 'GOOD' }), 'rental');
  const refunded = await checkIn(3, 60, ago(95), { start: true, method: 0 });
  await run('frontdesk', ago(60), (c) => endSession(c, refunded.sessionId), 'front');
  await run('manager', ago(58), (c) => refundPayment(c, refunded.paymentId!, { amountMinor: 5000, reason: 'Left early — partial refund (demo)' }), 'mgr');

  // ---- today: cancelled + waiting
  const cancelled = await checkIn(4, 60, ago(80), {});
  await run('frontdesk', ago(78), (c) => cancelSession(c, cancelled.sessionId, { reason: 'Customer changed their mind' }), 'front');

  // ---- on the floor right now
  const live: Record<string, Awaited<ReturnType<typeof checkIn>>> = {};
  live.a1 = await checkIn(5, 60, ago(12), { start: true, method: 0, equip: [1] });      // normal
  live.a2 = await checkIn(6, 30, ago(25), { start: true, method: 1, equip: [2] });      // 5 min left -> expiring
  live.a3 = await checkIn(7, 60, ago(35), { start: true, method: 3, equip: [3] });      // normal
  live.a4 = await checkIn(8, 60, ago(52), { start: true, method: 2, equip: [4] });      // expiring
  live.a5 = await checkIn(9, 60, ago(68), { start: true, method: 0, equip: [5] });      // expired (overtime)
  live.a6 = await checkIn(10, 90, ago(20), { start: true, method: 0, equip: [6] });     // paused
  await run('frontdesk', ago(5), (c) => pauseSession(c, live.a6.sessionId, { reason: 'Bathroom break' }), 'front');
  // waiting / awaiting payment
  await checkIn(11, 60, ago(3), { pay: true });
  await checkIn(0, 30, ago(2), { pay: 'partial' });
  await processSessionTimers(venueId, now);

  // ---- incidents
  const inc1 = await run('frontdesk', ago(40), (c) => createIncident(c, { sessionId: live.a3.sessionId, incidentType: 'Fall', severity: 'MINOR', location: 'Main rink', description: 'Demo: skater slipped near the entrance, no injury.', actionTaken: 'Helped up, checked for injury', managerNotified: false }), 'front');
  await run('manager', ago(35), (c) => transitionIncident(c, inc1.id, { to: 'ACKNOWLEDGED' }), 'mgr');
  await run('manager', ago(30), (c) => transitionIncident(c, inc1.id, { to: 'CLOSED', note: 'No follow-up needed.' }), 'mgr');
  await run('rental', ago(15), (c) => createIncident(c, { incidentType: 'Equipment', severity: 'MODERATE', location: 'Rental counter', description: 'Demo: skate SKATE-033 heel cup cracked while being fitted.', actionTaken: 'Removed from service', managerNotified: true }), 'rental');
  // visit photos for people on the floor (shows the photo-on-card workflow)
  for (const [k, key] of [[5, 'a1'], [6, 'a2'], [7, 'a3'], [8, 'a4'], [9, 'a5'], [10, 'a6']] as const) {
    await run('frontdesk', ago(10), (c) => storeCustomerPhoto(c, { customerId: cust[k], visitId: live[key].visitId, purpose: 'VISIT', bytes: demoAvatarPng((k * 47 + 20) % 360) }, { keys: [] }), 'front');
  }

  console.log('\nDemo venue ready.');
  console.log('Sign in at http://localhost:8080 with (password for all: ' + PASSWORD + '):');
  for (const [k, name, role] of staffDefs) console.log(`  ${k}@lightskate.demo   ${role.padEnd(12)} ${name}`);
  console.log('\nThe demo covers: 6 people on the floor (normal / expiring / expired / paused), 2 waiting, 1 cancelled,');
  console.log('completed sessions today + 6 days of history, rentals out, a damaged + an out-of-service skate, 2 incidents, a partial refund, a closed day.');
}

main().catch((e) => { console.error(e); process.exitCode = 1; }).finally(closePool);
