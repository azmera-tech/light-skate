import type { Db } from '../db.js';
import type { AuthUser } from '../auth/service.js';
import { E, permissionDeniedMessage } from './errors.js';

/** Everything a business operation needs, bound to one open transaction. */
export interface Ctx {
  db: Db;
  /** null for system actors (background worker). */
  user: AuthUser | null;
  venueId: string;
  deviceId: string | null;
  requestId: string;
  ip: string | null;
  now: Date;
}

export function can(ctx: Ctx, perm: string): boolean {
  return ctx.user ? ctx.user.permissions.has(perm) : true; // system actor is trusted
}

export function assertCan(ctx: Ctx, perm: string) {
  if (!can(ctx, perm)) throw E.forbidden(permissionDeniedMessage(perm));
}

export const actorId = (ctx: Ctx) => ctx.user?.id ?? null;
