export function formatMoney(minor: number | null | undefined, currency = 'ETB'): string {
  if (minor === null || minor === undefined) return '—';
  const neg = minor < 0, abs = Math.abs(minor);
  const whole = Math.trunc(abs / 100).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const frac = abs % 100;
  return `${neg ? '-' : ''}${whole}${frac ? '.' + String(frac).padStart(2, '0') : ''} ${currency}`;
}
export const toMinor = (majorText: string): number | null => {
  const m = /^\s*(\d{1,9})(?:\.(\d{1,2}))?\s*$/.exec(majorText);
  return m ? Number(m[1]) * 100 + Number((m[2] ?? '').padEnd(2, '0')) : null;
};

let tz = 'Africa/Addis_Ababa';
export function setVenueTimezone(z: string) { tz = z; }
export const venueTz = () => tz;

export function fmtTime(iso: string | null | undefined, withSeconds = false): string {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit', second: withSeconds ? '2-digit' : undefined, hourCycle: 'h23' }).format(new Date(iso));
}
export function fmtDateTime(iso: string | null | undefined): string {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', { timeZone: tz, day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso));
}
export function fmtDate(iso: string | null | undefined): string {
  if (!iso) return '—';
  const d = /^\d{4}-\d{2}-\d{2}$/.test(iso) ? new Date(iso + 'T12:00:00Z') : new Date(iso);
  return new Intl.DateTimeFormat('en-GB', { timeZone: /^\d{4}-\d{2}-\d{2}$/.test(iso) ? 'UTC' : tz, day: '2-digit', month: 'short', year: 'numeric' }).format(d);
}
export const localToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
export function shiftDate(date: string, days: number) { const d = new Date(date + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + days); return d.toISOString().slice(0, 10); }

export function fmtClock(totalSeconds: number): string {
  const neg = totalSeconds < 0; const s = Math.abs(Math.trunc(totalSeconds));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const mm = String(m).padStart(2, '0'), ss = String(sec).padStart(2, '0');
  return `${neg ? '+' : ''}${h ? h + ':' + mm : m}:${ss}`;
}
export function fmtDuration(seconds: number): string {
  const m = Math.round(seconds / 60);
  if (m < 60) return `${m} min`;
  return `${Math.floor(m / 60)} h ${m % 60 ? (m % 60) + ' min' : ''}`.trim();
}
export function phoneDisplay(e164: string | null | undefined): string {
  if (!e164) return '—';
  if (e164.startsWith('+251') && e164.length === 13) return `0${e164.slice(4, 6)} ${e164.slice(6, 9)} ${e164.slice(9)}`;
  return e164;
}
export const titleCase = (s: string) => s.toLowerCase().replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());
export const initials = (name: string) => name.replace(/^Demo /, '').split(/\s+/).slice(0, 2).map((p) => p[0]).join('').toUpperCase();
