import { randomBytes } from 'node:crypto';
import { config as loadDotenv } from 'dotenv';

// Loads backend/.env if present. Never overrides a variable the environment (shell, Docker, CI) already set,
// so production deployments that inject real env vars are unaffected either way.
loadDotenv();

function bool(v: string | undefined, d: boolean) {
  if (v === undefined) return d;
  return ['1', 'true', 'yes', 'on'].includes(v.toLowerCase());
}

const env = process.env;
const isProd = env.NODE_ENV === 'production';

if (isProd && !env.SIGNING_SECRET) {
  throw new Error('SIGNING_SECRET must be set in production');
}

export const config = {
  env: env.NODE_ENV ?? 'development',
  isProd,
  isTest: env.NODE_ENV === 'test',
  port: Number(env.PORT ?? 8080),
  host: env.HOST ?? '0.0.0.0',
  databaseUrl: env.DATABASE_URL ?? 'postgres://lightskate:lightskate@localhost:5432/lightskate',
  dbPoolMax: Number(env.DB_POOL_MAX ?? 20),
  logLevel: env.LOG_LEVEL ?? 'info',
  /** HMAC key for signed photo URLs. Random per-process in dev/test. */
  signingSecret: env.SIGNING_SECRET ?? randomBytes(32).toString('hex'),
  storage: {
    driver: (env.STORAGE_DRIVER ?? 'local') as 'local',
    dir: env.STORAGE_DIR ?? './storage-data',
    maxUploadBytes: Number(env.MAX_UPLOAD_BYTES ?? 5 * 1024 * 1024),
    minDimension: Number(env.PHOTO_MIN_DIM ?? 64),
    maxDimension: Number(env.PHOTO_MAX_DIM ?? 4096),
    signedUrlTtlSeconds: Number(env.SIGNED_URL_TTL_SECONDS ?? 60),
  },
  auth: {
    sessionTtlHours: Number(env.SESSION_TTL_HOURS ?? 12),
    maxFailedLogins: Number(env.MAX_FAILED_LOGINS ?? 5),
    lockoutMinutes: Number(env.LOCKOUT_MINUTES ?? 15),
    minPasswordLength: 10,
  },
  rateLimit: {
    enabled: bool(env.RATE_LIMIT_ENABLED, true),
  },
  worker: {
    /** Run the background worker inside the API process (single-node deployments). */
    embedded: bool(env.EMBEDDED_WORKER, !isProd ? true : false),
    tickMs: Number(env.WORKER_TICK_MS ?? 5000),
    outboxBatch: 50,
    outboxMaxAttempts: 10,
  },
  webDir: env.WEB_DIR ?? '../web/dist',
  corsOrigin: env.CORS_ORIGIN ?? '',
  idempotencyTtlHours: 48,
} as const;
