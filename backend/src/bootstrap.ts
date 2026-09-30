import type { Queryable, Db } from './db.js';
import { PERMISSIONS, DEFAULT_ROLES } from './permissions.js';
import { hashPassword } from './auth/password.js';

export async function ensurePermissions(q: Queryable) {
  for (const [code, description] of Object.entries(PERMISSIONS)) {
    await q.query('INSERT INTO permissions (code, description) VALUES ($1,$2) ON CONFLICT (code) DO UPDATE SET description=EXCLUDED.description', [code, description]);
  }
}

export const DEFAULT_WAIVER_TITLE = 'Skating rules & release of liability';
// TEMPLATE ONLY: venue owners must have this text reviewed by local legal counsel before use.
export const DEFAULT_WAIVER_BODY = `SKATING RULES
1. Follow staff instructions at all times and skate in the direction indicated.
2. Wear the rental skates and any protective equipment provided. Report damaged equipment immediately.
3. No running, racing, pushing or reckless skating. No food or drink on the rink.
4. Children under 12 must be supervised by a responsible adult.

ASSUMPTION OF RISK
Skating involves inherent risks including falls and collisions that may cause injury. I understand these risks and choose to participate voluntarily.

PERSONAL DATA
The venue records my name, phone number, photograph and visit details to identify me during my visit, operate the venue safely, and keep records. My photograph is kept only for the period set by the venue. I may ask the venue to correct or erase my personal data.

For a participant under 18, a parent or legal guardian must accept this waiver on their behalf.`;

export async function createVenue(db: Queryable, opts: { name: string; slug: string; timezone?: string; capacity?: number }) {
  const v = (await db.query(`INSERT INTO venues (name, slug, timezone) VALUES ($1,$2,$3) RETURNING id`, [opts.name, opts.slug, opts.timezone ?? 'Africa/Addis_Ababa'])).rows[0];
  for (const r of DEFAULT_ROLES) {
    const role = (await db.query(`INSERT INTO roles (venue_id, code, name) VALUES ($1,$2,$3) RETURNING id`, [v.id, r.code, r.name])).rows[0];
    for (const p of r.permissions) await db.query('INSERT INTO role_permissions (role_id, permission_code) VALUES ($1,$2)', [role.id, p]);
  }
  await db.query('INSERT INTO capacity_rules (venue_id, max_capacity, effective_from) VALUES ($1,$2, now() - interval \'1 day\')', [v.id, opts.capacity ?? 60]);
  const w = (await db.query(`INSERT INTO waivers (venue_id, code, name) VALUES ($1,'STANDARD','Skating rules & waiver') RETURNING id`, [v.id])).rows[0];
  await db.query(`INSERT INTO waiver_versions (waiver_id, venue_id, version, title, body, is_current) VALUES ($1,$2,1,$3,$4,true)`, [w.id, v.id, DEFAULT_WAIVER_TITLE, DEFAULT_WAIVER_BODY]);
  // Default price list (ETB minor units: 200 ETB = 20000)
  const sessions: [string, number, number][] = [['Quick Skate', 30, 10000], ['Standard', 60, 20000], ['Extended', 90, 28000], ['Two Hours', 120, 35000]];
  let order = 0;
  for (const [name, mins, price] of sessions) {
    await db.query(`INSERT INTO pricing_rules (venue_id, kind, name, duration_minutes, price_minor, sort_order) VALUES ($1,'SESSION',$2,$3,$4,$5)`, [v.id, name, mins, price, order++]);
  }
  const ext: [number, number][] = [[15, 5000], [30, 10000], [60, 20000]];
  for (const [mins, price] of ext) await db.query(`INSERT INTO pricing_rules (venue_id, kind, name, duration_minutes, price_minor, sort_order) VALUES ($1,'EXTENSION',$2,$3,$4,$5)`, [v.id, `+${mins} min`, mins, price, order++]);
  return v.id as string;
}

export async function createUser(db: Queryable, venueId: string, u: { email: string; fullName: string; password: string; roleCode: string }) {
  const role = (await db.query('SELECT id FROM roles WHERE venue_id=$1 AND code=$2', [venueId, u.roleCode])).rows[0];
  if (!role) throw new Error(`Unknown role ${u.roleCode}`);
  const r = (await db.query(
    `INSERT INTO users (venue_id, email, password_hash, full_name, role_id) VALUES ($1,$2,$3,$4,$5) RETURNING id`,
    [venueId, u.email.toLowerCase(), await hashPassword(u.password), u.fullName, role.id])).rows[0];
  await db.query('INSERT INTO staff_profiles (user_id, display_name) VALUES ($1,$2)', [r.id, u.fullName]);
  return r.id as string;
}
