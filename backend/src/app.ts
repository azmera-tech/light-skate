import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import helmet from '@fastify/helmet';
import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import fastifyStatic from '@fastify/static';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { ZodError } from 'zod';
import { config } from './config.js';
import { pool, withTx } from './db.js';
import { clock } from './shared/clock.js';
import { AppError, E } from './shared/errors.js';
import { translateDbError } from './shared/command.js';
import { resolveToken, type AuthUser } from './auth/service.js';
import { RealtimeHub } from './realtime/hub.js';
import { registerRoutes } from './routes.js';
import { startWorker } from './worker/index.js';
import { ensurePermissions } from './bootstrap.js';
import { migrate } from './migrate.js';

declare module 'fastify' {
  interface FastifyRequest {
    auth?: AuthUser;
  }
}

export interface BuiltApp {
  app: FastifyInstance;
  hub: RealtimeHub;
  close: () => Promise<void>;
}

export async function buildApp(opts: { embeddedWorker?: boolean; runMigrations?: boolean } = {}): Promise<BuiltApp> {
  if (opts.runMigrations) await migrate(() => {});
  await ensurePermissions(pool);

  const app = Fastify({
    logger: config.logLevel === 'silent' ? false : { level: config.logLevel, redact: ['req.headers.authorization'] },
    genReqId: (req) => {
      const h = req.headers['x-request-id'];
      return typeof h === 'string' && /^[\w.-]{8,64}$/.test(h) ? h : randomUUID();
    },
    trustProxy: true,
    bodyLimit: 1024 * 1024,
  });

  await app.register(helmet, {
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        imgSrc: ["'self'", 'data:', 'blob:'],
        connectSrc: ["'self'", 'ws:', 'wss:'],
        scriptSrc: ["'self'"],
        styleSrc: ["'self'", "'unsafe-inline'"],
        objectSrc: ["'none'"],
        frameAncestors: ["'none'"],
      },
    },
    crossOriginEmbedderPolicy: false,
  });
  app.addHook('onSend', async (_req, reply) => {
    reply.header('Permissions-Policy', 'camera=(self), microphone=()');
    if (_req.url.startsWith('/api/')) reply.header('Cache-Control', reply.getHeader('Cache-Control') ?? 'no-store');
  });

  // Same-origin by default (the web app is served from this process, so no CORS headers are needed and
  // none are sent). Opt in with CORS_ORIGIN (comma-separated) only when a client is hosted elsewhere —
  // a separately-deployed Flutter web build, a native app's local dev server, a staging domain, etc.
  // Native mobile/desktop app builds (Android, iOS) are never subject to browser CORS and need none of this.
  const allowedOrigins = config.corsOrigin.split(',').map((o) => o.trim()).filter(Boolean);
  if (allowedOrigins.length) {
    await app.register(cors, {
      origin: allowedOrigins,
      methods: ['GET', 'POST', 'PATCH', 'PUT', 'DELETE', 'OPTIONS'],
      allowedHeaders: ['content-type', 'authorization', 'idempotency-key', 'x-device-id', 'x-request-id'],
      exposedHeaders: ['idempotent-replay'],
      credentials: false, // auth is a bearer token, never a cookie, so credentialed CORS is unnecessary
      maxAge: 600,
    });
  }

  await app.register(websocket, { options: { maxPayload: 4096 } });

  // Raw image bodies for uploads (type is verified from the bytes, never from this header).
  app.addContentTypeParser(['image/jpeg', 'image/png', 'image/webp', 'application/octet-stream'], { parseAs: 'buffer', bodyLimit: config.storage.maxUploadBytes + 1024 }, (_req, body, done) => done(null, body));

  app.setErrorHandler((err: any, req: FastifyRequest, reply: FastifyReply) => {
    const requestId = req.id;
    if (err instanceof AppError) return reply.status(err.status).send({ error: { code: err.code, message: err.message, details: err.details, requestId } });
    if (err instanceof ZodError) {
      const first = err.issues[0];
      const where = first?.path.join('.') || 'request';
      return reply.status(400).send({ error: { code: 'VALIDATION_FAILED', message: `Please check the form: ${where} — ${first?.message ?? 'invalid'}.`, details: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message })), requestId } });
    }
    if (err.code === 'FST_ERR_CTP_BODY_TOO_LARGE' || err.statusCode === 413) {
      return reply.status(413).send({ error: { code: 'PAYLOAD_TOO_LARGE', message: 'That upload is too large.', requestId } });
    }
    if (err.code === 'FST_ERR_CTP_INVALID_MEDIA_TYPE' || err.statusCode === 415) {
      return reply.status(415).send({ error: { code: 'UNSUPPORTED_MEDIA_TYPE', message: 'Unsupported content type.', requestId } });
    }
    if (err.validation || err.statusCode === 400) return reply.status(400).send({ error: { code: 'BAD_REQUEST', message: 'The request was not understood.', requestId } });
    const t = translateDbError(err);
    if (t) return reply.status(t.status).send({ error: { code: t.code, message: t.message, requestId } });
    req.log.error({ err }, 'unhandled error');
    return reply.status(500).send({ error: { code: 'INTERNAL', message: 'Something went wrong on our side. Please try again; if it keeps happening, tell your manager.', requestId } });
  });
  app.setNotFoundHandler((req, reply) => {
    if (req.url.startsWith('/api/')) return reply.status(404).send({ error: { code: 'NOT_FOUND', message: 'That endpoint does not exist.', requestId: req.id } });
    return serveSpa(reply);
  });

  const hub = new RealtimeHub();
  registerRoutes(app, hub);
  hub.register(app);

  // Serve the built staff/admin app from the same origin (no CORS needed).
  const webDir = resolve(config.webDir);
  let spaIndex: string | null = null;
  if (existsSync(webDir)) {
    await app.register(fastifyStatic, { root: webDir, wildcard: false, index: false, cacheControl: true, maxAge: '1h' });
    spaIndex = 'index.html';
  }
  function serveSpa(reply: FastifyReply) {
    if (!spaIndex) return reply.status(404).send({ error: { code: 'NOT_FOUND', message: 'Not found.' } });
    reply.header('Cache-Control', 'no-cache');
    return (reply as any).sendFile('index.html');
  }
  app.get('/', async (_req, reply) => serveSpa(reply));

  let stopWorker: (() => void) | null = null;
  await app.ready();
  await hub.start();
  if (opts.embeddedWorker ?? config.worker.embedded) stopWorker = startWorker({ info: (m) => app.log.info(m), error: (m) => app.log.error(m) });

  return {
    app, hub,
    close: async () => {
      stopWorker?.();
      await hub.stop();
      await app.close();
    },
  };
}

/** Auth helper used by route definitions. */
export async function authenticate(req: FastifyRequest): Promise<AuthUser> {
  const h = req.headers.authorization;
  if (!h?.startsWith('Bearer ')) throw E.unauthorized();
  const dev = req.headers['x-device-id'];
  const user = await resolveToken(h.slice(7), typeof dev === 'string' ? dev : null);
  if (!user) throw E.unauthorized('Your session has expired. Please sign in again.');
  req.auth = user;
  return user;
}
export { withTx, clock };
