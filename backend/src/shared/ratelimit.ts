import { E } from './errors.js';
import { config } from '../config.js';

/**
 * Small in-process sliding-window limiter (per API process). Good enough for a single-venue deployment;
 * swap the store for Redis if the API is ever scaled horizontally (see docs/ARCHITECTURE.md).
 */
const hits = new Map<string, number[]>();
let enabled = config.rateLimit.enabled;
let lastSweep = Date.now();

export function setRateLimitEnabled(v: boolean) {
  enabled = v;
  hits.clear();
}

export function rateLimit(bucket: string, key: string, max: number, windowMs: number, message?: string) {
  if (!enabled) return;
  const now = Date.now();
  if (now - lastSweep > 60_000) {
    for (const [k, v] of hits) if (!v.length || now - v[v.length - 1] > 10 * 60_000) hits.delete(k);
    lastSweep = now;
  }
  const id = `${bucket}:${key}`;
  const arr = (hits.get(id) ?? []).filter((t) => now - t < windowMs);
  if (arr.length >= max) {
    hits.set(id, arr);
    throw E.tooMany(message);
  }
  arr.push(now);
  hits.set(id, arr);
}
