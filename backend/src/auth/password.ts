import { randomBytes, scrypt as _scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
const scrypt = promisify(_scrypt) as (pw: string, salt: Buffer, len: number, opts: object) => Promise<Buffer>;

const N = 16384, r = 8, p = 1, KEYLEN = 64;

export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(pw, salt, KEYLEN, { N, r, p, maxmem: 64 * 1024 * 1024 });
  return `scrypt$${N}$${r}$${p}$${salt.toString('base64')}$${key.toString('base64')}`;
}

export async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [alg, n, rr, pp, saltB64, keyB64] = stored.split('$');
  if (alg !== 'scrypt') return false;
  const salt = Buffer.from(saltB64, 'base64');
  const expected = Buffer.from(keyB64, 'base64');
  const actual = await scrypt(pw, salt, expected.length, { N: Number(n), r: Number(rr), p: Number(pp), maxmem: 64 * 1024 * 1024 });
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function newToken(): string {
  return randomBytes(32).toString('base64url');
}
export function hashToken(t: string): string {
  return createHash('sha256').update(t).digest('hex');
}
