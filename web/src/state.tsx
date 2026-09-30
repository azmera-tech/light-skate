import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { ApiError, auth, get, post, serverNow, syncClock, clearPhotoCache } from './api';
import { realtime } from './realtime';
import { setVenueTimezone } from './format';
import { flushQueue, queue } from './offline';

export interface Me { id: string; email: string; fullName: string; role: string; permissions: string[]; venueId: string; deviceId: string | null }
export interface Config {
  serverTime: string; venue: { id: string; name: string; timezone: string; currency: string }; maxCapacity: number;
  settings: {
    paymentMethods: { code: string; label: string; requiresReference: boolean }[];
    warnings: { minutes: number; level: 'YELLOW' | 'ORANGE' | 'RED' }[]; expiringMinutes: number;
    pause: { enabled: boolean; countsTowardTime: boolean }; extensionOptionsMinutes: number[]; waiverRequired: boolean; minorAgeYears: number;
    photoCapture: 'NEW_CUSTOMER' | 'EVERY_VISIT' | 'NEVER'; wristbands: { enabled: boolean; colors: string[] };
    equipmentRequiredForStart: boolean; inspectOnReturn: boolean; earlyExitGraceSeconds: number;
  };
  emergency: Record<string, string>;
}

export type Toast = { id: number; kind: 'ok' | 'error' | 'info'; text: string };

interface Ctx {
  me: Me | null; config: Config | null; booting: boolean;
  can: (p: string) => boolean;
  login: (email: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  toasts: Toast[]; toast: (kind: Toast['kind'], text: string) => void; dismissToast: (id: number) => void;
  live: 'connecting' | 'live' | 'offline'; queued: number;
  tick: number; // increments on every realtime event or resync; screens refetch when it changes
  refreshConfig: () => Promise<void>;
}
const C = createContext<Ctx>(null as any);
export const useApp = () => useContext(C);

export function AppProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [config, setConfig] = useState<Config | null>(null);
  const [booting, setBooting] = useState(!!auth.token);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [live, setLive] = useState(realtime.status);
  const [queued, setQueued] = useState(queue.length);
  const [tick, setTick] = useState(0);
  const toastId = useRef(0);

  const toast = useCallback((kind: Toast['kind'], text: string) => {
    const id = ++toastId.current;
    setToasts((t) => [...t.slice(-3), { id, kind, text }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), kind === 'error' ? 8000 : 4500);
  }, []);
  const dismissToast = useCallback((id: number) => setToasts((t) => t.filter((x) => x.id !== id)), []);

  const refreshConfig = useCallback(async () => {
    const cfg = await get<Config>('/config');
    setConfig(cfg); setVenueTimezone(cfg.venue.timezone); syncClock(cfg.serverTime);
    try { localStorage.setItem('ls.config', JSON.stringify(cfg)); } catch { /* */ }
  }, []);

  const loadSession = useCallback(async () => {
    try {
      const m = await get<Me>('/auth/me');
      setMe(m);
      await refreshConfig();
      realtime.start();
    } catch (e) {
      if (e instanceof ApiError && e.isNetwork) {
        // Offline start: fall back to the last known venue configuration so timers and screens still render.
        try { const c = JSON.parse(localStorage.getItem('ls.config') ?? 'null'); const m = JSON.parse(localStorage.getItem('ls.me') ?? 'null'); if (c && m) { setConfig(c); setMe(m); setVenueTimezone(c.venue.timezone); realtime.start(); } } catch { /* */ }
      } else { auth.set(null); setMe(null); }
    } finally { setBooting(false); }
  }, [refreshConfig]);

  useEffect(() => { auth.onUnauthorized(() => { auth.set(null); setMe(null); realtime.stop(); }); if (auth.token) loadSession(); }, [loadSession]);
  useEffect(() => { if (me) try { localStorage.setItem('ls.me', JSON.stringify(me)); } catch { /* */ } }, [me]);
  useEffect(() => realtime.onStatus(setLive), []);
  useEffect(() => queue.subscribe(() => setQueued(queue.length)), []);
  useEffect(() => {
    const bump = () => setTick((t) => t + 1);
    const off1 = realtime.onEvent(bump);
    const off2 = realtime.onResync(async () => {
      // Reconnected: replay queued offline commands first, then tell screens to refetch authoritative state.
      try {
        const r = await flushQueue();
        if (r) {
          if (r.accepted) toast('ok', `${r.accepted} offline action${r.accepted > 1 ? 's' : ''} synced.`);
          r.conflicts.forEach((c) => toast('error', `${c.label}: ${c.message}`));
        }
      } catch { /* retry on next resync */ }
      bump();
    });
    const online = () => flushQueue().then((r) => { if (r) { if (r.accepted) toast('ok', `${r.accepted} offline action${r.accepted > 1 ? 's' : ''} synced.`); r.conflicts.forEach((c) => toast('error', `${c.label}: ${c.message}`)); bump(); } }).catch(() => {});
    window.addEventListener('online', online);
    // Safety net: even if the socket is silent (proxy dropped it), states are re-reconciled every 30 s.
    const t = setInterval(() => { if (document.visibilityState === 'visible') bump(); }, 30000);
    return () => { off1(); off2(); window.removeEventListener('online', online); clearInterval(t); };
  }, [toast]);

  const login = useCallback(async (email: string, password: string) => {
    const r = await post('/auth/login', { email, password, deviceId: auth.deviceId ?? undefined });
    auth.set(r.token);
    setBooting(true);
    await loadSession();
  }, [loadSession]);
  const logout = useCallback(async () => {
    try { await post('/auth/logout'); } catch { /* ignore */ }
    realtime.stop(); auth.set(null); clearPhotoCache(); setMe(null); setConfig(null);
  }, []);
  const can = useCallback((p: string) => !!me?.permissions.includes(p), [me]);

  const value = useMemo<Ctx>(() => ({ me, config, booting, can, login, logout, toasts, toast, dismissToast, live, queued, tick, refreshConfig }),
    [me, config, booting, can, login, logout, toasts, toast, dismissToast, live, queued, tick, refreshConfig]);
  return <C.Provider value={value}>{children}</C.Provider>;
}

/** 1-second display ticker. Display only: it re-renders countdowns; it never writes anything. */
export function useNow(intervalMs = 1000) {
  const [, set] = useState(0);
  useEffect(() => { const t = setInterval(() => set((n) => n + 1), intervalMs); return () => clearInterval(t); }, [intervalMs]);
  return serverNow();
}

/** Fetch + auto-refetch on realtime ticks. Keeps showing the previous data while reloading (no flicker). */
export function useApi<T>(path: string | null, deps: unknown[] = []) {
  const { tick } = useApp();
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const [loading, setLoading] = useState(true);
  const seq = useRef(0);
  const load = useCallback(async () => {
    if (!path) return;
    const n = ++seq.current;
    try { const d = await get<T>(path); if (n === seq.current) { setData(d); setError(null); } }
    catch (e) { if (n === seq.current) setError(e as ApiError); }
    finally { if (n === seq.current) setLoading(false); }
  }, [path]);
  useEffect(() => { setLoading(true); load(); /* eslint-disable-next-line */ }, [path, ...deps]);
  useEffect(() => { if (tick) load(); /* eslint-disable-next-line */ }, [tick]);
  return { data, error, loading, reload: load };
}
