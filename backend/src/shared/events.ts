import type { Ctx } from './ctx.js';

/**
 * Domain events go into immutable history tables (session_events, payment_events, ...),
 * and operational notifications go into the outbox. Both are written in the same
 * transaction as the state change they describe.
 */
export async function recordSessionEvent(
  ctx: Ctx,
  s: { id: string; visit_id: string },
  type: string,
  opts: { from?: string | null; to?: string | null; meta?: Record<string, unknown>; at?: Date } = {},
) {
  const r = await ctx.db.query(
    `INSERT INTO session_events (venue_id, session_id, visit_id, event_type, from_status, to_status, actor_user_id, device_id, occurred_at, metadata, request_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT DO NOTHING RETURNING id`,
    [ctx.venueId, s.id, s.visit_id, type, opts.from ?? null, opts.to ?? null, ctx.user?.id ?? null, ctx.deviceId,
      opts.at ?? ctx.now, JSON.stringify(opts.meta ?? {}), ctx.requestId],
  );
  return r.rowCount === 1;
}

export async function recordPaymentEvent(ctx: Ctx, paymentId: string, type: string, opts: { from?: string | null; to?: string | null; meta?: Record<string, unknown> } = {}) {
  await ctx.db.query(
    `INSERT INTO payment_events (venue_id, payment_id, event_type, from_status, to_status, actor_user_id, device_id, occurred_at, metadata, request_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [ctx.venueId, paymentId, type, opts.from ?? null, opts.to ?? null, ctx.user?.id ?? null, ctx.deviceId, ctx.now, JSON.stringify(opts.meta ?? {}), ctx.requestId],
  );
}

export async function recordEquipmentEvent(
  ctx: Ctx, equipmentId: string, type: string,
  opts: { from?: string | null; to?: string | null; sessionId?: string | null; meta?: Record<string, unknown> } = {},
) {
  await ctx.db.query(
    `INSERT INTO equipment_events (venue_id, equipment_id, event_type, from_status, to_status, session_id, actor_user_id, device_id, occurred_at, metadata, request_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
    [ctx.venueId, equipmentId, type, opts.from ?? null, opts.to ?? null, opts.sessionId ?? null, ctx.user?.id ?? null, ctx.deviceId, ctx.now,
      JSON.stringify(opts.meta ?? {}), ctx.requestId],
  );
}

export async function recordIncidentEvent(ctx: Ctx, incidentId: string, type: string, opts: { from?: string | null; to?: string | null; meta?: Record<string, unknown> } = {}) {
  await ctx.db.query(
    `INSERT INTO incident_events (venue_id, incident_id, event_type, from_status, to_status, actor_user_id, device_id, occurred_at, metadata, request_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [ctx.venueId, incidentId, type, opts.from ?? null, opts.to ?? null, ctx.user?.id ?? null, ctx.deviceId, ctx.now, JSON.stringify(opts.meta ?? {}), ctx.requestId],
  );
}

/** Outbox: delivery of realtime/notification side effects happens after commit, by the worker. */
export async function emit(ctx: Ctx, type: string, aggregateType: string, aggregateId: string | null, payload: Record<string, unknown> = {}) {
  await ctx.db.query(
    `INSERT INTO outbox_events (venue_id, event_type, aggregate_type, aggregate_id, payload, created_at, available_at)
     VALUES ($1,$2,$3,$4,$5,$6,$6)`,
    [ctx.venueId, type, aggregateType, aggregateId, JSON.stringify({ ...payload, at: ctx.now.toISOString() }), ctx.now],
  );
}
