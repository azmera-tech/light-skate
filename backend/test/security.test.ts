import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { pool } from '../src/db.js';
import { makeWorld, registerCustomer, readySession, activeSession, makePng, makeJpeg, sha, PASSWORD, type World } from './helpers.js';
import { setRateLimitEnabled } from '../src/shared/ratelimit.js';
import { createUser } from '../src/bootstrap.js';
import { runRetention } from '../src/worker/index.js';
import { storage } from '../src/storage/index.js';
import { validateImage } from '../src/storage/image.js';

let w: World, other: World;
beforeAll(async () => { w = await makeWorld(); other = await makeWorld(); });
afterAll(() => setRateLimitEnabled(false));

describe('authentication', () => {
  it('rejects missing, malformed and unknown tokens', async () => {
    for (const path of ['/dashboard', '/customers', '/sessions', '/payments', '/equipment', '/audit', '/settings', '/staff', '/reports/daily']) {
      expect((await w.api('nobody-token-that-is-not-valid-at-all-000000', 'GET', path)).status).toBe(401);
      const r = await w.app.inject({ method: 'GET', url: '/api/v1' + path });
      expect(r.statusCode).toBe(401);
    }
    const bad = await w.app.inject({ method: 'GET', url: '/api/v1/dashboard', headers: { authorization: 'Basic abc' } });
    expect(bad.statusCode).toBe(401);
  });

  it('does not reveal whether an email exists; locks the account after repeated failures', async () => {
    const email = `front_desk@${(await pool.query('SELECT slug FROM venues WHERE id=$1', [w.venueId])).rows[0].slug}.test`;
    const wrong = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email, password: 'wrong-password-1' } });
    const ghost = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: 'ghost@nowhere.test', password: 'wrong-password-1' } });
    expect(wrong.statusCode).toBe(401);
    expect(ghost.statusCode).toBe(401);
    expect(wrong.json().error.message).toBe(ghost.json().error.message);
    for (let i = 0; i < 5; i++) await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email, password: 'wrong-password-' + i } });
    const locked = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email, password: PASSWORD } });
    expect(locked.statusCode).toBe(423);
    await pool.query(`UPDATE users SET locked_until=NULL, failed_login_count=0 WHERE lower(email)=lower($1)`, [email]);
    const ok = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email, password: PASSWORD } });
    expect(ok.statusCode).toBe(200);
  });

  it('rate limits login attempts', async () => {
    setRateLimitEnabled(true);
    try {
      const codes: number[] = [];
      for (let i = 0; i < 12; i++) codes.push((await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: 'rl@x.test', password: 'nope-nope-nope' } })).statusCode);
      expect(codes).toContain(429);
    } finally { setRateLimitEnabled(false); }
  });

  it('does not store or log passwords or tokens', async () => {
    // no secret VALUE (password or raw bearer token) appears anywhere in the audit trail
    const secrets = [PASSWORD, ...Object.values(w.tokens)];
    for (const secret of secrets) {
      const r = await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE position($1 in (coalesce(before_data::text,'') || coalesce(after_data::text,'') || coalesce(reason,''))) > 0`, [secret]);
      expect(r.rows[0].n).toBe(0);
    }
    const t = await pool.query(`SELECT count(*)::int n FROM auth_sessions WHERE token_hash = $1`, [w.tokens.front]); // raw token never stored
    expect(t.rows[0].n).toBe(0);
  });

  it('disabling a user revokes their sessions immediately', async () => {
    const slug = (await pool.query('SELECT slug FROM venues WHERE id=$1', [w.venueId])).rows[0].slug;
    const id = await createUser(pool, w.venueId, { email: `temp@${slug}.test`, fullName: 'Temp', password: PASSWORD, roleCode: 'FRONT_DESK' });
    const login = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: `temp@${slug}.test`, password: PASSWORD } });
    const tok = login.json().token;
    expect((await w.api(tok, 'GET', '/dashboard')).status).toBe(200);
    // owner has staff.manage
    const d = await w.api('owner', 'PATCH', `/staff/${id}`, { status: 'DISABLED' });
    expect(d.status).toBe(200);
    expect((await w.api(tok, 'GET', '/dashboard')).status).toBe(401);
  });
});

describe('function-level authorization', () => {
  it('front desk cannot use management functions', async () => {
    const attempts: [string, string, unknown?][] = [
      ['GET', '/audit'], ['GET', '/settings'], ['PUT', '/settings', { pause: { enabled: false, countsTowardTime: false } }], ['GET', '/staff'],
      ['POST', '/staff', { email: 'x@y.test', fullName: 'X Y', password: 'Passw0rd!Passw0rd', roleId: randomUUID() }],
      ['GET', '/reports/daily'], ['PUT', '/capacity', { maxCapacity: 1 }], ['POST', '/pricing', { kind: 'SESSION', name: 'Free', durationMinutes: 60, priceMinor: 0 }],
      ['POST', '/waivers/versions', { title: 'New waiver', body: 'x'.repeat(40) }], ['GET', '/devices'], ['GET', '/day-close/preview'],
    ];
    for (const [m, p, b] of attempts) {
      const r = await w.api('front', m, p, b);
      expect(r.status, `${m} ${p}`).toBe(403);
      expect(r.body.error.message).toBeTruthy();
    }
  });

  it('rental staff cannot take payments or start sessions; front desk cannot manage maintenance', async () => {
    const r = await readySession(w);
    expect((await w.api('rental', 'POST', `/sessions/${r.sessionId}/start`, {})).status).toBe(403);
    expect((await w.api('rental', 'POST', '/payments', { sessionId: r.sessionId, amountMinor: 100, method: 'CASH' })).status).toBe(403);
    const [e] = (await w.api('owner', 'POST', '/equipment', { code: 'SEC-001' })).body.id ? [(await w.api('owner', 'POST', '/equipment', { code: 'SEC-002' })).body.id] : [];
    expect((await w.api('front', 'POST', `/equipment/${e}/damage`, { issue: 'broken wheel' })).status).toBe(403);
    expect((await w.api('rental', 'POST', `/equipment/${e}/damage`, { issue: 'broken wheel' })).status).toBe(200);
  });

  it('role claims from the client are ignored', async () => {
    const r = await w.api('front', 'POST', '/staff', { email: 'evil@x.test', fullName: 'Evil Admin', password: PASSWORD, roleId: randomUUID(), role: 'admin', permissions: ['staff.manage'] }, { 'x-role': 'OWNER', 'x-user-role': 'admin' });
    expect(r.status).toBe(403);
    const me = await w.api('front', 'GET', '/auth/me', undefined, { 'x-role': 'OWNER' });
    expect(me.body.role).toBe('FRONT_DESK');
    expect(me.body.permissions).not.toContain('staff.manage');
  });

  it('a user with staff.manage cannot grant a role more powerful than their own', async () => {
    const slug = (await pool.query('SELECT slug FROM venues WHERE id=$1', [w.venueId])).rows[0].slug;
    const role = (await pool.query(`INSERT INTO roles (venue_id, code, name, is_system) VALUES ($1,'HR','HR Lead',false) RETURNING id`, [w.venueId])).rows[0].id;
    for (const p of ['staff.manage', 'customer.read']) await pool.query('INSERT INTO role_permissions (role_id, permission_code) VALUES ($1,$2)', [role, p]);
    await createUser(pool, w.venueId, { email: `hr@${slug}.test`, fullName: 'HR Lead', password: PASSWORD, roleCode: 'HR' });
    const login = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: `hr@${slug}.test`, password: PASSWORD } });
    const hr = login.json().token;
    const ownerRole = (await pool.query(`SELECT id FROM roles WHERE venue_id=$1 AND code='OWNER'`, [w.venueId])).rows[0].id;
    const esc = await w.api(hr, 'POST', '/staff', { email: `x1@${slug}.test`, fullName: 'Sneaky Owner', password: PASSWORD, roleId: ownerRole });
    expect(esc.status).toBe(403);
    expect(esc.body.error.code).toBe('ROLE_ESCALATION');
    // nor can they take over an existing owner's account
    const ownerUser = w.userIds.owner;
    expect((await w.api(hr, 'POST', `/staff/${ownerUser}/reset-password`, { password: 'NewPassw0rd!NewPass' })).status).toBe(403);
    // nor change their own role
    const me = (await w.api(hr, 'GET', '/auth/me')).body.id;
    expect((await w.api(hr, 'PATCH', `/staff/${me}`, { roleId: ownerRole })).status).toBe(403);
    const allowed = await w.api('owner', 'POST', '/staff', { email: `ok@${slug}.test`, fullName: 'Fine Person', password: PASSWORD, roleId: ownerRole });
    expect(allowed.status).toBe(201);
    expect((await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE venue_id=$1 AND action='staff.created'`, [w.venueId])).rows[0].n).toBeGreaterThan(0);
  });

  it('weak passwords are refused for new staff', async () => {
    const role = (await pool.query(`SELECT id FROM roles WHERE venue_id=$1 AND code='FRONT_DESK'`, [w.venueId])).rows[0].id;
    const r = await w.api('owner', 'POST', '/staff', { email: 'weak@x.test', fullName: 'Weak Pw', password: 'short', roleId: role });
    expect(r.status).toBe(422);
    expect(r.body.error.code).toBe('WEAK_PASSWORD');
  });
});

describe('object-level & cross-venue authorization', () => {
  it('staff of another venue cannot read or change anything they have the id of', async () => {
    const mine = await activeSession(w);
    const eq = (await w.api('owner', 'POST', '/equipment', { code: 'XV-001' })).body.id;
    const probes: [string, string, unknown?][] = [
      ['GET', `/customers/${mine.customerId}`], ['GET', `/customers/${mine.customerId}/history`], ['GET', `/customers/${mine.customerId}/waiver`],
      ['GET', `/sessions/${mine.sessionId}`], ['GET', `/visits/${mine.visitId}`], ['GET', `/payments/${mine.paymentId}`], ['GET', `/equipment/${eq}`],
      ['POST', `/sessions/${mine.sessionId}/end`, {}], ['POST', `/sessions/${mine.sessionId}/extend`, { minutes: 15, payment: { method: 'CASH' } }],
      ['POST', `/sessions/${mine.sessionId}/pause`, {}], ['POST', `/payments/${mine.paymentId}/refund`, { reason: 'steal money' }],
      ['POST', `/equipment/${eq}/assign`, { sessionId: mine.sessionId }], ['PATCH', `/customers/${mine.customerId}`, { fullName: 'Hacked' }],
      ['POST', '/visits', { customerId: mine.customerId }], ['POST', `/customers/${mine.customerId}/erase`, { reason: 'malicious erase' }],
    ];
    for (const [m, p, b] of probes) {
      const r = await other.api('owner', m, p, b);
      expect(r.status, `${m} ${p}`).toBe(404);
    }
    const phone = (await pool.query('SELECT phone_e164 FROM customers WHERE id=$1', [mine.customerId])).rows[0].phone_e164;
    const search = await other.api('owner', 'GET', `/customers?q=${encodeURIComponent(phone)}`);
    expect(search.body.customers).toHaveLength(0);
    const dash = await other.api('owner', 'GET', '/dashboard');
    expect(dash.body.liveSessions.map((s: any) => s.id)).not.toContain(mine.sessionId);
    // and nothing was altered
    expect((await pool.query('SELECT status FROM sessions WHERE id=$1', [mine.sessionId])).rows[0].status).toBe('ACTIVE');
    expect((await pool.query('SELECT full_name FROM customers WHERE id=$1', [mine.customerId])).rows[0].full_name).not.toBe('Hacked');
  });

  it('cross-venue ids inside bodies are rejected too (session/customer/equipment mix-ups)', async () => {
    const theirs = await activeSession(other);
    const eq = (await w.api('owner', 'POST', '/equipment', { code: 'XV-002' })).body.id;
    expect((await w.api('owner', 'POST', `/equipment/${eq}/assign`, { sessionId: theirs.sessionId })).status).toBe(404);
    expect((await w.api('owner', 'POST', '/visits', { customerId: theirs.customerId })).status).toBe(404);
    expect((await w.api('owner', 'POST', '/incidents', { sessionId: theirs.sessionId, incidentType: 'Fall', severity: 'MINOR', description: 'cross venue' })).status).toBe(404);
    const pricingOther = (await pool.query(`SELECT id FROM pricing_rules WHERE venue_id=$1 LIMIT 1`, [other.venueId])).rows[0].id;
    const c = await registerCustomer(w);
    const v = await w.api('front', 'POST', '/visits', { customerId: c.id });
    expect((await w.api('front', 'POST', '/sessions', { visitId: v.body.id, pricingRuleId: pricingOther })).status).toBe(422);
  });

  it('customer search is protected, parameterised and rate limited', async () => {
    await registerCustomer(w, 'front', { fullName: "Robert'); DROP TABLE customers;--", phone: '0977000111' });
    for (const q of ["'; DROP TABLE customers; --", "' OR '1'='1", '%', '_', '\\', 'a'.repeat(200)]) {
      const r = await w.api('front', 'GET', `/customers?q=${encodeURIComponent(q)}`);
      expect([200, 400]).toContain(r.status);
    }
    expect((await pool.query('SELECT count(*)::int n FROM customers')).rows[0].n).toBeGreaterThan(0);
    const found = await w.api('front', 'GET', `/customers?q=${encodeURIComponent('Robert')}`);
    expect(found.body.customers).toHaveLength(1);
    const all = await w.api('front', 'GET', `/customers?q=${encodeURIComponent('%')}`);
    expect(all.body.customers).toHaveLength(0); // % is a literal, not a wildcard
    expect((await w.app.inject({ method: 'GET', url: '/api/v1/customers?q=abc' })).statusCode).toBe(401);
    setRateLimitEnabled(true);
    try {
      const codes: number[] = [];
      for (let i = 0; i < 130; i++) codes.push((await w.api('front', 'GET', '/customers?q=abebe')).status);
      expect(codes).toContain(429);
    } finally { setRateLimitEnabled(false); }
  });

  it('incident details are redacted for ordinary staff; managers see everything', async () => {
    const a = await activeSession(w);
    const created = await w.api('front', 'POST', '/incidents', { sessionId: a.sessionId, incidentType: 'Fall', severity: 'MODERATE', description: 'Fell near the entrance, wrist pain', location: 'Main rink' });
    expect(created.status).toBe(201);
    const mineList = await w.api('front', 'GET', '/incidents');
    expect(mineList.body.redacted).toBe(true);
    expect(mineList.body.incidents[0].description).toBeUndefined();
    expect(mineList.body.incidents[0].customerName).toBeUndefined();
    const mineOne = await w.api('front', 'GET', `/incidents/${created.body.id}`);
    expect(mineOne.body.redacted).toBe(true);
    expect(JSON.stringify(mineOne.body)).not.toMatch(/wrist/);
    // another front desk user (rental) did not report it: no access at all
    expect((await w.api('rental', 'GET', `/incidents/${created.body.id}`)).status).toBe(403);
    const full = await w.api('manager', 'GET', `/incidents/${created.body.id}`);
    expect(full.body.redacted).toBe(false);
    expect(full.body.incident.description).toMatch(/wrist/);
    expect(full.body.incident.customerName).toBeTruthy();
  });
});

describe('customer photo security', () => {
  let customerId: string, photoId: string;
  beforeAll(async () => {
    customerId = (await registerCustomer(w)).id;
    const up = await w.api('front', 'POST', `/customers/${customerId}/photos?purpose=PROFILE`, makePng(300, 300));
    expect(up.status).toBe(201);
    photoId = up.body.id;
  });

  it('is stored privately, never publicly reachable, and metadata is recorded', async () => {
    const row = (await pool.query('SELECT * FROM customer_photos WHERE id=$1', [photoId])).rows[0];
    expect(row.storage_key).toMatch(/^[0-9a-f-]{36}\/customer\/[0-9a-f-]{36}\.png$/); // server-generated name
    expect(row.mime_type).toBe('image/png');
    expect(row.width).toBe(300);
    expect(row.sha256).toHaveLength(64);
    expect(row.purpose).toBe('PROFILE');
    expect(row.captured_by).toBe(w.userIds.front_desk);
    expect(row.retention_until).toBeNull(); // profile photo: kept while profile is active (configurable)
    const st = await stat(join(resolve(process.env.STORAGE_DIR!), row.storage_key));
    expect(st.mode & 0o077).toBe(0); // owner-only permissions
    // not served from any static/public path
    for (const url of [`/${row.storage_key}`, `/uploads/${row.storage_key}`, `/storage-data/${row.storage_key}`, `/api/v1/${row.storage_key}`]) {
      const r = await w.app.inject({ method: 'GET', url });
      // (an unknown path may fall back to the SPA shell; what must never happen is serving the image itself)
      expect(String(r.headers['content-type'] ?? '')).not.toMatch(/^image\//);
      expect(r.rawPayload.includes(Buffer.from([0x89, 0x50, 0x4e, 0x47]))).toBe(false);
      expect(url.startsWith('/api/') ? r.statusCode === 404 : true).toBe(true);
    }
    expect((await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE entity_id=$1 AND action='photo.captured'`, [photoId])).rows[0].n).toBe(1);
  });

  it('requires authentication and permission; other venues and roles without customer.read cannot fetch it', async () => {
    expect((await w.app.inject({ method: 'GET', url: `/api/v1/photos/${photoId}/content` })).statusCode).toBe(401);
    expect((await other.api('owner', 'GET', `/photos/${photoId}/content`)).status).toBe(404);
    const slug = (await pool.query('SELECT slug FROM venues WHERE id=$1', [w.venueId])).rows[0].slug;
    const role = (await pool.query(`INSERT INTO roles (venue_id, code, name, is_system) VALUES ($1,'NOPHOTO','No photo',false) RETURNING id`, [w.venueId])).rows[0].id;
    await pool.query(`INSERT INTO role_permissions VALUES ($1,'session.read')`, [role]);
    await createUser(pool, w.venueId, { email: `nophoto@${slug}.test`, fullName: 'No Photo', password: PASSWORD, roleCode: 'NOPHOTO' });
    const tok = (await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: `nophoto@${slug}.test`, password: PASSWORD } })).json().token;
    expect((await w.api(tok, 'GET', `/photos/${photoId}/content`)).status).toBe(403);
    // the dashboard does not leak photo ids to a role that cannot view photos
    const dash = await w.api(tok, 'GET', '/dashboard');
    expect(dash.body.liveSessions.every((s: any) => s.photoId === null)).toBe(true);
    const ok = await w.api('rental', 'GET', `/photos/${photoId}/content`);
    expect(ok.status).toBe(200);
    expect(ok.headers['content-type']).toBe('image/png');
    expect(ok.headers['x-content-type-options']).toBe('nosniff');
    expect(ok.headers['cache-control']).toMatch(/private/);
    expect(sha(ok.raw)).toBe((await pool.query('SELECT sha256 FROM customer_photos WHERE id=$1', [photoId])).rows[0].sha256);
    expect((await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE entity_id=$1 AND action='photo.viewed'`, [photoId])).rows[0].n).toBeGreaterThanOrEqual(1);
  });

  it('short-lived signed URLs work without a header, expire, and cannot be tampered with', async () => {
    const s = await w.api('front', 'POST', `/photos/${photoId}/signed-url`);
    expect(s.status).toBe(200);
    const good = await w.app.inject({ method: 'GET', url: s.body.url });
    expect(good.statusCode).toBe(200);
    const tampered = await w.app.inject({ method: 'GET', url: s.body.url.replace(/sig=(.)/, (_m: string, c: string) => 'sig=' + (c === 'a' ? 'b' : 'a')) });
    expect(tampered.statusCode).toBe(404);
    const expired = await w.app.inject({ method: 'GET', url: s.body.url.replace(/exp=\d+/, 'exp=1000') });
    expect(expired.statusCode).toBe(404);
    expect((await other.api('owner', 'POST', `/photos/${photoId}/signed-url`)).status).toBe(404);
  });

  it('validates uploads from their bytes, never the Content-Type header', async () => {
    const up = (b: Buffer, ct = 'image/png', q = '?purpose=PROFILE') => w.api('front', 'POST', `/customers/${customerId}/photos${q}`, b, { 'content-type': ct });
    const text = await up(Buffer.from('<?php system($_GET["c"]); ?>'), 'image/png');
    expect(text.status).toBe(400); expect(text.body.error.code).toBe('IMAGE_TYPE_NOT_ALLOWED');
    const svg = await up(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'), 'image/png');
    expect(svg.body.error.code).toBe('IMAGE_TYPE_NOT_ALLOWED');
    const gif = await up(Buffer.from('GIF89a' + 'x'.repeat(40)), 'image/png');
    expect(gif.body.error.code).toBe('IMAGE_TYPE_NOT_ALLOWED');
    const html = await up(Buffer.from('<html><script>alert(1)</script></html>'), 'image/jpeg');
    expect(html.body.error.code).toBe('IMAGE_TYPE_NOT_ALLOWED');
    expect((await up(Buffer.alloc(0), 'image/png')).status).toBe(400);
    const tiny = await up(makePng(8, 8)); expect(tiny.body.error.code).toBe('IMAGE_TOO_SMALL');
    const huge = await up(makePng(5000, 100)); expect(huge.body.error.code).toBe('IMAGE_DIMENSIONS');
    const corrupt = await up(makePng(200, 200).subarray(0, 20)); expect(corrupt.status).toBe(400);
    const big = await up(Buffer.concat([makePng(200, 200), Buffer.alloc(6 * 1024 * 1024)]));
    expect(big.status).toBe(413);
    // a real PNG labelled as jpeg is accepted as what it really is
    const lie = await up(makePng(200, 200), 'image/jpeg');
    expect(lie.status).toBe(201);
    expect(lie.body.mimeType).toBe('image/png');
    // nothing rejected left files or rows behind
    const n = (await pool.query(`SELECT count(*)::int n FROM customer_photos WHERE customer_id=$1`, [customerId])).rows[0].n;
    expect(n).toBe(2);
  });

  it('strips EXIF/GPS metadata before storing', async () => {
    const withExif = makeJpeg(200, 200, true);
    expect(withExif.includes(Buffer.from('GPSLatitude'))).toBe(true);
    const r = await w.api('front', 'POST', `/customers/${customerId}/photos?purpose=VISIT`, withExif, { 'content-type': 'image/jpeg' });
    expect(r.status).toBe(201);
    const key = (await pool.query('SELECT storage_key FROM customer_photos WHERE id=$1', [r.body.id])).rows[0].storage_key;
    const stored = await storage.get(key);
    expect(stored.includes(Buffer.from('GPSLatitude'))).toBe(false);
    expect(validateImage(stored).width).toBe(200);
    expect(r.body.retentionUntil).not.toBeNull(); // visit photos carry a retention date (default 90 days)
  });

  it('retention: expired photos are deleted from storage and marked; uploads are rate limited', async () => {
    const r = await w.api('front', 'POST', `/customers/${customerId}/photos?purpose=VISIT`, makePng(150, 150));
    const key = (await pool.query('SELECT storage_key FROM customer_photos WHERE id=$1', [r.body.id])).rows[0].storage_key;
    await pool.query(`UPDATE customer_photos SET retention_until = now() - interval '1 day' WHERE id=$1`, [r.body.id]);
    const res = await runRetention();
    expect(res.photosExpired).toBeGreaterThanOrEqual(1);
    expect(await storage.exists(key)).toBe(false);
    expect((await pool.query('SELECT status FROM customer_photos WHERE id=$1', [r.body.id])).rows[0].status).toBe('EXPIRED');
    expect((await w.api('front', 'GET', `/photos/${r.body.id}/content`)).status).toBe(404);
    expect((await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE entity_id=$1 AND action='photo.retention_expired'`, [r.body.id])).rows[0].n).toBe(1);
    setRateLimitEnabled(true);
    try {
      const codes: number[] = [];
      for (let i = 0; i < 14; i++) codes.push((await w.api('front', 'POST', `/customers/${customerId}/photos?purpose=VISIT`, makePng(100, 100))).status);
      expect(codes).toContain(429);
    } finally { setRateLimitEnabled(false); }
  });
});

describe('privacy: erasure policy layer', () => {
  it('erases personal data and photos but retains financial and audit records', async () => {
    const a = await activeSession(w);
    await w.api('front', 'POST', `/customers/${a.customerId}/photos`, makePng(200, 200));
    const key = (await pool.query('SELECT storage_key FROM customer_photos WHERE customer_id=$1 LIMIT 1', [a.customerId])).rows[0].storage_key;
    const blocked = await w.api('owner', 'POST', `/customers/${a.customerId}/erase`, { reason: 'Customer request' });
    expect(blocked.status).toBe(409); // still skating
    await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    expect((await w.api('manager', 'POST', `/customers/${a.customerId}/erase`, { reason: 'Customer request' })).status).toBe(403);
    const ok = await w.api('owner', 'POST', `/customers/${a.customerId}/erase`, { reason: 'Customer request under data protection law' });
    expect(ok.status).toBe(200);
    const c = (await pool.query('SELECT full_name, phone_e164, email, status FROM customers WHERE id=$1', [a.customerId])).rows[0];
    expect(c).toEqual({ full_name: 'Erased customer', phone_e164: null, email: null, status: 'ERASED' });
    expect(await storage.exists(key)).toBe(false);
    expect((await pool.query('SELECT count(*)::int n FROM payments WHERE customer_id=$1', [a.customerId])).rows[0].n).toBe(1);
    expect((await pool.query(`SELECT count(*)::int n FROM audit_logs WHERE entity_id=$1 AND action='customer.erased'`, [a.customerId])).rows[0].n).toBe(1);
  });
});

describe('error responses', () => {
  it('are readable and never leak internals', async () => {
    const r = await w.api('front', 'GET', '/customers/not-a-uuid');
    expect(r.status).toBe(400);
    expect(r.body.error.message).not.toMatch(/SELECT|pg|stack|node_modules/i);
    const nf = await w.api('front', 'GET', `/customers/${randomUUID()}`);
    expect(nf.status).toBe(404);
    expect(nf.body.error.message).toBe('Customer was not found.');
    const v = await w.api('front', 'POST', '/customers', { fullName: 'x', phone: 123 });
    expect(v.status).toBe(400);
    expect(v.body.error.requestId).toBeTruthy();
    const unknown = await w.api('front', 'GET', '/nope');
    expect(unknown.status).toBe(404);
  });
});

describe('CORS', () => {
  it('adds no cross-origin headers by default (same-origin only, unless CORS_ORIGIN is explicitly set)', async () => {
    const preflight = await w.app.inject({ method: 'OPTIONS', url: '/api/v1/dashboard', headers: { origin: 'https://evil.example', 'access-control-request-method': 'GET' } });
    expect(preflight.headers['access-control-allow-origin']).toBeUndefined();
    const real = await w.app.inject({ method: 'GET', url: '/api/v1/health', headers: { origin: 'https://evil.example' } });
    expect(real.headers['access-control-allow-origin']).toBeUndefined();
  });
});
