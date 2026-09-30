import { auth } from './api';

/**
 * Realtime delivery over WebSocket. Events are hints: on any event (and after every reconnect) subscribers
 * simply refetch authoritative state, so a missed message can never leave a screen wrong.
 */
type Status = 'connecting' | 'live' | 'offline';
type Listener = (evt: { event: string; payload: any }) => void;

class Realtime {
  status: Status = 'offline';
  private ws: WebSocket | null = null;
  private listeners = new Set<Listener>();
  private statusListeners = new Set<(s: Status) => void>();
  private resync = new Set<() => void>();
  private retry = 0;
  private timer: any = null;
  private running = false;
  private hb: any = null;

  start() {
    if (this.running) return;
    this.running = true;
    this.connect();
    window.addEventListener('online', () => this.connect());
    // The browser knows immediately when the link drops; do not wait for TCP to time out.
    window.addEventListener('offline', () => { this.drop(); });
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') { this.connect(); this.resync.forEach((f) => f()); } });
  }
  stop() {
    this.running = false;
    clearTimeout(this.timer); clearInterval(this.hb);
    this.ws?.close();
    this.set('offline');
  }
  private drop() {
    const ws = this.ws; this.ws = null;
    try { ws?.close(); } catch { /* */ }
    this.set('offline');
    clearTimeout(this.timer);
    if (this.running) this.timer = setTimeout(() => this.connect(), 2000);
  }
  private set(s: Status) { if (this.status !== s) { this.status = s; this.statusListeners.forEach((f) => f(s)); } }
  private connect() {
    if (!this.running || !auth.token || (this.ws && this.ws.readyState <= 1)) return;
    this.set('connecting');
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(`${proto}://${location.host}/api/v1/realtime`);
    this.ws = ws;
    ws.onopen = () => ws.send(JSON.stringify({ type: 'auth', token: auth.token, deviceId: auth.deviceId }));
    ws.onmessage = (m) => {
      let msg: any; try { msg = JSON.parse(m.data); } catch { return; }
      if (msg.type === 'ready') { this.retry = 0; this.set('live'); this.resync.forEach((f) => f()); }
      else if (msg.type === 'event') this.listeners.forEach((f) => f({ event: msg.event, payload: msg.payload ?? {} }));
    };
    const lost = () => {
      if (this.ws !== ws) return;
      this.ws = null; this.set('offline');
      if (!this.running) return;
      clearTimeout(this.timer);
      this.timer = setTimeout(() => this.connect(), Math.min(15000, 1000 * 2 ** this.retry++));
    };
    ws.onclose = lost; ws.onerror = () => { try { ws.close(); } catch { /* */ } };
    // Heartbeat with a deadline: a socket that stops answering is treated as lost (silent Wi-Fi drop, sleeping tablet, dead proxy).
    clearInterval(this.hb);
    let lastPong = Date.now();
    const onPong = ws.onmessage;
    ws.onmessage = (m) => { lastPong = Date.now(); onPong?.call(ws, m); };
    this.hb = setInterval(() => {
      if (ws.readyState !== 1) return;
      if (Date.now() - lastPong > 20000) { if (this.ws === ws) this.drop(); return; }
      ws.send(JSON.stringify({ type: 'ping' }));
    }, 8000);
  }
  onEvent(f: Listener) { this.listeners.add(f); return () => { this.listeners.delete(f); }; }
  onStatus(f: (s: Status) => void) { this.statusListeners.add(f); return () => { this.statusListeners.delete(f); }; }
  /** Called after (re)connect and when the tab becomes visible again. */
  onResync(f: () => void) { this.resync.add(f); return () => { this.resync.delete(f); }; }
}
export const realtime = new Realtime();
