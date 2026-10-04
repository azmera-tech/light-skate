import { mkdir, writeFile, readFile, unlink, stat } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { config } from '../config.js';

/**
 * Object storage abstraction. Only the local-disk driver is implemented; it stores outside any
 * web-served path with owner-only permissions. A production S3/R2 driver implements the same interface
 * (see docs/DEPLOYMENT.md) — the rest of the app never touches paths or URLs directly.
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

export const storage: StorageDriver = new LocalDriver();

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
