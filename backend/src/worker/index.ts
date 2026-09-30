import { pool, many, withTx } from '../db.js';
import { config } from '../config.js';
import { clock } from '../shared/clock.js';
import { processSessionTimers } from '../modules/sessions.js';
import { processOutbox } from './outbox.js';
import { storage } from '../storage/index.js';
import { getSettings } from '../settings.js';

/** Photo/attachment retention policy job: expired files are deleted from storage and marked EXPIRED. */
export async function runRetention(now = clock.now()) {
  const photos = await many<any>(pool, `SELECT id, venue_id, storage_key FROM customer_photos WHERE status='ACTIVE' AND retention_until IS NOT NULL AND retention_until <= $1 LIMIT 200`, [now]);
  for (const p of photos) {
    await withTx(async (db) => {
      const r = await db.query(`UPDATE customer_photos SET status='EXPIRED', deleted_at=$2 WHERE id=$1 AND status='ACTIVE' RETURNING id`, [p.id, now]);
      if (!r.rowCount) return;
      await storage.delete(p.storage_key);
      await db.query(`INSERT INTO audit_logs (venue_id, action, entity_type, entity_id, reason, request_id, created_at) VALUES ($1,'photo.retention_expired','customer_photo',$2,'Retention period elapsed','worker',$3)`, [p.venue_id, p.id, now]);
    }).catch((e) => console.error('retention failed', p.id, (e as Error).message));
  }
  const venues = await many<{ id: string }>(pool, 'SELECT id FROM venues');
  let attachments = 0;
  for (const v of venues) {
    const days = (await getSettings(pool, v.id)).retention.incidentAttachmentDays;
    if (!days) continue;
    const old = await many<any>(pool, `SELECT id, storage_key FROM incident_attachments WHERE venue_id=$1 AND status='ACTIVE' AND uploaded_at < $2 LIMIT 100`, [v.id, new Date(now.getTime() - days * 86400_000)]);
    for (const a of old) {
      await storage.delete(a.storage_key);
      await pool.query(`UPDATE incident_attachments SET status='DELETED' WHERE id=$1`, [a.id]);
      attachments++;
    }
  }
  return { photosExpired: photos.length, attachmentsDeleted: attachments };
}

export async function runHousekeeping(now = clock.now()) {
  await pool.query('DELETE FROM idempotency_keys WHERE expires_at < $1', [now]);
  await pool.query('DELETE FROM auth_sessions WHERE expires_at < $1 - interval \'7 days\'', [now]);
  // TODO(phase 2): payment reconciliation against provider statements; equipment maintenance reminders; scheduled daily report delivery.
}

let ticking = false;
let lastHousekeeping = 0;

/** One worker pass: timers for every venue, then the outbox. Both are idempotent and safe to overlap. */
export async function tick() {
  if (ticking) return;
  ticking = true;
  try {
    const venues = await many<{ id: string }>(pool, `SELECT id FROM venues WHERE status='ACTIVE'`);
    for (const v of venues) await processSessionTimers(v.id).catch((e) => console.error('timers failed', (e as Error).message));
    let n;
    do { n = await processOutbox(); } while (n >= config.worker.outboxBatch);
    if (Date.now() - lastHousekeeping > 10 * 60_000) {
      lastHousekeeping = Date.now();
      await runRetention().catch((e) => console.error('retention failed', (e as Error).message));
      await runHousekeeping().catch((e) => console.error('housekeeping failed', (e as Error).message));
    }
  } finally {
    ticking = false;
  }
}

export function startWorker(log: { info: (m: string) => void; error: (m: string) => void } = console as any) {
  log.info(`worker started (tick ${config.worker.tickMs}ms)`);
  const t = setInterval(() => tick().catch((e) => log.error('worker tick failed: ' + (e as Error).message)), config.worker.tickMs);
  tick().catch(() => {});
  return () => clearInterval(t);
}
