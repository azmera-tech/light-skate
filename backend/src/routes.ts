import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z, type ZodTypeAny } from 'zod';
import { createHash } from 'node:crypto';
import { pool, one } from './db.js';
import { config } from './config.js';
import { clock } from './shared/clock.js';
import { AppError, E } from './shared/errors.js';
import { execute, type CommandMeta, type CommandOpts } from './shared/command.js';
import { rateLimit } from './shared/ratelimit.js';
import type { Ctx } from './shared/ctx.js';
import { can } from './shared/ctx.js';
import { authenticate } from './app.js';
import { login, logout, listRolesForVenue } from './auth/service.js';
import { getSettings, getVenue } from './settings.js';
import { getMaxCapacity } from './modules/capacity.js';
import { storage } from './storage/index.js';
import { PERMISSIONS } from './permissions.js';
import type { RealtimeHub } from './realtime/hub.js';
import { outboxBacklog } from './worker/outbox.js';
import { replayCommands } from './modules/sync.js';
import * as customers from './modules/customers.js';
import * as waivers from './modules/waivers.js';
import * as visits from './modules/visits.js';
import * as sessions from './modules/sessions.js';
import * as payments from './modules/payments.js';
import * as equipment from './modules/equipment.js';
import * as incidents from './modules/incidents.js';
import * as photos from './modules/photos.js';
import * as pricing from './modules/pricing.js';
import * as admin from './modules/admin.js';
import * as reports from './modules/reports.js';
import * as dashboard from './modules/dashboard.js';
import * as dayclose from './modules/dayclose.js';
import { normalizePhone } from './shared/phone.js';
import { assertUuid } from './modules/util.js';

const uuid = z.string().uuid('must be a valid id');
const dateStr = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'use YYYY-MM-DD');
const reason = z.string().trim().min(3, 'please give a short reason').max(500);

const metaOf = (req: FastifyRequest): CommandMeta => {
  const k = req.headers['idempotency-key'];
  return { user: req.auth!, requestId: req.id, ip: req.ip ?? null, idempotencyKey: typeof k === 'string' ? k : null };
};

function parse<T extends ZodTypeAny>(schema: T, data: unknown): z.infer<T> {
  return schema.parse(data ?? {});
}

/** Read-only snapshot transaction: a screen's queries all see one consistent state. */
async function read<T>(req: FastifyRequest, fn: (ctx: Ctx) => Promise<T>): Promise<T> {
  const user = await authenticate(req);
  const client = await pool.connect();
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const ctx: Ctx = { db: client, user, venueId: user.venueId, deviceId: user.deviceId, requestId: req.id, ip: req.ip ?? null, now: clock.now() };
    const out = await fn(ctx);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

export function registerRoutes(app: FastifyInstance, hub: RealtimeHub) {
  const P = '/api/v1';

  /** Declarative state-changing route: authenticate -> validate -> authorize -> idempotency -> transaction. */
  function command<B extends ZodTypeAny = z.ZodAny>(
    method: 'post' | 'put' | 'patch' | 'delete',
    path: string,
    o: { op: string; perm?: string | string[]; idem?: CommandOpts['idempotency']; status?: number; body?: B; rate?: [string, number, number] },
    handler: (ctx: Ctx, input: z.infer<B>, req: FastifyRequest) => Promise<unknown>,
  ) {
    (app as any)[method](P + path, async (req: FastifyRequest, reply: FastifyReply) => {
      await authenticate(req);
      if (o.rate) rateLimit(o.rate[0], req.auth!.id, o.rate[1], o.rate[2]);
      const input = o.body ? parse(o.body, req.body) : (undefined as any);
      const r = await execute(metaOf(req), { operation: o.op, permission: o.perm, idempotency: o.idem ?? 'optional', successStatus: o.status }, { params: req.params, body: input },
        (ctx) => handler(ctx, input, req));
      if (r.replay) reply.header('Idempotent-Replay', 'true');
      reply.status(r.status);
      return r.body;
    });
  }
  const get = (path: string, handler: (ctx: Ctx, req: FastifyRequest) => Promise<unknown>) =>
    app.get(P + path, async (req) => read(req, (ctx) => handler(ctx, req)));
  const idParam = (req: FastifyRequest, name = 'id') => { const v = (req.params as any)[name]; assertUuid(v); return v as string; };

  // ---------------------------------------------------------------- public / meta
  app.get(`${P}/health`, async (_req, reply) => {
    try {
      await pool.query('SELECT 1');
      const ob = await outboxBacklog();
      return { status: 'ok', time: new Date().toISOString(), outbox: ob, realtimeClients: hub.connectionCount };
    } catch {
      return reply.status(503).send({ status: 'unavailable' });
    }
  });
  app.get(`${P}/time`, async () => ({ serverTime: clock.now().toISOString() }));

  // ---------------------------------------------------------------- auth
  app.post(`${P}/auth/login`, async (req) => {
    const body = parse(z.object({ email: z.string().email().max(200), password: z.string().min(1).max(200), deviceId: z.string().uuid().optional() }), req.body);
    rateLimit('login-ip', req.ip, 30, 60_000, 'Too many sign-in attempts from this device. Please wait a minute.');
    rateLimit('login', `${req.ip}:${body.email.toLowerCase()}`, 8, 60_000, 'Too many sign-in attempts. Please wait a minute and try again.');
    return login({ email: body.email, password: body.password, deviceId: body.deviceId, ip: req.ip, userAgent: String(req.headers['user-agent'] ?? '') });
  });
  app.post(`${P}/auth/logout`, async (req) => { const u = await authenticate(req); await logout(u.authSessionId); return { ok: true }; });
  app.get(`${P}/auth/me`, async (req) => {
    const u = await authenticate(req);
    return { id: u.id, email: u.email, fullName: u.fullName, role: u.roleCode, permissions: [...u.permissions].sort(), venueId: u.venueId, deviceId: u.deviceId };
  });

  // ---------------------------------------------------------------- config / emergency / products
  get('/config', async (ctx) => {
    const settings = await getSettings(ctx.db, ctx.venueId);
    const venue = await getVenue(ctx.db, ctx.venueId);
    return {
      serverTime: ctx.now.toISOString(), venue,
      maxCapacity: await getMaxCapacity(ctx.db, ctx.venueId, ctx.now),
      settings: {
        paymentMethods: settings.paymentMethods.filter((m) => m.enabled), warnings: settings.warnings, expiringMinutes: settings.expiringMinutes,
        pause: settings.pause, extensionOptionsMinutes: settings.extensionOptionsMinutes, waiverRequired: settings.waiverRequired, minorAgeYears: settings.minorAgeYears,
        photoCapture: settings.photoCapture, wristbands: settings.wristbands, equipmentRequiredForStart: settings.equipmentRequiredForStart, inspectOnReturn: settings.inspectOnReturn,
        earlyExitGraceSeconds: settings.earlyExitGraceSeconds,
      },
      emergency: settings.emergency,
    };
  });
  get('/emergency', async (ctx) => (await getSettings(ctx.db, ctx.venueId)).emergency);
  get('/products', async (ctx, req) => {
    if (!can(ctx, 'session.create') && !can(ctx, 'session.read')) throw E.forbidden("You don't have permission to view session options.");
    const q = parse(z.object({ customerId: uuid.optional() }), req.query);
    const extensions = (await pricing.listPricingRules(ctx.db, ctx.venueId)).filter((r: any) => r.kind === 'EXTENSION' && r.active);
    return { sessions: await pricing.listApplicableProducts(ctx.db, ctx.venueId, ctx.now, q.customerId), extensions };
  });

  // ---------------------------------------------------------------- customers
  const emergencyContact = z.object({ name: z.string().trim().min(1).max(120), phone: z.string().trim().min(5).max(30), relationship: z.string().max(60).nullish(), isGuardian: z.boolean().optional() });
  const customerBody = z.object({
    fullName: z.string().trim().min(2, 'enter the full name').max(120),
    phone: z.string().trim().min(5).max(30),
    email: z.string().trim().email().max(200).nullish().or(z.literal('')),
    dateOfBirth: dateStr.nullish(),
    notes: z.string().max(1000).nullish(),
    emergencyContact: emergencyContact.nullish(),
    confirmDistinct: z.boolean().optional(),
  });
  command('post', '/customers', { op: 'customer.create', perm: 'customer.create', idem: 'required', status: 201, body: customerBody }, (ctx, b) => customers.createCustomer(ctx, b));
  app.get(`${P}/customers`, async (req) => {
    const q = parse(z.object({ q: z.string().max(100).optional(), limit: z.coerce.number().int().min(1).max(200).optional(), offset: z.coerce.number().int().min(0).optional() }), req.query);
    const user = await authenticate(req);
    rateLimit('search', user.id, 120, 60_000, 'You are searching too quickly. Please wait a moment.');
    return read(req, async (ctx) => {
      if (!can(ctx, 'customer.read') && !can(ctx, 'customer.create')) throw E.forbidden("You don't have permission to view customers.");
      if (q.q) return { customers: await customers.searchCustomers(ctx, q.q, q.limit ?? 20), normalizedPhone: normalizePhone(q.q) };
      return { customers: await customers.listCustomers(ctx, { limit: q.limit ?? 50, offset: q.offset ?? 0 }) };
    });
  });
  get('/customers/:id', (ctx, req) => customers.getCustomer(ctx, idParam(req)));
  command('patch', '/customers/:id', { op: 'customer.update', perm: 'customer.update', body: customerBody.partial().omit({ confirmDistinct: true }).extend({ status: z.enum(['ACTIVE', 'BLOCKED', 'ARCHIVED']).optional(), email: z.string().trim().email().nullish().or(z.literal('')) }) },
    (ctx, b, req) => customers.updateCustomer(ctx, idParam(req), b as any));
  get('/customers/:id/history', async (ctx, req) => ({ history: await customers.customerHistory(ctx, idParam(req)) }));
  command('post', '/customers/:id/erase', { op: 'customer.erase', perm: 'customer.delete', idem: 'required', body: z.object({ reason }) }, (ctx, b, req) => customers.eraseCustomer(ctx, idParam(req), b.reason));

  // ---------------------------------------------------------------- photos
  app.post(`${P}/customers/:id/photos`, async (req, reply) => {
    await authenticate(req);
    rateLimit('upload', req.auth!.id, 10, 60_000, 'Too many photo uploads. Please wait a moment.');
    const q = parse(z.object({ purpose: z.enum(['PROFILE', 'VISIT']).default('PROFILE'), visitId: uuid.optional() }), req.query);
    const bytes = req.body as Buffer;
    if (!Buffer.isBuffer(bytes)) throw E.badRequest('IMAGE_REQUIRED', 'Send the photo as a JPEG, PNG or WebP image body.');
    const id = idParam(req);
    const written = { keys: [] as string[] };
    try {
      const r = await execute(metaOf(req), { operation: 'photo.upload', permission: ['customer.create', 'customer.update'], idempotency: 'optional', successStatus: 201 },
        { id, q, sha: createHash('sha256').update(bytes).digest('hex') },
        (ctx) => photos.storeCustomerPhoto(ctx, { customerId: id, visitId: q.visitId, purpose: q.purpose, bytes }, written));
      reply.status(r.status);
      return r.body;
    } catch (e) {
      for (const k of written.keys) await storage.delete(k).catch(() => {}); // no orphaned files if the transaction failed
      throw e;
    }
  });
  get('/customers/:id/photos', async (ctx, req) => {
    if (!can(ctx, 'customer.read')) throw E.forbidden("You don't have permission to view customers.");
    const rows = await pool.query(`SELECT id, purpose, captured_at, retention_until, status, width, height FROM customer_photos WHERE customer_id=$1 AND venue_id=$2 AND status='ACTIVE' ORDER BY captured_at DESC`, [idParam(req), ctx.venueId]);
    return { photos: rows.rows.map((r) => ({ id: r.id, purpose: r.purpose, capturedAt: r.captured_at, retentionUntil: r.retention_until, width: r.width, height: r.height })) };
  });
  const sendImage = (reply: FastifyReply, p: { bytes: Buffer; mime: string }, cache = 'private, max-age=300') => {
    reply.header('Content-Type', p.mime).header('X-Content-Type-Options', 'nosniff').header('Content-Security-Policy', "default-src 'none'").header('Cache-Control', cache).header('Content-Disposition', 'inline');
    return reply.send(p.bytes);
  };
  app.get(`${P}/photos/:id/content`, async (req, reply) => {
    const user = await authenticate(req);
    if (!user.permissions.has('customer.read')) throw E.forbidden("You don't have permission to view customer photos.");
    rateLimit('photo', user.id, 600, 60_000);
    return sendImage(reply, await photos.loadPhotoForUser({ venueId: user.venueId, userId: user.id, requestId: req.id, ip: req.ip ?? null, deviceId: user.deviceId }, idParam(req)));
  });
  app.post(`${P}/photos/:id/signed-url`, async (req) => {
    const user = await authenticate(req);
    if (!user.permissions.has('customer.read')) throw E.forbidden("You don't have permission to view customer photos.");
    const id = idParam(req);
    const p = await one<any>(pool, `SELECT venue_id, status FROM customer_photos WHERE id=$1`, [id]);
    if (!p || p.venue_id !== user.venueId || p.status !== 'ACTIVE') throw E.notFound('Photo');
    return photos.issueSignedUrl(user.venueId, id);
  });
  app.get(`${P}/photos/:id/signed`, async (req, reply) => {
    rateLimit('signed', req.ip, 120, 60_000);
    const q = parse(z.object({ exp: z.coerce.number().int(), sig: z.string().min(10).max(200) }), req.query);
    return sendImage(reply, await photos.loadPhotoBySignature(idParam(req), q.exp, q.sig), 'private, no-store');
  });

  // ---------------------------------------------------------------- waivers
  get('/waivers/current', async (ctx) => ({ waiver: await waivers.getCurrentWaiver(ctx.db, ctx.venueId) }));
  get('/waivers/versions', async (ctx) => ({ versions: await waivers.listWaiverVersions(ctx.db, ctx.venueId) }));
  command('post', '/waivers/versions', { op: 'waiver.publish', perm: 'waiver.manage', status: 201, body: z.object({ title: z.string().trim().min(3).max(200), body: z.string().trim().min(20).max(20000), language: z.string().max(10).optional() }) },
    (ctx, b) => waivers.publishWaiverVersion(ctx, b));
  get('/customers/:id/waiver', async (ctx, req) => { if (!can(ctx, 'customer.read')) throw E.forbidden("You don't have permission to view customers."); return waivers.waiverStatus(ctx.db, ctx.venueId, idParam(req)); });
  command('post', '/customers/:id/waiver-acceptance', { op: 'waiver.accept', perm: ['customer.create', 'customer.update'], status: 201,
    body: z.object({ waiverVersionId: uuid.optional(), visitId: uuid.nullish(), signatureData: z.string().max(200_000).nullish(), guardianName: z.string().trim().max(120).nullish(), guardianPhone: z.string().trim().max(30).nullish() }) },
    (ctx, b, req) => waivers.acceptWaiver(ctx, idParam(req), b));

  // ---------------------------------------------------------------- visits
  command('post', '/visits', { op: 'visit.create', perm: 'session.create', status: 201, body: z.object({ customerId: uuid }) }, (ctx, b) => visits.createVisit(ctx, b));
  get('/visits', (ctx, req) => {
    const q = parse(z.object({ date: dateStr.optional(), filter: z.enum(['all', 'completed', 'active', 'cancelled', 'expired', 'payment_issues', 'incidents']).optional(), customerId: uuid.optional(), limit: z.coerce.number().int().min(1).max(500).optional(), offset: z.coerce.number().int().min(0).optional() }), req.query);
    return visits.listVisits(ctx, q);
  });
  get('/visits/:id', (ctx, req) => visits.getVisit(ctx, idParam(req)));

  // ---------------------------------------------------------------- sessions
  command('post', '/sessions', { op: 'session.create', perm: 'session.create', status: 201,
    body: z.object({ visitId: uuid, pricingRuleId: uuid, discountMinor: z.number().int().min(0).optional(), discountReason: z.string().max(300).nullish(), wristband: z.string().max(20).nullish() }) },
    (ctx, b) => sessions.createSession(ctx, b));
  get('/sessions', (ctx, req) => sessions.listSessions(ctx, parse(z.object({ group: z.enum(['live', 'waiting', 'expiring']).default('live') }), req.query)));
  get('/sessions/:id', (ctx, req) => sessions.getSession(ctx, idParam(req)));
  command('post', '/sessions/:id/start', { op: 'session.start', perm: 'session.create', idem: 'required', body: z.object({ equipmentIds: z.array(uuid).max(5).optional(), wristband: z.string().max(20).nullish(), overrideCapacityReason: z.string().max(300).nullish() }) },
    (ctx, b, req) => sessions.startSession(ctx, idParam(req), b));
  const reasonOpt = z.object({ reason: z.string().max(500).nullish() });
  command('post', '/sessions/:id/pause', { op: 'session.pause', perm: 'session.pause', body: reasonOpt }, (ctx, b, req) => sessions.pauseSession(ctx, idParam(req), b));
  command('post', '/sessions/:id/resume', { op: 'session.resume', perm: 'session.pause', body: reasonOpt }, (ctx, b, req) => sessions.resumeSession(ctx, idParam(req), b));
  command('post', '/sessions/:id/extend', { op: 'session.extend', perm: 'session.extend', idem: 'required',
    body: z.object({ minutes: z.number().int().min(5).max(480), reason: z.string().max(500).nullish(), complimentary: z.boolean().optional(), payment: z.object({ method: z.string().max(24), reference: z.string().max(100).nullish() }).nullish() }) },
    (ctx, b, req) => sessions.extendSession(ctx, idParam(req), b));
  command('post', '/sessions/:id/end', { op: 'session.end', perm: 'session.end', idem: 'required', body: reasonOpt }, (ctx, b, req) => sessions.endSession(ctx, idParam(req), { reason: b.reason }));
  command('post', '/sessions/:id/cancel', { op: 'session.cancel', perm: 'session.cancel', body: z.object({ reason }) }, (ctx, b, req) => sessions.cancelSession(ctx, idParam(req), b));
  command('post', '/sessions/:id/correct', { op: 'session.correct', perm: 'session.correct', idem: 'required',
    body: z.discriminatedUnion('action', [z.object({ action: z.literal('CHANGE_DURATION'), newDurationMinutes: z.number().int().min(1).max(600), reason }), z.object({ action: z.literal('REOPEN'), reason })]) },
    (ctx, b, req) => sessions.correctSession(ctx, idParam(req), b));

  // ---------------------------------------------------------------- payments
  command('post', '/payments', { op: 'payment.create', perm: 'payment.create', idem: 'required', status: 201, rate: ['payment', 60, 60_000],
    body: z.object({ sessionId: uuid, amountMinor: z.number().int().positive().max(100_000_000), method: z.string().max(24), reference: z.string().trim().max(100).nullish(), note: z.string().max(300).nullish(), confirmed: z.boolean().optional() }) },
    (ctx, b) => payments.recordPayment(ctx, b));
  get('/payments', (ctx, req) => payments.listPayments(ctx, parse(z.object({ date: dateStr.optional(), status: z.string().max(30).optional(), limit: z.coerce.number().int().max(500).optional() }), req.query)).then((p) => ({ payments: p })));
  get('/payments/:id', (ctx, req) => payments.getPayment(ctx, idParam(req)));
  command('post', '/payments/:id/refund', { op: 'payment.refund', perm: 'payment.refund', idem: 'required', rate: ['refund', 20, 60_000],
    body: z.object({ amountMinor: z.number().int().positive().optional(), reason }) }, (ctx, b, req) => payments.refundPayment(ctx, idParam(req), b));
  for (const [action, outcome] of [['confirm', 'CONFIRM'], ['cancel', 'CANCEL'], ['fail', 'FAIL']] as const) {
    command('post', `/payments/:id/${action}`, { op: `payment.${action}`, perm: 'payment.create', body: z.object({ reference: z.string().max(100).nullish() }) },
      (ctx, b, req) => payments.resolvePendingPayment(ctx, idParam(req), outcome, b.reference));
  }

  // ---------------------------------------------------------------- equipment
  get('/equipment', (ctx, req) => equipment.listEquipment(ctx, parse(z.object({ status: z.string().max(30).optional(), q: z.string().max(40).optional() }), req.query)));
  get('/equipment/:id', (ctx, req) => equipment.getEquipment(ctx, idParam(req)));
  command('post', '/equipment', { op: 'equipment.create', perm: 'equipment.manage', status: 201,
    body: z.object({ code: z.string().trim().min(2).max(30), category: z.string().max(30).optional(), size: z.string().max(20).nullish(), condition: z.enum(['NEW', 'GOOD', 'FAIR', 'POOR']).optional(), location: z.string().max(60).nullish() }) },
    (ctx, b) => equipment.createEquipment(ctx, b));
  command('post', '/equipment/:id/assign', { op: 'equipment.assign', perm: 'equipment.assign', idem: 'required', body: z.object({ sessionId: uuid }) }, (ctx, b, req) => equipment.assignEquipment(ctx, idParam(req), b.sessionId));
  command('post', '/equipment/:id/return', { op: 'equipment.return', perm: 'equipment.return', idem: 'required', body: z.object({ condition: z.enum(['GOOD', 'DAMAGED']).default('GOOD'), note: z.string().max(500).nullish() }) }, (ctx, b, req) => equipment.returnEquipment(ctx, idParam(req), b));
  command('post', '/equipment/:id/inspect', { op: 'equipment.inspect', perm: 'equipment.return' }, (ctx, _b, req) => equipment.markInspected(ctx, idParam(req)));
  command('post', '/equipment/:id/damage', { op: 'equipment.damage', perm: 'equipment.maintenance', body: z.object({ issue: z.string().trim().min(3).max(500), startMaintenance: z.boolean().optional() }) }, (ctx, b, req) => equipment.reportDamage(ctx, idParam(req), b));
  command('post', '/equipment/:id/maintenance/start', { op: 'equipment.maintenance_start', perm: 'equipment.maintenance' }, (ctx, _b, req) => equipment.startMaintenance(ctx, idParam(req)));
  command('post', '/equipment/:id/maintenance/complete', { op: 'equipment.maintenance_complete', perm: 'equipment.maintenance', body: z.object({ resolution: z.string().max(500).nullish() }) }, (ctx, b, req) => equipment.completeMaintenance(ctx, idParam(req), b));
  command('post', '/equipment/:id/out-of-service', { op: 'equipment.out_of_service', perm: 'equipment.maintenance', body: z.object({ reason }) }, (ctx, b, req) => equipment.markOutOfService(ctx, idParam(req), b));
  app.post(`${P}/equipment/:id/maintenance/photo`, async (req, reply) => {
    await authenticate(req);
    rateLimit('upload', req.auth!.id, 10, 60_000, 'Too many photo uploads. Please wait a moment.');
    const bytes = req.body as Buffer;
    if (!Buffer.isBuffer(bytes)) throw E.badRequest('IMAGE_REQUIRED', 'Send the photo as a JPEG, PNG or WebP image body.');
    const id = idParam(req); const written = { keys: [] as string[] };
    try {
      const r = await execute(metaOf(req), { operation: 'equipment.damage_photo', permission: 'equipment.maintenance', successStatus: 201 }, { id, sha: createHash('sha256').update(bytes).digest('hex') },
        (ctx) => equipment.attachMaintenancePhoto(ctx, id, (req.query as any).recordId ?? null, bytes, written));
      reply.status(r.status); return r.body;
    } catch (e) { for (const k of written.keys) await storage.delete(k).catch(() => {}); throw e; }
  });
  app.get(`${P}/equipment/:id/maintenance/photo`, async (req, reply) => {
    const user = await authenticate(req);
    if (!user.permissions.has('equipment.read')) throw E.forbidden("You don't have permission to view equipment.");
    const rec = await one<any>(pool, `SELECT photo_key, photo_mime FROM maintenance_records WHERE equipment_id=$1 AND venue_id=$2 AND photo_key IS NOT NULL ORDER BY reported_at DESC LIMIT 1`, [idParam(req), user.venueId]);
    if (!rec) throw E.notFound('Photo');
    return sendImage(reply, { bytes: await storage.get(rec.photo_key), mime: rec.photo_mime });
  });

  // ---------------------------------------------------------------- incidents
  command('post', '/incidents', { op: 'incident.create', perm: 'incident.create', status: 201, idem: 'optional',
    body: z.object({ customerId: uuid.nullish(), sessionId: uuid.nullish(), occurredAt: z.coerce.date().nullish(), location: z.string().max(100).nullish(), incidentType: z.string().trim().min(2).max(60),
      severity: z.enum(['MINOR', 'MODERATE', 'SERIOUS', 'CRITICAL']), description: z.string().trim().min(3).max(4000), actionTaken: z.string().max(2000).nullish(), managerNotified: z.boolean().optional() }) },
    (ctx, b) => incidents.createIncident(ctx, b));
  get('/incidents', (ctx, req) => incidents.listIncidents(ctx, parse(z.object({ open: z.enum(['true', 'false']).optional() }), req.query).open === 'true' ? { open: true } : {}));
  get('/incidents/:id', (ctx, req) => incidents.getIncident(ctx, idParam(req)));
  command('post', '/incidents/:id/transition', { op: 'incident.transition', perm: 'incident.manage', body: z.object({ to: z.enum(['ACKNOWLEDGED', 'ACTION_TAKEN', 'UNDER_REVIEW', 'CLOSED']), note: z.string().max(1000).nullish(), actionTaken: z.string().max(2000).nullish() }) },
    (ctx, b, req) => incidents.transitionIncident(ctx, idParam(req), b));
  app.post(`${P}/incidents/:id/attachments`, async (req, reply) => {
    await authenticate(req);
    rateLimit('upload', req.auth!.id, 10, 60_000, 'Too many photo uploads. Please wait a moment.');
    const bytes = req.body as Buffer;
    if (!Buffer.isBuffer(bytes)) throw E.badRequest('IMAGE_REQUIRED', 'Send the photo as a JPEG, PNG or WebP image body.');
    const id = idParam(req); const written = { keys: [] as string[] };
    try {
      const r = await execute(metaOf(req), { operation: 'incident.attach', permission: ['incident.create', 'incident.manage'], successStatus: 201 }, { id, sha: createHash('sha256').update(bytes).digest('hex') },
        (ctx) => incidents.attachIncidentPhoto(ctx, id, bytes, written));
      reply.status(r.status); return r.body;
    } catch (e) { for (const k of written.keys) await storage.delete(k).catch(() => {}); throw e; }
  });
  app.get(`${P}/incident-attachments/:id/content`, async (req, reply) => {
    const user = await authenticate(req);
    const a = await read(req, (ctx) => incidents.loadIncidentAttachment(ctx, idParam(req)));
    void user;
    return sendImage(reply, a);
  });

  // ---------------------------------------------------------------- dashboard / reports / close
  get('/dashboard', (ctx) => dashboard.getDashboard(ctx));
  get('/reports/daily', (ctx, req) => reports.dailyReport(ctx, parse(z.object({ date: dateStr.optional() }), req.query).date));
  get('/reports/range', (ctx, req) => reports.rangeReport(ctx, parse(z.object({ from: dateStr, to: dateStr, group: z.enum(['day', 'week', 'month']).default('day') }), req.query)));
  get('/day-close/preview', (ctx, req) => dayclose.dayClosePreview(ctx, parse(z.object({ date: dateStr.optional() }), req.query).date));
  get('/day-closes', async (ctx) => ({ closes: await dayclose.listDayCloses(ctx) }));
  command('post', '/day-close', { op: 'day.close', perm: 'dayclose.manage', idem: 'required', status: 201,
    body: z.object({ date: dateStr.optional(), countedCashMinor: z.number().int().min(0), notes: z.string().max(1000).nullish(), acknowledgeWarnings: z.boolean().optional() }) }, (ctx, b) => dayclose.closeDay(ctx, b));

  // ---------------------------------------------------------------- admin
  get('/staff', async (ctx) => ({ staff: await admin.listStaff(ctx) }));
  get('/roles', async (ctx) => { if (!can(ctx, 'staff.manage')) throw E.forbidden("You don't have permission to manage staff accounts."); return { roles: await listRolesForVenue(ctx.db, ctx.venueId), permissions: PERMISSIONS }; });
  command('post', '/staff', { op: 'staff.create', perm: 'staff.manage', status: 201, idem: 'required', body: z.object({ email: z.string().email().max(200), fullName: z.string().trim().min(2).max(120), password: z.string().min(1).max(200), roleId: uuid, phone: z.string().max(30).nullish(), employeeNo: z.string().max(30).nullish() }) },
    (ctx, b) => admin.createStaff(ctx, b));
  command('patch', '/staff/:id', { op: 'staff.update', perm: 'staff.manage', body: z.object({ roleId: uuid.optional(), status: z.enum(['ACTIVE', 'DISABLED']).optional(), fullName: z.string().trim().min(2).max(120).optional() }) }, (ctx, b, req) => admin.updateStaff(ctx, idParam(req), b));
  command('post', '/staff/:id/reset-password', { op: 'staff.reset_password', perm: 'staff.manage', body: z.object({ password: z.string().min(1).max(200) }) }, (ctx, b, req) => admin.resetStaffPassword(ctx, idParam(req), b.password));
  get('/devices', async (ctx) => ({ devices: await admin.listDevices(ctx) }));
  command('post', '/devices', { op: 'device.register', perm: 'device.manage', status: 201, body: z.object({ name: z.string().trim().min(2).max(60), deviceType: z.enum(['FRONT_DESK', 'RENTAL_DESK', 'MANAGER', 'KIOSK', 'OTHER']) }) }, (ctx, b) => admin.registerDevice(ctx, b));
  command('patch', '/devices/:id', { op: 'device.update', perm: 'device.manage', body: z.object({ status: z.enum(['ACTIVE', 'DISABLED']).optional(), name: z.string().trim().min(2).max(60).optional() }) }, (ctx, b, req) => admin.updateDevice(ctx, idParam(req), b));
  get('/settings', async (ctx) => { if (!can(ctx, 'settings.manage')) throw E.forbidden("You don't have permission to change venue settings."); return { settings: await getSettings(ctx.db, ctx.venueId), venue: await getVenue(ctx.db, ctx.venueId), maxCapacity: await getMaxCapacity(ctx.db, ctx.venueId, ctx.now) }; });
  command('put', '/settings', { op: 'settings.update', perm: 'settings.manage', body: z.record(z.unknown()) }, async (ctx, b) => ({ settings: await admin.updateSettings(ctx, b) }));
  command('put', '/capacity', { op: 'capacity.set', perm: 'capacity.manage', body: z.object({ maxCapacity: z.number().int().min(0).max(5000), reason: z.string().max(300).nullish() }) }, (ctx, b) => admin.setCapacity(ctx, b.maxCapacity, b.reason));
  get('/pricing', async (ctx) => {
    if (!can(ctx, 'pricing.manage') && !can(ctx, 'settings.manage') && !can(ctx, 'reports.read')) throw E.forbidden("You don't have permission to view pricing.");
    return { rules: await pricing.listPricingRules(ctx.db, ctx.venueId) };
  });
  const pricingBody = z.object({ kind: z.enum(['SESSION', 'EXTENSION']), name: z.string().trim().min(1).max(60), durationMinutes: z.number().int().min(1).max(600), priceMinor: z.number().int().min(0).max(100_000_000),
    dayType: z.enum(['ANY', 'WEEKDAY', 'WEEKEND', 'HOLIDAY']).optional(), customerType: z.enum(['ANY', 'ADULT', 'CHILD']).optional(), active: z.boolean().optional(), sortOrder: z.number().int().optional() });
  command('post', '/pricing', { op: 'pricing.create', perm: 'pricing.manage', status: 201, body: pricingBody }, (ctx, b) => pricing.createPricingRule(ctx, b));
  command('patch', '/pricing/:id', { op: 'pricing.update', perm: 'pricing.manage', body: pricingBody.partial() }, (ctx, b, req) => pricing.updatePricingRule(ctx, idParam(req), b));
  get('/audit', (ctx, req) => {
    const q = parse(z.object({ action: z.string().max(60).optional(), entityType: z.string().max(40).optional(), entityId: z.string().max(60).optional(), actorId: uuid.optional(), from: z.coerce.date().optional(), to: z.coerce.date().optional(), before: z.coerce.number().int().optional(), limit: z.coerce.number().int().max(500).optional() }), req.query);
    return admin.listAudit(ctx, q).then((entries) => ({ entries }));
  });
  get('/notifications', (ctx, req) => admin.listNotifications(ctx, parse(z.object({ status: z.enum(['OPEN', 'ACKNOWLEDGED', 'RESOLVED']).optional() }), req.query)).then((n) => ({ notifications: n })));
  command('post', '/notifications/:id/ack', { op: 'notification.ack', perm: 'session.read', body: z.object({ resolve: z.boolean().optional() }) }, (ctx, b, req) => admin.ackNotification(ctx, idParam(req), b.resolve ? 'RESOLVED' : 'ACKNOWLEDGED'));

  // ---------------------------------------------------------------- offline sync
  app.post(`${P}/sync/commands`, async (req) => {
    await authenticate(req);
    rateLimit('sync', req.auth!.id, 30, 60_000);
    const body = parse(z.object({ commands: z.array(z.object({ requestId: z.string().min(8).max(128), command: z.string().max(40), sessionId: uuid.optional(), equipmentId: uuid.optional(), params: z.record(z.any()).optional(), issuedAt: z.string().max(40).optional() })).min(1).max(100) }), req.body);
    const { idempotencyKey: _ignored, ...meta } = metaOf(req);
    return { serverTime: clock.now().toISOString(), results: await replayCommands(meta, body.commands) };
  });
}
