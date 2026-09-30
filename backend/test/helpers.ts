import { randomUUID, createHash } from 'node:crypto';
import { deflateSync, crc32 } from 'node:zlib';
import type { FastifyInstance } from 'fastify';
import { buildApp, type BuiltApp } from '../src/app.js';
import { pool } from '../src/db.js';
import { createVenue, createUser } from '../src/bootstrap.js';
import { clock } from '../src/shared/clock.js';

export const PASSWORD = 'Passw0rd!Passw0rd';

export interface World {
  built: BuiltApp;
  app: FastifyInstance;
  venueId: string;
  tokens: Record<string, string>;
  userIds: Record<string, string>;
  deviceIds: Record<string, string>;
  api: (who: string, method: string, url: string, body?: unknown, headers?: Record<string, string>) => Promise<{ status: number; body: any; headers: Record<string, any>; raw: Buffer }>;
  close: () => Promise<void>;
}

let appSingleton: BuiltApp | null = null;
export async function getApp() {
  if (!appSingleton) appSingleton = await buildApp({ embeddedWorker: false });
  return appSingleton;
}

export async function makeWorld(opts: { capacity?: number; name?: string } = {}): Promise<World> {
  const built = await getApp();
  const app = built.app;
  const slug = 'v-' + randomUUID().slice(0, 8);
  const venueId = await createVenue(pool, { name: opts.name ?? 'Test Venue ' + slug, slug, capacity: opts.capacity ?? 60 });
  const roles = ['OWNER', 'MANAGER', 'SUPERVISOR', 'FRONT_DESK', 'RENTAL_STAFF'];
  const userIds: Record<string, string> = {};
  const tokens: Record<string, string> = {};
  const deviceIds: Record<string, string> = {};
  for (const r of roles) {
    const key = r.toLowerCase();
    userIds[key] = await createUser(pool, venueId, { email: `${key}@${slug}.test`, fullName: `${r} User`, password: PASSWORD, roleCode: r });
  }
  for (const [key, name, type] of [['front', 'FRONT-DESK-01', 'FRONT_DESK'], ['rental', 'RENTAL-DESK-01', 'RENTAL_DESK'], ['manager', 'MANAGER-TABLET-01', 'MANAGER']]) {
    deviceIds[key] = (await pool.query(`INSERT INTO devices (venue_id, name, device_type) VALUES ($1,$2,$3) RETURNING id`, [venueId, name, type])).rows[0].id;
  }
  const deviceFor: Record<string, string> = { front_desk: deviceIds.front, rental_staff: deviceIds.rental, manager: deviceIds.manager };
  for (const r of roles) {
    const key = r.toLowerCase();
    const res = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: `${key}@${slug}.test`, password: PASSWORD, deviceId: deviceFor[key] } });
    if (res.statusCode !== 200) throw new Error('login failed in test setup: ' + res.body);
    tokens[key] = res.json().token;
  }
  tokens.front = tokens.front_desk; tokens.rental = tokens.rental_staff;
  userIds.front = userIds.front_desk; userIds.rental = userIds.rental_staff;
  const api: World['api'] = async (who, method, url, body, headers = {}) => {
    const h: Record<string, string> = { ...headers };
    if (tokens[who] || who.length > 30) h.authorization = `Bearer ${tokens[who] ?? who}`;
    if (method !== 'GET' && !h['idempotency-key'] && !h['no-idem']) h['idempotency-key'] = randomUUID();
    delete h['no-idem'];
    let payload: any = body;
    if (Buffer.isBuffer(body)) { h['content-type'] = h['content-type'] ?? 'image/png'; }
    const res = await app.inject({ method: method as any, url: '/api/v1' + url, headers: h, payload });
    let parsed: any = null;
    try { parsed = res.json(); } catch { /* binary */ }
    return { status: res.statusCode, body: parsed, headers: res.headers, raw: res.rawPayload };
  };
  return { built, app, venueId, tokens, userIds, deviceIds, api, close: async () => {} };
}

// ---- domain helpers used across tests ----
export async function registerCustomer(w: World, who = 'front', over: Record<string, unknown> = {}) {
  const phone = over.phone ?? '09' + String(Math.floor(10000000 + Math.random() * 89999999));
  const r = await w.api(who, 'POST', '/customers', { fullName: 'Abebe Kebede', phone, ...over });
  if (r.status !== 201) throw new Error('registerCustomer failed: ' + JSON.stringify(r.body));
  return { id: r.body.id as string, phone: r.body.phone as string };
}
export async function acceptWaiver(w: World, customerId: string, who = 'front', visitId?: string) {
  const r = await w.api(who, 'POST', `/customers/${customerId}/waiver-acceptance`, { visitId, guardianName: 'Guardian', guardianPhone: '0911111111' });
  if (r.status !== 201) throw new Error('waiver failed: ' + JSON.stringify(r.body));
}
export async function productId(w: World, minutes = 60) {
  const r = await pool.query(`SELECT id FROM pricing_rules WHERE venue_id=$1 AND kind='SESSION' AND duration_minutes=$2`, [w.venueId, minutes]);
  return r.rows[0].id as string;
}

/** Full check-in up to READY (paid, waiver accepted) */
export async function readySession(w: World, opts: { minutes?: number; who?: string; customerId?: string; method?: string; customerOver?: Record<string, unknown> } = {}) {
  const who = opts.who ?? 'front';
  const customerId = opts.customerId ?? (await registerCustomer(w, who, opts.customerOver)).id;
  await acceptWaiver(w, customerId, who);
  const v = await w.api(who, 'POST', '/visits', { customerId });
  if (v.status !== 201) throw new Error('visit failed ' + JSON.stringify(v.body));
  const s = await w.api(who, 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: await productId(w, opts.minutes ?? 60) });
  if (s.status !== 201) throw new Error('session failed ' + JSON.stringify(s.body));
  const sess = s.body;
  const p = await w.api(who, 'POST', '/payments', { sessionId: sess.id, amountMinor: sess.priceMinor - sess.discountMinor, method: opts.method ?? 'CASH' });
  if (p.status !== 201) throw new Error('payment failed ' + JSON.stringify(p.body));
  return { customerId, visitId: v.body.id as string, sessionId: sess.id as string, paymentId: p.body.id as string, priceMinor: sess.priceMinor as number };
}

export async function activeSession(w: World, opts: Parameters<typeof readySession>[1] & { equipmentIds?: string[] } = {}) {
  const r = await readySession(w, opts);
  const st = await w.api(opts.who ?? 'front', 'POST', `/sessions/${r.sessionId}/start`, { equipmentIds: opts.equipmentIds });
  if (st.status !== 200) throw new Error('start failed ' + JSON.stringify(st.body));
  return { ...r, started: st.body };
}

export async function addSkates(w: World, n: number, prefix = 'SKATE') {
  const ids: string[] = [];
  for (let i = 1; i <= n; i++) {
    const r = await w.api('manager', 'POST', '/equipment', { code: `${prefix}-${String(i).padStart(3, '0')}`, size: String(36 + (i % 10)) });
    if (r.status === 403) { // managers lack equipment.manage? they have it; fall back to owner
      const o = await w.api('owner', 'POST', '/equipment', { code: `${prefix}-${String(i).padStart(3, '0')}` });
      ids.push(o.body.id);
    } else ids.push(r.body.id);
  }
  return ids;
}

// ---- image fixtures ----
function pngChunk(type: string, data: Buffer) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td) >>> 0);
  return Buffer.concat([len, td, crc]);
}
export function makePng(w = 128, h = 128, extraChunks: Buffer[] = []) {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc((w * 3 + 1) * h, 0x7f);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), pngChunk('IHDR', ihdr), ...extraChunks, pngChunk('IDAT', deflateSync(raw)), pngChunk('IEND', Buffer.alloc(0))]);
}
/** Header-valid JPEG (SOI, optional EXIF APP1, SOF0, SOS, EOI). Enough for header validation. */
export function makeJpeg(w = 128, h = 128, withExif = false) {
  const soi = Buffer.from([0xff, 0xd8]);
  const exifBody = Buffer.from('Exif\0\0GPSLatitude=9.03,GPSLongitude=38.74');
  const app1 = withExif ? Buffer.concat([Buffer.from([0xff, 0xe1]), Buffer.from([(exifBody.length + 2) >> 8, (exifBody.length + 2) & 0xff]), exifBody]) : Buffer.alloc(0);
  const sof = Buffer.from([0xff, 0xc0, 0x00, 0x0b, 0x08, h >> 8, h & 0xff, w >> 8, w & 0xff, 0x01, 0x01, 0x11, 0x00]);
  const sos = Buffer.from([0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0x11, 0x22, 0x33]);
  return Buffer.concat([soi, app1, sof, sos, Buffer.from([0xff, 0xd9])]);
}
export const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
export { clock };

import { processOutbox } from '../src/worker/outbox.js';
/** Drain the outbox like the real worker loop does. */
export async function drainOutbox() {
  let total = 0, n;
  do { n = await processOutbox(); total += n; } while (n >= 50);
  return total;
}
