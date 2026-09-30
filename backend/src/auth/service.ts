import { pool, one, many, type Queryable } from '../db.js';
import { config } from '../config.js';
import { clock } from '../shared/clock.js';
import { AppError, E } from '../shared/errors.js';
import { hashToken, newToken, verifyPassword, hashPassword } from './password.js';

export interface AuthUser {
  id: string;
  venueId: string;
  email: string;
  fullName: string;
  roleId: string;
  roleCode: string;
  permissions: Set<string>;
  deviceId: string | null;
  authSessionId: string;
}

// A dummy hash so unknown emails cost the same time as wrong passwords (no user enumeration by timing).
let dummyHash: string | null = null;

export async function login(args: { email: string; password: string; deviceId?: string | null; ip?: string | null; userAgent?: string | null }) {
  const now = clock.now();
  const user = await one<any>(
    pool,
    `SELECT u.*, r.code AS role_code FROM users u JOIN roles r ON r.id = u.role_id WHERE lower(u.email) = lower($1)`,
    [args.email],
  );
  if (!user) {
    dummyHash ??= await hashPassword('dummy-password-for-timing');
    await verifyPassword(args.password, dummyHash);
    await writeLoginAudit(null, null, 'auth.login_failed', { email: args.email, reason: 'unknown_user' }, args.ip);
    throw new AppError(401, 'INVALID_CREDENTIALS', 'Incorrect email or password.');
  }
  if (user.status !== 'ACTIVE') {
    await writeLoginAudit(user.venue_id, user.id, 'auth.login_failed', { reason: 'disabled' }, args.ip);
    throw new AppError(403, 'ACCOUNT_DISABLED', 'This account has been disabled. Please contact your manager.');
  }
  if (user.locked_until && new Date(user.locked_until) > now) {
    await writeLoginAudit(user.venue_id, user.id, 'auth.login_blocked', { reason: 'locked' }, args.ip);
    throw new AppError(423, 'ACCOUNT_LOCKED', 'Too many failed attempts. This account is temporarily locked; try again later.');
  }
  const ok = await verifyPassword(args.password, user.password_hash);
  if (!ok) {
    const failed = user.failed_login_count + 1;
    const lock = failed >= config.auth.maxFailedLogins ? new Date(now.getTime() + config.auth.lockoutMinutes * 60_000) : null;
    await pool.query('UPDATE users SET failed_login_count = $2, locked_until = $3 WHERE id = $1', [user.id, lock ? 0 : failed, lock]);
    await writeLoginAudit(user.venue_id, user.id, 'auth.login_failed', { reason: 'bad_password', locked: !!lock }, args.ip);
    throw new AppError(401, 'INVALID_CREDENTIALS', 'Incorrect email or password.');
  }

  let deviceId: string | null = null;
  if (args.deviceId) {
    const d = await one<{ id: string }>(pool, `SELECT id FROM devices WHERE id = $1 AND venue_id = $2 AND status = 'ACTIVE'`, [args.deviceId, user.venue_id]);
    deviceId = d?.id ?? null;
  }
  const token = newToken();
  const expires = new Date(now.getTime() + config.auth.sessionTtlHours * 3600_000);
  await pool.query(
    `INSERT INTO auth_sessions (user_id, venue_id, device_id, token_hash, created_at, last_seen_at, expires_at, ip, user_agent)
     VALUES ($1,$2,$3,$4,$5,$5,$6,$7,$8)`,
    [user.id, user.venue_id, deviceId, hashToken(token), now, expires, args.ip ?? null, (args.userAgent ?? '').slice(0, 200)],
  );
  await pool.query('UPDATE users SET failed_login_count = 0, locked_until = NULL, last_login_at = $2 WHERE id = $1', [user.id, now]);
  await writeLoginAudit(user.venue_id, user.id, 'auth.login', { deviceId }, args.ip, deviceId);
  return { token, expiresAt: expires.toISOString() };
}

export async function logout(authSessionId: string) {
  await pool.query('UPDATE auth_sessions SET revoked_at = $2 WHERE id = $1', [authSessionId, clock.now()]);
}

/** Resolve a bearer token to an authenticated user with server-derived permissions. */
export async function resolveToken(token: string, deviceHeader: string | null): Promise<AuthUser | null> {
  const now = clock.now();
  const row = await one<any>(
    pool,
    `SELECT s.id AS session_id, s.device_id AS session_device, u.id, u.venue_id, u.email, u.full_name, u.role_id, u.status,
            r.code AS role_code,
            COALESCE((SELECT array_agg(rp.permission_code) FROM role_permissions rp WHERE rp.role_id = u.role_id), '{}') AS perms
       FROM auth_sessions s
       JOIN users u ON u.id = s.user_id
       JOIN roles r ON r.id = u.role_id
      WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > $2`,
    [hashToken(token), now],
  );
  if (!row || row.status !== 'ACTIVE') return null;
  // Device: a registered, active device of the same venue. Header wins over login-time device.
  let deviceId: string | null = row.session_device;
  if (deviceHeader && /^[0-9a-f-]{36}$/i.test(deviceHeader)) {
    const d = await one<{ id: string }>(pool, `SELECT id FROM devices WHERE id = $1 AND venue_id = $2 AND status = 'ACTIVE'`, [deviceHeader, row.venue_id]);
    if (d) {
      deviceId = d.id;
      // last_seen is best-effort and throttled to once a minute per device
      pool.query(`UPDATE devices SET last_seen_at = $2 WHERE id = $1 AND (last_seen_at IS NULL OR last_seen_at < $2::timestamptz - interval '1 minute')`, [d.id, now]).catch(() => {});
    }
  }
  return {
    id: row.id,
    venueId: row.venue_id,
    email: row.email,
    fullName: row.full_name,
    roleId: row.role_id,
    roleCode: row.role_code,
    permissions: new Set<string>(row.perms),
    deviceId,
    authSessionId: row.session_id,
  };
}

async function writeLoginAudit(venueId: string | null, userId: string | null, action: string, after: object, ip?: string | null, deviceId?: string | null) {
  await pool.query(
    `INSERT INTO audit_logs (venue_id, actor_user_id, action, entity_type, entity_id, after_data, device_id, ip)
     VALUES ($1,$2,$3,'user',$4,$5,$6,$7)`,
    [venueId, userId, action, userId, JSON.stringify(after), deviceId ?? null, ip ?? null],
  );
}

export async function listRolesForVenue(q: Queryable, venueId: string) {
  return many(q, `SELECT r.id, r.code, r.name,
      COALESCE((SELECT array_agg(permission_code ORDER BY permission_code) FROM role_permissions WHERE role_id = r.id), '{}') AS permissions
      FROM roles r WHERE r.venue_id = $1 ORDER BY r.name`, [venueId]);
}
