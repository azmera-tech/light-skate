import { mkdir, writeFile, readFile, unlink, stat } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { config } from '../config.js';

/**
 * Object storage abstraction. Two drivers: local-disk (stores outside any web-served path with
 * owner-only permissions, for local dev) and Supabase Storage (production — see SupabaseDriver
 * below). Selected via STORAGE_DRIVER; the rest of the app never touches paths or URLs directly.
 */
export interface StorageDriver {
  put(key: string, data: Buffer): Promise<void>;
  get(key: string): Promise<Buffer>;
  delete(key: string): Promise<void>;
  exists(key: string): Promise<boolean>;
}

class LocalDriver implements StorageDriver {
  private root = resolve(config.storage.dir);
  private path(key: string) {
    const p = resolve(join(this.root, key));
    if (!p.startsWith(this.root + sep)) throw new Error('invalid storage key');
    return p;
  }
  async put(key: string, data: Buffer) {
    const p = this.path(key);
    await mkdir(dirname(p), { recursive: true, mode: 0o700 });
    await writeFile(p, data, { mode: 0o600, flag: 'wx' }); // never overwrite
  }
  get(key: string) {
    return readFile(this.path(key));
  }
  async delete(key: string) {
    await unlink(this.path(key)).catch((e) => {
      if (e.code !== 'ENOENT') throw e;
    });
  }
  async exists(key: string) {
    return stat(this.path(key)).then(() => true, () => false);
  }
}

/**
 * Supabase Storage via its plain REST API (no @supabase/supabase-js dependency — this backend
 * stays on raw `fetch`/`pg` throughout). Uses the `service_role` key, which bypasses Storage's
 * RLS/policies entirely (this server is the only thing ever allowed to touch the bucket; the
 * anon/publishable key is never used here, same reasoning as migration 009's deny-all RLS).
 */
class SupabaseDriver implements StorageDriver {
  private base = `${config.storage.supabaseUrl.replace(/\/+$/, '')}/storage/v1`;
  private bucket = config.storage.supabaseBucket;
  private headers() {
    return {
      Authorization: `Bearer ${config.storage.supabaseServiceRoleKey}`,
      apikey: config.storage.supabaseServiceRoleKey,
    };
  }
  async put(key: string, data: Buffer) {
    const res = await fetch(`${this.base}/object/${this.bucket}/${key}`, {
      method: 'POST',
      headers: { ...this.headers(), 'Content-Type': 'application/octet-stream', 'x-upsert': 'false' },
      body: new Uint8Array(data),
    });
    if (!res.ok) throw new Error(`Supabase Storage upload failed (${res.status}): ${await res.text()}`);
  }
  async get(key: string) {
    const res = await fetch(`${this.base}/object/${this.bucket}/${key}`, { headers: this.headers() });
    if (!res.ok) throw new Error(`Supabase Storage download failed (${res.status})`);
    return Buffer.from(await res.arrayBuffer());
  }
  async delete(key: string) {
    const res = await fetch(`${this.base}/object/${this.bucket}/${key}`, { method: 'DELETE', headers: this.headers() });
    if (!res.ok && res.status !== 404) throw new Error(`Supabase Storage delete failed (${res.status})`);
  }
  async exists(key: string) {
    const res = await fetch(`${this.base}/object/info/${this.bucket}/${key}`, { headers: this.headers() });
    return res.ok;
  }
}

export const storage: StorageDriver = config.storage.driver === 'supabase' ? new SupabaseDriver() : new LocalDriver();

/** Server-generated storage key. User-provided names are never used. */
export function newStorageKey(venueId: string, kind: 'customer' | 'incident' | 'maintenance' | 'shoe', ext: string) {
  return `${venueId}/${kind}/${randomUUID()}.${ext}`;
}

// ---- short-lived signed URLs (for contexts that cannot send an Authorization header) ----
export function signFileToken(fileId: string, venueId: string, exp: number): string {
  return createHmac('sha256', config.signingSecret).update(`${fileId}.${venueId}.${exp}`).digest('base64url');
}

export function verifyFileToken(fileId: string, venueId: string, exp: number, sig: string): boolean {
  if (!Number.isFinite(exp) || exp * 1000 < Date.now()) return false;
  const expected = Buffer.from(signFileToken(fileId, venueId, exp));
  const given = Buffer.from(sig ?? '');
  return expected.length === given.length && timingSafeEqual(expected, given);
}
