/**
 * Production provisioning: the real venue plus one staff account per role. No demo customers, sessions or payments.
 * Idempotent — re-running creates only what is missing and never changes an existing password unless
 * PROVISION_RESET_PASSWORDS=true. Usage:
 *   PROVISION_PASSWORD='...' npm run provision
 */
import { pool, one, closePool } from './db.js';
import { migrate } from './migrate.js';
import { ensurePermissions, syncDefaultRoles, createVenue, createUser } from './bootstrap.js';
import { hashPassword } from './auth/password.js';
import { config } from './config.js';

const VENUE = { name: process.env.PROVISION_VENUE_NAME || 'Light Skate', slug: process.env.PROVISION_VENUE_SLUG || 'light-skate', timezone: 'Africa/Addis_Ababa', capacity: 60 };

export const ACCOUNTS: { email: string; fullName: string; role: string }[] = [
  { email: 'lightskateowner@gmail.com', fullName: 'Light Skate Owner', role: 'OWNER' },
  { email: 'lightskateadmin@gmail.com', fullName: 'Light Skate Admin', role: 'ADMIN' },
  { email: 'lightskatemanager@gmail.com', fullName: 'Light Skate Manager', role: 'MANAGER' },
  { email: 'lightskatesupervisor@gmail.com', fullName: 'Light Skate Supervisor', role: 'SUPERVISOR' },
  { email: 'lightskatefrontdesk@gmail.com', fullName: 'Light Skate Front Desk', role: 'FRONT_DESK' },
  { email: 'lightskaterental@gmail.com', fullName: 'Light Skate Rental Staff', role: 'RENTAL_STAFF' },
  { email: 'lightskateplaystation@gmail.com', fullName: 'Light Skate PlayStation Manager', role: 'PLAYSTATION_MANAGER' },
];

async function main() {
  const password = process.env.PROVISION_PASSWORD;
  if (!password || password.length < config.auth.minPasswordLength) throw new Error(`Set PROVISION_PASSWORD (at least ${config.auth.minPasswordLength} characters).`);
  const reset = process.env.PROVISION_RESET_PASSWORDS === 'true';
  await migrate();
  await ensurePermissions(pool);
  let venue = await one<{ id: string }>(pool, 'SELECT id FROM venues WHERE slug=$1', [VENUE.slug]);
  if (!venue) {
    venue = { id: await createVenue(pool, VENUE) };
    console.log(`created venue "${VENUE.name}"`);
  } else {
    console.log(`venue "${VENUE.name}" already exists`);
  }
  await syncDefaultRoles(pool);
  for (const a of ACCOUNTS) {
    const existing = await one<{ id: string }>(pool, 'SELECT id FROM users WHERE lower(email)=lower($1)', [a.email]);
    if (!existing) {
      await createUser(pool, venue.id, { email: a.email, fullName: a.fullName, password, roleCode: a.role });
      console.log(`created ${a.role.padEnd(20)} ${a.email}`);
    } else if (reset) {
      await pool.query('UPDATE users SET password_hash=$2, failed_login_count=0, locked_until=NULL WHERE id=$1', [existing.id, await hashPassword(password)]);
      await pool.query('UPDATE auth_sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL', [existing.id]);
      console.log(`reset password for ${a.email}`);
    } else {
      console.log(`exists              ${a.email}`);
    }
  }
}

main().catch((e) => { console.error(e.message ?? e); process.exitCode = 1; }).finally(closePool);
