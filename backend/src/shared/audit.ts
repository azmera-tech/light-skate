import type { Ctx } from './ctx.js';
import { pool } from '../db.js';

export interface AuditInput {
  action: string;
  entityType: string;
  entityId?: string | null;
  before?: unknown;
  after?: unknown;
  reason?: string | null;
}

/** Business audit log entry, written inside the caller's transaction so it commits (or rolls back) with the change. */
export async function audit(ctx: Ctx, a: AuditInput) {
  await ctx.db.query(
    `INSERT INTO audit_logs (venue_id, actor_user_id, action, entity_type, entity_id, before_data, after_data, reason, device_id, request_id, ip, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
    [
      ctx.venueId, ctx.user?.id ?? null, a.action, a.entityType, a.entityId ?? null,
      a.before === undefined ? null : JSON.stringify(a.before),
      a.after === undefined ? null : JSON.stringify(a.after),
      a.reason ?? null, ctx.deviceId, ctx.requestId, ctx.ip, ctx.now,
    ],
  );
}

/** Audit entry outside any business transaction (denied attempts, login failures). */
export async function auditStandalone(p: {
  venueId: string | null; userId: string | null; action: string; entityType: string; entityId?: string | null;
  after?: unknown; deviceId?: string | null; requestId?: string | null; ip?: string | null; reason?: string | null;
}) {
  await pool.query(
    `INSERT INTO audit_logs (venue_id, actor_user_id, action, entity_type, entity_id, after_data, reason, device_id, request_id, ip)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [p.venueId, p.userId, p.action, p.entityType, p.entityId ?? null, p.after === undefined ? null : JSON.stringify(p.after),
      p.reason ?? null, p.deviceId ?? null, p.requestId ?? null, p.ip ?? null],
  );
}
