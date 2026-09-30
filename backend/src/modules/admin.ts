import type { Ctx } from '../shared/ctx.js';
import { assertCan, can } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { emit } from '../shared/events.js';
import { SETTING_SCHEMAS, getSettings, type SettingKey, getVenue } from '../settings.js';
import { many, one, type Queryable } from '../db.js';
import { hashPassword } from '../auth/password.js';
import { config } from '../config.js';
import { toCamel, toCamelAll, lockOne } from './util.js';
import { getMaxCapacity, countOccupancy } from './capacity.js';
import { normalizePhone } from '../shared/phone.js';

// ---------- staff ----------
export async function listStaff(ctx: Ctx) {
  assertCan(ctx, 'staff.manage');
  return toCamelAll(await many(ctx.db,
    `SELECT u.id, u.email, u.full_name, u.status, u.last_login_at, u.created_at, r.id AS role_id, r.code AS role_code, r.name AS role_name, sp.phone, sp.employee_no
       FROM users u JOIN roles r ON r.id=u.role_id LEFT JOIN staff_profiles sp ON sp.user_id=u.id WHERE u.venue_id=$1 ORDER BY u.full_name`, [ctx.venueId]));
}

/** A manager can only grant roles whose permissions they already hold — no privilege escalation via staff.manage. */
async function assertCanGrantRole(ctx: Ctx, roleId: string) {
  const role = await one<any>(ctx.db, 'SELECT id, code FROM roles WHERE id=$1 AND venue_id=$2', [roleId, ctx.venueId]);
  if (!role) throw E.unprocessable('ROLE_INVALID', 'That role does not exist.');
  const perms = await many<{ permission_code: string }>(ctx.db, 'SELECT permission_code FROM role_permissions WHERE role_id=$1', [roleId]);
  const missing = perms.filter((p) => !ctx.user!.permissions.has(p.permission_code));
  if (missing.length) throw E.forbidden('You cannot assign a role with more permissions than your own.', 'ROLE_ESCALATION');
  return role;
}

export async function createStaff(ctx: Ctx, i: { email: string; fullName: string; password: string; roleId: string; phone?: string | null; employeeNo?: string | null }) {
  assertCan(ctx, 'staff.manage');
  if (i.password.length < config.auth.minPasswordLength) throw E.unprocessable('WEAK_PASSWORD', `Passwords must be at least ${config.auth.minPasswordLength} characters.`);
  const role = await assertCanGrantRole(ctx, i.roleId);
  const hash = await hashPassword(i.password);
  const r = await ctx.db.query(
    `INSERT INTO users (venue_id, email, password_hash, full_name, role_id, must_change_password, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,true,$6,$6) RETURNING id`,
    [ctx.venueId, i.email.trim().toLowerCase(), hash, i.fullName.trim(), i.roleId, ctx.now]);
  await ctx.db.query('INSERT INTO staff_profiles (user_id, display_name, phone, employee_no) VALUES ($1,$2,$3,$4)', [r.rows[0].id, i.fullName.trim(), i.phone ? normalizePhone(i.phone) : null, i.employeeNo ?? null]);
  await audit(ctx, { action: 'staff.created', entityType: 'user', entityId: r.rows[0].id, after: { email: i.email.toLowerCase(), role: role.code } });
  return { id: r.rows[0].id };
}

export async function updateStaff(ctx: Ctx, id: string, patch: { roleId?: string; status?: 'ACTIVE' | 'DISABLED'; fullName?: string }) {
  assertCan(ctx, 'staff.manage');
  const u = await lockOne<any>(ctx.db, `SELECT u.*, r.code AS role_code FROM users u JOIN roles r ON r.id=u.role_id WHERE u.id=$1 AND u.venue_id=$2 FOR NO KEY UPDATE OF u`, [id, ctx.venueId], 'Staff member');
  if (id === ctx.user!.id && (patch.roleId || patch.status)) throw E.forbidden('You cannot change your own role or status.');
  // A user can only modify accounts whose current role they could themselves grant.
  await assertCanGrantRole(ctx, u.role_id);
  let newRole = u.role_code;
  if (patch.roleId && patch.roleId !== u.role_id) {
    const role = await assertCanGrantRole(ctx, patch.roleId);
    newRole = role.code;
    await ctx.db.query('UPDATE users SET role_id=$2, updated_at=$3 WHERE id=$1', [id, patch.roleId, ctx.now]);
    await audit(ctx, { action: 'staff.permission_changed', entityType: 'user', entityId: id, before: { role: u.role_code }, after: { role: role.code } });
  }
  if (patch.status && patch.status !== u.status) {
    await ctx.db.query('UPDATE users SET status=$2, updated_at=$3 WHERE id=$1', [id, patch.status, ctx.now]);
    if (patch.status === 'DISABLED') await ctx.db.query('UPDATE auth_sessions SET revoked_at=$2 WHERE user_id=$1 AND revoked_at IS NULL', [id, ctx.now]);
    await audit(ctx, { action: 'staff.status_changed', entityType: 'user', entityId: id, before: { status: u.status }, after: { status: patch.status } });
  }
  if (patch.fullName) await ctx.db.query('UPDATE users SET full_name=$2, updated_at=$3 WHERE id=$1', [id, patch.fullName.trim(), ctx.now]);
  return { id, role: newRole };
}

export async function resetStaffPassword(ctx: Ctx, id: string, password: string) {
  assertCan(ctx, 'staff.manage');
  if (password.length < config.auth.minPasswordLength) throw E.unprocessable('WEAK_PASSWORD', `Passwords must be at least ${config.auth.minPasswordLength} characters.`);
  const u = await lockOne<any>(ctx.db, 'SELECT id, role_id FROM users WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Staff member');
  await assertCanGrantRole(ctx, u.role_id);
  await ctx.db.query('UPDATE users SET password_hash=$2, must_change_password=true, failed_login_count=0, locked_until=NULL, updated_at=$3 WHERE id=$1', [id, await hashPassword(password), ctx.now]);
  await ctx.db.query('UPDATE auth_sessions SET revoked_at=$2 WHERE user_id=$1 AND revoked_at IS NULL', [id, ctx.now]);
  await audit(ctx, { action: 'staff.password_reset', entityType: 'user', entityId: id });
  return { id };
}

// ---------- devices ----------
export async function listDevices(ctx: Ctx) {
  assertCan(ctx, 'device.manage');
  return toCamelAll(await many(ctx.db, `SELECT id, name, device_type, status, last_seen_at, registered_at FROM devices WHERE venue_id=$1 ORDER BY name`, [ctx.venueId]));
}
export async function registerDevice(ctx: Ctx, i: { name: string; deviceType: string }) {
  assertCan(ctx, 'device.manage');
  const r = await ctx.db.query(`INSERT INTO devices (venue_id, name, device_type, registered_by, registered_at) VALUES ($1,$2,$3,$4,$5) RETURNING id, name, device_type`,
    [ctx.venueId, i.name.trim(), i.deviceType, ctx.user?.id ?? null, ctx.now]);
  await audit(ctx, { action: 'device.registered', entityType: 'device', entityId: r.rows[0].id, after: { name: i.name, deviceType: i.deviceType } });
  return toCamel(r.rows[0]);
}
export async function updateDevice(ctx: Ctx, id: string, patch: { status?: 'ACTIVE' | 'DISABLED'; name?: string }) {
  assertCan(ctx, 'device.manage');
  const d = await lockOne<any>(ctx.db, 'SELECT * FROM devices WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId], 'Device');
  await ctx.db.query('UPDATE devices SET status=COALESCE($2,status), name=COALESCE($3,name) WHERE id=$1', [id, patch.status ?? null, patch.name?.trim() ?? null]);
  await audit(ctx, { action: 'device.updated', entityType: 'device', entityId: id, before: { status: d.status, name: d.name }, after: patch });
  return { id };
}

// ---------- settings / capacity ----------
export async function updateSettings(ctx: Ctx, patch: Record<string, unknown>) {
  assertCan(ctx, 'settings.manage');
  const before = await getSettings(ctx.db, ctx.venueId);
  const changed: Record<string, { before: unknown; after: unknown }> = {};
  for (const [key, value] of Object.entries(patch)) {
    const schema = (SETTING_SCHEMAS as any)[key];
    if (!schema) throw E.unprocessable('UNKNOWN_SETTING', `Unknown setting: ${key}.`);
    const parsed = schema.safeParse(value);
    if (!parsed.success) throw E.unprocessable('INVALID_SETTING', `Invalid value for ${key}: ${parsed.error.issues[0]?.message ?? 'invalid'}.`);
    await ctx.db.query(
      `INSERT INTO system_settings (venue_id, key, value, updated_at, updated_by) VALUES ($1,$2,$3,$4,$5)
       ON CONFLICT (venue_id, key) DO UPDATE SET value=EXCLUDED.value, updated_at=EXCLUDED.updated_at, updated_by=EXCLUDED.updated_by`,
      [ctx.venueId, key, JSON.stringify(parsed.data), ctx.now, ctx.user?.id ?? null]);
    changed[key] = { before: (before as any)[key], after: parsed.data };
  }
  if (Object.keys(changed).length) {
    await audit(ctx, { action: 'settings.changed', entityType: 'settings', entityId: ctx.venueId, before: Object.fromEntries(Object.entries(changed).map(([k, v]) => [k, v.before])), after: Object.fromEntries(Object.entries(changed).map(([k, v]) => [k, v.after])) });
    await emit(ctx, 'SETTINGS_CHANGED', 'venue', ctx.venueId, { keys: Object.keys(changed) });
  }
  return getSettings(ctx.db, ctx.venueId);
}

export async function setCapacity(ctx: Ctx, maxCapacity: number, reason?: string | null) {
  assertCan(ctx, 'capacity.manage');
  const prev = await getMaxCapacity(ctx.db, ctx.venueId, ctx.now);
  await ctx.db.query('INSERT INTO capacity_rules (venue_id, max_capacity, effective_from, created_by, created_at) VALUES ($1,$2,$3,$4,$3)', [ctx.venueId, maxCapacity, ctx.now, ctx.user?.id ?? null]);
  await audit(ctx, { action: 'capacity.changed', entityType: 'venue', entityId: ctx.venueId, before: { maxCapacity: prev }, after: { maxCapacity }, reason: reason ?? null });
  const occupancy = await countOccupancy(ctx.db, ctx.venueId);
  await emit(ctx, 'CAPACITY_CHANGED', 'venue', ctx.venueId, { occupancy, max: maxCapacity });
  return { maxCapacity, occupancy };
}

// ---------- audit + notifications ----------
export async function listAudit(ctx: Ctx, opts: { action?: string; entityType?: string; entityId?: string; actorId?: string; from?: Date; to?: Date; before?: number; limit?: number }) {
  assertCan(ctx, 'audit.read');
  const params: unknown[] = [ctx.venueId];
  const w: string[] = ['a.venue_id=$1'];
  const add = (sql: string, v: unknown) => { params.push(v); w.push(sql.replace('?', `$${params.length}`)); };
  if (opts.action) add(`a.action LIKE ?`, opts.action.replace(/[%_\\]/g, (m) => '\\' + m) + '%');
  if (opts.entityType) add('a.entity_type = ?', opts.entityType);
  if (opts.entityId) add('a.entity_id = ?', opts.entityId);
  if (opts.actorId) add('a.actor_user_id = ?', opts.actorId);
  if (opts.from) add('a.created_at >= ?', opts.from);
  if (opts.to) add('a.created_at < ?', opts.to);
  if (opts.before) add('a.id < ?', opts.before);
  params.push(Math.min(opts.limit ?? 100, 500));
  const rows = await many<any>(ctx.db,
    `SELECT a.id, a.action, a.entity_type, a.entity_id, a.before_data, a.after_data, a.reason, a.request_id, a.ip, a.created_at, u.full_name AS actor_name, a.actor_user_id, d.name AS device_name
       FROM audit_logs a LEFT JOIN users u ON u.id=a.actor_user_id LEFT JOIN devices d ON d.id=a.device_id
      WHERE ${w.join(' AND ')} ORDER BY a.id DESC LIMIT $${params.length}`, params);
  return toCamelAll(rows);
}

export async function listNotifications(ctx: Ctx, opts: { status?: string }) {
  assertCan(ctx, 'session.read');
  return toCamelAll(await many(ctx.db,
    `SELECT id, type, severity, title, body, entity_type, entity_id, status, created_at, acknowledged_at FROM notifications
      WHERE venue_id=$1 AND ($2::text IS NULL OR status=$2) ORDER BY created_at DESC LIMIT 100`, [ctx.venueId, opts.status ?? null]));
}

export async function ackNotification(ctx: Ctx, id: string, outcome: 'ACKNOWLEDGED' | 'RESOLVED') {
  assertCan(ctx, 'session.read');
  const r = await ctx.db.query(
    `UPDATE notifications SET status=$3, acknowledged_by=COALESCE(acknowledged_by,$4), acknowledged_at=COALESCE(acknowledged_at,$5), resolved_at=CASE WHEN $3='RESOLVED' THEN $5 ELSE resolved_at END
      WHERE id=$1 AND venue_id=$2 AND status <> 'RESOLVED' RETURNING id, status`, [id, ctx.venueId, outcome, ctx.user?.id ?? null, ctx.now]);
  if (!r.rows[0]) throw E.notFound('Notification');
  await emit(ctx, 'NOTIFICATION_UPDATED', 'notification', id, { notificationId: id, status: outcome });
  return toCamel(r.rows[0]);
}
