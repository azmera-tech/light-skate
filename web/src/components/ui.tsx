import { useEffect, useRef, useState, type ReactNode } from 'react';
import { photoUrl } from '../api';
import { fmtClock, initials } from '../format';
import { useApp, useNow } from '../state';
import { serverNow } from '../api';

// ---------- icons (labels always accompany color; icons are a second, non-color cue) ----------
const P: Record<string, string> = {
  play: 'M8 5v14l11-7z', pause: 'M6 5h4v14H6zm8 0h4v14h-4z', warn: 'M12 2 1 21h22L12 2zm1 15h-2v-2h2v2zm0-4h-2V9h2v4z', stop: 'M6 6h12v12H6z',
  check: 'M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z', clock: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm1 11h-5V7h2v4h3v2z', x: 'M18.3 5.7 12 12l6.3 6.3-1.4 1.4L10.6 13.4 4.3 19.7 2.9 18.3 9.2 12 2.9 5.7 4.3 4.3l6.3 6.3 6.3-6.3z',
  card: 'M20 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2zm0 14H4v-6h16v6zm0-10H4V6h16v2z', user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm0 2c-3.3 0-8 1.7-8 5v1h16v-1c0-3.3-4.7-5-8-5z',
  plus: 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z', search: 'M15.5 14h-.8l-.3-.3A6.5 6.5 0 1 0 14 15.5l.3.3v.8l5 5 1.5-1.5-5-5zm-6 0a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9z',
  alert: 'M12 2 1 21h22L12 2zm1 15h-2v-2h2v2zm0-4h-2V9h2v4z', phone: 'M6.6 10.8a15 15 0 0 0 6.6 6.6l2.2-2.2a1 1 0 0 1 1-.25 11 11 0 0 0 3.5.56 1 1 0 0 1 1 1V20a1 1 0 0 1-1 1A17 17 0 0 1 3 4a1 1 0 0 1 1-1h3.5a1 1 0 0 1 1 1c0 1.2.2 2.4.56 3.5a1 1 0 0 1-.25 1z',
  camera: 'M9 3 7.2 5H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-3.2L15 3zm3 15a5 5 0 1 1 0-10 5 5 0 0 1 0 10z', skate: 'M3 15h13l3-7h-4l-1.5 3H8L7 4H3zm4 2a2 2 0 1 0 0 4 2 2 0 0 0 0-4zm9 0a2 2 0 1 0 0 4 2 2 0 0 0 0-4z',
  home: 'M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z', list: 'M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z', wrench: 'M22.7 19 13.6 9.9a5 5 0 0 0-6.8-6.2l3.2 3.2-2.8 2.8L4 6.5a5 5 0 0 0 6.2 6.8l9.1 9.1a1 1 0 0 0 1.4 0l2-2a1 1 0 0 0 0-1.4z',
  shield: 'M12 1 3 5v6c0 5.5 3.8 10.7 9 12 5.2-1.3 9-6.5 9-12V5l-9-4z', chart: 'M5 9.2h3V19H5zM10.6 5h2.8v14h-2.8zm5.6 8H19v6h-2.8z', gear: 'M19.4 13a7.5 7.5 0 0 0 0-2l2.1-1.6-2-3.4-2.5 1a7.4 7.4 0 0 0-1.7-1L14.9 3h-4l-.4 3a7.4 7.4 0 0 0-1.7 1l-2.5-1-2 3.4L6.6 11a7.5 7.5 0 0 0 0 2l-2.1 1.6 2 3.4 2.5-1c.5.4 1.1.7 1.7 1l.4 3h4l.4-3c.6-.3 1.2-.6 1.7-1l2.5 1 2-3.4z',
  flag: 'M14.4 6 14 4H5v17h2v-7h5.6l.4 2h7V6z', lock: 'M18 8h-1V6a5 5 0 0 0-10 0v2H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V10a2 2 0 0 0-2-2zM9 6a3 3 0 0 1 6 0v2H9V6z', wifi: 'M1 9l2 2a13 13 0 0 1 18 0l2-2A16 16 0 0 0 1 9zm8 8 3 3 3-3a4 4 0 0 0-6 0zm-4-4 2 2a7 7 0 0 1 10 0l2-2a10 10 0 0 0-14 0z',
};
export function Icon({ n, size = 16 }: { n: string; size?: number }) {
  return <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor" aria-hidden="true"><path d={P[n] ?? P.check} /></svg>;
}

export function Logo() {
  return <svg viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="14" fill="var(--brand)" /><path d="M14 38h26l6-14h-8l-3 6H22l-2-14h-8l3 22z" fill="var(--on-brand)" /><circle cx="22" cy="46" r="4" fill="var(--on-brand)" /><circle cx="40" cy="46" r="4" fill="var(--on-brand)" /></svg>;
}

// ---------- status ----------
export type Level = 'normal' | 'yellow' | 'orange' | 'red' | 'expired' | 'paused' | 'gray' | 'info';

const STATUS_LABEL: Record<string, [string, Level, string]> = {
  ACTIVE: ['Active', 'normal', 'play'], PAUSED: ['Paused', 'paused', 'pause'], EXPIRING: ['Ending soon', 'yellow', 'warn'], EXPIRED: ['Time up', 'expired', 'stop'],
  COMPLETED: ['Completed', 'gray', 'check'], EARLY_EXIT: ['Left early', 'gray', 'check'], CANCELLED: ['Cancelled', 'gray', 'x'], NO_SHOW: ['No-show', 'gray', 'x'],
  READY: ['Ready to start', 'info', 'check'], CHECKED_IN: ['Checked in', 'info', 'check'], PAYMENT_PENDING: ['Awaiting payment', 'yellow', 'card'], CREATED: ['Created', 'gray', 'clock'],
};

/** Countdown severity from configured thresholds (default 15 / 5 / 1 min). */
export function levelFor(remaining: number | null, status: string, warnings: { minutes: number; level: string }[]): Level {
  if (status === 'PAUSED') return 'paused';
  if (status === 'EXPIRED' || (remaining !== null && remaining <= 0 && ['ACTIVE', 'EXPIRING'].includes(status))) return 'expired';
  if (remaining === null) return 'gray';
  const hit = [...warnings].sort((a, b) => a.minutes - b.minutes).find((w) => remaining <= w.minutes * 60);
  return hit ? (hit.level.toLowerCase() as Level) : 'normal';
}

export function remainingFor(s: { status: string; scheduledEndAt: string | null; pausedAt: string | null; pauseCountsTowardTime: boolean }, now = serverNow()): number | null {
  if (!s.scheduledEndAt) return null;
  const end = Date.parse(s.scheduledEndAt);
  const ref = s.status === 'PAUSED' && !s.pauseCountsTowardTime && s.pausedAt ? Date.parse(s.pausedAt) : now;
  return Math.round((end - ref) / 1000);
}

export function StatusBadge({ status, level }: { status: string; level?: Level }) {
  const [label, lvl, icon] = STATUS_LABEL[status] ?? [status, 'gray' as Level, 'check'];
  let l = level ?? lvl, text = label, ic = icon;
  if (status === 'ACTIVE' && level && level !== 'normal') { text = level === 'red' ? 'Last minute' : level === 'orange' ? 'Finishing' : 'Ending soon'; ic = 'warn'; }
  if (status === 'EXPIRING' && level && level !== 'yellow') { text = level === 'red' ? 'Last minute' : level === 'orange' ? 'Finishing' : 'Ending soon'; }
  return <span className={`badge lvl-${l}`}><Icon n={ic} />{text}</span>;
}

/** Display-only countdown derived from the authoritative end timestamp (survives refresh/restart/another device). */
export function Countdown({ s, xl }: { s: any; xl?: boolean }) {
  const { config } = useApp();
  const now = useNow();
  const rem = remainingFor(s, now);
  const lvl = levelFor(rem, s.status, config?.settings.warnings ?? []);
  if (rem === null) return <span className="muted">—</span>;
  return <span className={`clock lvl-${lvl} ${xl ? 'xl' : ''}`} aria-label={rem < 0 ? `Over time by ${fmtClock(rem)}` : `${fmtClock(rem)} remaining`}>{fmtClock(rem)}</span>;
}

// ---------- photo ----------
export function Photo({ id, name, size = 'md' }: { id?: string | null; name: string; size?: 'sm' | 'md' | 'lg' }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => { let ok = true; setUrl(null); if (id) photoUrl(id).then((u) => ok && setUrl(u)).catch(() => {}); return () => { ok = false; }; }, [id]);
  return <div className={`avatar ${size === 'lg' ? 'lg' : size === 'sm' ? 'sm' : ''}`} title={name}>{url ? <img src={url} alt={`Photo of ${name}`} /> : initials(name)}</div>;
}

// ---------- layout helpers ----------
export function Modal({ title, onClose, children, footer, size }: { title: ReactNode; onClose: () => void; children: ReactNode; footer?: ReactNode; size?: 'sm' | 'wide' }) {
  useEffect(() => { const h = (e: KeyboardEvent) => e.key === 'Escape' && onClose(); window.addEventListener('keydown', h); return () => window.removeEventListener('keydown', h); }, [onClose]);
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()} role="dialog" aria-modal="true">
      <div className={`modal ${size ?? ''}`}>
        <header><h2>{title}</h2><button className="btn ghost small" onClick={onClose} aria-label="Close"><Icon n="x" /></button></header>
        <div className="body">{children}</div>
        {footer && <footer>{footer}</footer>}
      </div>
    </div>
  );
}

export function Field({ label, hint, error, children }: { label: string; hint?: string; error?: string | null; children: ReactNode }) {
  return <div className="field"><label>{label}</label>{children}{error ? <span className="err">{error}</span> : hint ? <span className="hint">{hint}</span> : null}</div>;
}

export function Kpi({ label, value, sub, tone }: { label: string; value: ReactNode; sub?: ReactNode; tone?: 'red' | 'yellow' | 'green' }) {
  return <div className="kpi"><div className="label">{label}</div><div className="value" style={tone ? { color: `var(--${tone})` } : undefined}>{value}</div>{sub && <div className="sub">{sub}</div>}</div>;
}

export function Empty({ children }: { children: ReactNode }) { return <div className="empty">{children}</div>; }
export function Loading() { return <div className="empty">Loading…</div>; }
export function ErrorBox({ error, retry }: { error: { message: string }; retry?: () => void }) {
  return <div className="banner red" role="alert"><Icon n="alert" />{error.message}{retry && <button className="btn small" onClick={retry}>Retry</button>}</div>;
}

/** Busy-aware action button: disables itself while the request is in flight (prevents double taps). */
export function ActionButton({ onClick, children, className = 'btn', disabled }: { onClick: () => Promise<unknown> | unknown; children: ReactNode; className?: string; disabled?: boolean }) {
  const [busy, setBusy] = useState(false);
  const mounted = useRef(true);
  useEffect(() => () => { mounted.current = false; }, []);
  return <button className={className} disabled={busy || disabled} onClick={async () => { setBusy(true); try { await onClick(); } finally { if (mounted.current) setBusy(false); } }}>{busy ? 'Working…' : children}</button>;
}

export function ToastHost() {
  const { toasts, dismissToast } = useApp();
  return <div className="toasts" aria-live="polite">{toasts.map((t) => <div key={t.id} className={`toast ${t.kind}`} onClick={() => dismissToast(t.id)}>{t.text}</div>)}</div>;
}

export function useLocalState<T>(key: string, initial: T): [T, (v: T) => void] {
  const [v, setV] = useState<T>(() => { try { const s = localStorage.getItem(key); return s ? JSON.parse(s) : initial; } catch { return initial; } });
  return [v, (n: T) => { setV(n); try { localStorage.setItem(key, JSON.stringify(n)); } catch { /* */ } }];
}
