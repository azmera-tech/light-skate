import { createHash } from 'node:crypto';
import { withTx } from '../db.js';
import { config } from '../config.js';
import { clock } from './clock.js';
import { AppError, E, permissionDeniedMessage } from './errors.js';
import type { AuthUser } from '../auth/service.js';
import type { Ctx } from './ctx.js';
import { auditStandalone } from './audit.js';

export interface CommandMeta {
  user: AuthUser;
  requestId: string;
  ip: string | null;
  idempotencyKey: string | null;
}

export interface CommandOpts {
  operation: string;
  permission?: string | string[]; // any-of
  idempotency?: 'required' | 'optional' | 'none';
  successStatus?: number;
}

export interface CommandResult<T> {
  status: number;
  body: T;
  replay: boolean;
}

export function stableStringify(v: unknown): string {
  if (v === null || typeof v !== 'object') return JSON.stringify(v) ?? 'null';
  if (Array.isArray(v)) return '[' + v.map(stableStringify).join(',') + ']';
  const o = v as Record<string, unknown>;
  return '{' + Object.keys(o).filter((k) => o[k] !== undefined).sort().map((k) => JSON.stringify(k) + ':' + stableStringify(o[k])).join(',') + '}';
}

export function checkPermission(meta: CommandMeta, opts: { operation: string; permission?: string | string[] }) {
  if (!opts.permission) return;
  const needed = Array.isArray(opts.permission) ? opts.permission : [opts.permission];
  if (needed.some((p) => meta.user.permissions.has(p))) return;
  // Denied attempts are themselves security-relevant business events.
  auditStandalone({
    venueId: meta.user.venueId, userId: meta.user.id, action: 'security.permission_denied', entityType: 'operation',
    entityId: opts.operation, after: { required: needed, role: meta.user.roleCode }, deviceId: meta.user.deviceId,
    requestId: meta.requestId, ip: meta.ip,
  }).catch(() => {});
  throw E.forbidden(permissionDeniedMessage(needed[0]));
}

const RETRYABLE = new Set(['40P01', '40001']);

/**
 * The one way state-changing operations run: authorize -> (idempotency) -> single DB transaction -> commit.
 * The idempotency record is inserted in the same transaction as the business change, so a crash can never
 * leave a half-recorded command, and concurrent duplicates serialize on the unique key.
 */
export async function execute<T>(
  meta: CommandMeta,
  opts: CommandOpts,
  hashInput: unknown,
  fn: (ctx: Ctx) => Promise<T>,
): Promise<CommandResult<T>> {
  checkPermission(meta, opts);
  const mode = opts.idempotency ?? 'none';
  if (mode === 'required' && !meta.idempotencyKey) {
    throw E.badRequest('IDEMPOTENCY_KEY_REQUIRED', 'This action needs an Idempotency-Key header so retries are safe.');
  }
  const key = meta.idempotencyKey;
  if (key && (key.length < 8 || key.length > 128)) throw E.badRequest('IDEMPOTENCY_KEY_INVALID', 'Idempotency-Key must be 8-128 characters.');
  const hash = createHash('sha256').update(opts.operation + '|' + stableStringify(hashInput)).digest('hex');

  for (let attempt = 1; ; attempt++) {
    try {
      return await withTx(async (db) => {
        const now = clock.now();
        const ctx: Ctx = { db, user: meta.user, venueId: meta.user.venueId, deviceId: meta.user.deviceId, requestId: meta.requestId, ip: meta.ip, now };
        if (key && mode !== 'none') {
          const ins = await db.query(
            `INSERT INTO idempotency_keys (venue_id, user_id, key, operation, request_hash, expires_at)
             VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING`,
            [ctx.venueId, meta.user.id, key, opts.operation, hash, new Date(now.getTime() + config.idempotencyTtlHours * 3600_000)],
          );
          if (ins.rowCount === 0) {
            const prev = (await db.query(
              'SELECT operation, request_hash, response_status, response_body FROM idempotency_keys WHERE venue_id=$1 AND user_id=$2 AND key=$3',
              [ctx.venueId, meta.user.id, key],
            )).rows[0];
            if (!prev || prev.operation !== opts.operation || prev.request_hash !== hash) {
              throw E.unprocessable('IDEMPOTENCY_KEY_REUSED', 'This Idempotency-Key was already used for a different request.');
            }
            return { status: prev.response_status ?? 200, body: prev.response_body as T, replay: true };
          }
        }
        const body = await fn(ctx);
        const status = opts.successStatus ?? 200;
        if (key && mode !== 'none') {
          // Store the JSON-normalised body so a replay returns exactly what the first call returned.
          const normalised = JSON.parse(JSON.stringify(body ?? null));
          await db.query('UPDATE idempotency_keys SET response_status=$4, response_body=$5 WHERE venue_id=$1 AND user_id=$2 AND key=$3',
            [ctx.venueId, meta.user.id, key, status, JSON.stringify(normalised)]);
          return { status, body: normalised as T, replay: false };
        }
        return { status, body, replay: false };
      });
    } catch (e: any) {
      if (e && RETRYABLE.has(e.code) && attempt < 3) continue; // deadlock / serialization: safe to retry whole tx
      throw e;
    }
  }
}

/** Translate low-level database errors into messages staff can act on. */
export function translateDbError(e: any): AppError | null {
  if (!e || typeof e.code !== 'string') return null;
  if (e.code === '23505') {
    switch (e.constraint) {
      case 'sessions_one_live_per_customer':
        return E.conflict('CUSTOMER_ALREADY_ACTIVE', 'This customer already has an active session.');
      case 'equipment_one_open_assignment':
        return E.conflict('EQUIPMENT_UNAVAILABLE', 'That equipment was just assigned to another customer.');
      case 'equipment_venue_id_code_key':
        return E.conflict('EQUIPMENT_CODE_EXISTS', 'Equipment with that code already exists.');
      case 'users_email_uq':
        return E.conflict('EMAIL_EXISTS', 'A staff account with that email already exists.');
      case 'devices_venue_id_name_key':
        return E.conflict('DEVICE_NAME_EXISTS', 'A device with that name already exists.');
      default:
        return E.conflict('DUPLICATE', 'That record already exists.');
    }
  }
  if (e.code === '40P01' || e.code === '40001') return E.conflict('CONFLICT_RETRY', 'Another staff member is changing the same record. Please try again.');
  if (e.code === '23514') return E.unprocessable('CONSTRAINT_VIOLATION', 'That change is not allowed by the venue rules.');
  if (e.code === '23503') return E.unprocessable('REFERENCE_INVALID', 'A referenced record does not exist.');
  if (e.code === '22P02') return E.badRequest('INVALID_ID', 'One of the identifiers is not valid.');
  if (e.code === '23001' || e.code === 'P0001') return null;
  return null;
}
