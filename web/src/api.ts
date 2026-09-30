/**
 * Thin API client. It carries the bearer token + registered device id, attaches an Idempotency-Key to every
 * state-changing call (reused on retry so a double tap / timeout never duplicates work), tracks the server clock
 * offset, and turns failures into a typed ApiError with a message staff can read.
 */
export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: any, public requestId?: string) {
    super(message);
  }
  get isNetwork() { return this.status === 0; }
}

const TOKEN_KEY = 'ls.token';
const DEVICE_KEY = 'ls.device';
let token: string | null = safeGet(TOKEN_KEY);
let clockOffsetMs = 0;
let onUnauthorized: (() => void) | null = null;

function safeGet(k: string) { try { return localStorage.getItem(k); } catch { return null; } }
function safeSet(k: string, v: string | null) { try { v === null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch { /* storage unavailable */ } }

export const auth = {
  get token() { return token; },
  set(t: string | null) { token = t; safeSet(TOKEN_KEY, t); },
  get deviceId() { return safeGet(DEVICE_KEY); },
  setDevice(id: string | null) { safeSet(DEVICE_KEY, id); },
  onUnauthorized(fn: () => void) { onUnauthorized = fn; },
};

/** Authoritative "now": local clock corrected by the offset learned from the server. */
export const serverNow = () => Date.now() + clockOffsetMs;
export function syncClock(serverTimeIso: string | undefined) {
  if (!serverTimeIso) return;
  const t = Date.parse(serverTimeIso);
  if (!Number.isNaN(t)) clockOffsetMs = t - Date.now();
}

export const newKey = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}-${Math.random().toString(16).slice(2)}`);

export interface ReqOpts { key?: string; raw?: boolean; signal?: AbortSignal; contentType?: string }

export async function api<T = any>(method: string, path: string, body?: unknown, opts: ReqOpts = {}): Promise<T> {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  const dev = auth.deviceId;
  if (dev) headers['x-device-id'] = dev;
  let payload: BodyInit | undefined;
  if (body instanceof Blob) { payload = body; headers['content-type'] = opts.contentType ?? body.type ?? 'application/octet-stream'; }
  else if (body !== undefined) { payload = JSON.stringify(body); headers['content-type'] = 'application/json'; }
  if (method !== 'GET') headers['idempotency-key'] = opts.key ?? newKey();
  let res: Response;
  try {
    res = await fetch('/api/v1' + path, { method, headers, body: payload, signal: opts.signal });
  } catch (e: any) {
    if (e?.name === 'AbortError') throw e;
    throw new ApiError(0, 'NETWORK', 'Cannot reach the server. Check the connection.');
  }
  const date = res.headers.get('date');
  if (date) { /* server date header has 1s resolution; body serverTime is preferred */ }
  if (res.status === 204) return undefined as T;
  const ct = res.headers.get('content-type') ?? '';
  if (!res.ok) {
    let j: any = null;
    try { j = ct.includes('json') ? await res.json() : null; } catch { /* ignore */ }
    if (res.status === 401 && path !== '/auth/login') onUnauthorized?.();
    throw new ApiError(res.status, j?.error?.code ?? 'ERROR', j?.error?.message ?? `Request failed (${res.status}).`, j?.error?.details, j?.error?.requestId);
  }
  if (opts.raw) return (await res.blob()) as any;
  const json = ct.includes('json') ? await res.json() : undefined;
  if (json && typeof json === 'object' && 'serverTime' in json) syncClock((json as any).serverTime);
  return json as T;
}

export const get = <T = any>(p: string, o?: ReqOpts) => api<T>('GET', p, undefined, o);
export const post = <T = any>(p: string, b?: unknown, o?: ReqOpts) => api<T>('POST', p, b ?? {}, o);
export const patch = <T = any>(p: string, b?: unknown, o?: ReqOpts) => api<T>('PATCH', p, b ?? {}, o);
export const put = <T = any>(p: string, b?: unknown, o?: ReqOpts) => api<T>('PUT', p, b ?? {}, o);

/** Protected photos: fetched with the bearer token and shown through short-lived object URLs (never public URLs). */
const photoCache = new Map<string, Promise<string>>();
export function photoUrl(id: string): Promise<string> {
  let p = photoCache.get(id);
  if (!p) {
    p = api<Blob>('GET', `/photos/${id}/content`, undefined, { raw: true }).then((b) => URL.createObjectURL(b));
    p.catch(() => photoCache.delete(id));
    photoCache.set(id, p);
  }
  return p;
}
export function clearPhotoCache() { for (const p of photoCache.values()) p.then((u) => URL.revokeObjectURL(u)).catch(() => {}); photoCache.clear(); }

export async function fetchBlobUrl(path: string): Promise<string> {
  return URL.createObjectURL(await api<Blob>('GET', path, undefined, { raw: true }));
}
