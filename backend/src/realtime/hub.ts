import type { FastifyInstance } from 'fastify';
import pg from 'pg';
import { config } from '../config.js';
import { resolveToken } from '../auth/service.js';
import { REALTIME_CHANNEL } from '../worker/outbox.js';

interface Client { socket: import('ws').WebSocket; venueId: string; userId: string; alive: boolean }

/**
 * Realtime is only a delivery mechanism. The DB is the source of truth: clients that miss events
 * (disconnect, sleep) simply refetch state on reconnect. Messages carry ids + tiny payloads, never PII.
 */
export class RealtimeHub {
  private clients = new Set<Client>();
  private listener: pg.Client | null = null;
  private stopped = false;
  private heartbeat: NodeJS.Timeout | null = null;

  async start() {
    this.stopped = false;
    await this.connectListener();
    this.heartbeat = setInterval(() => {
      for (const c of this.clients) {
        if (!c.alive) { c.socket.terminate(); this.clients.delete(c); continue; }
        c.alive = false;
        try { c.socket.ping(); } catch { /* closed */ }
      }
    }, 25_000);
  }

  private async connectListener() {
    if (this.stopped) return;
    const client = new pg.Client({ connectionString: config.databaseUrl });
    client.on('error', () => this.reconnect());
    client.on('end', () => this.reconnect());
    client.on('notification', (m) => {
      if (m.channel !== REALTIME_CHANNEL || !m.payload) return;
      try { this.broadcast(JSON.parse(m.payload)); } catch { /* ignore malformed */ }
    });
    try {
      await client.connect();
      await client.query(`LISTEN ${REALTIME_CHANNEL}`);
      this.listener = client;
    } catch {
      this.reconnect();
    }
  }

  private reconnecting = false;
  private reconnect() {
    if (this.stopped || this.reconnecting) return;
    this.reconnecting = true;
    this.listener?.removeAllListeners();
    this.listener?.end().catch(() => {});
    this.listener = null;
    // Clients learn of a gap through the periodic `sync` hint and refetch; correctness never depends on delivery.
    setTimeout(() => { this.reconnecting = false; this.connectListener(); }, 2000);
  }

  /** Wire format: { type: 'event', event: 'SESSION_STARTED', aggregateType, aggregateId, payload, id, at } */
  broadcast(evt: { venueId: string; type: string; [k: string]: unknown }) {
    const { venueId, type, ...rest } = evt;
    const data = JSON.stringify({ type: 'event', event: type, ...rest });
    for (const c of this.clients) if (c.venueId === venueId && c.socket.readyState === 1) c.socket.send(data);
  }

  register(app: FastifyInstance) {
    app.get('/api/v1/realtime', { websocket: true }, (socket, req) => {
      let client: Client | null = null;
      const authTimer = setTimeout(() => { if (!client) socket.close(4401, 'auth timeout'); }, 5000);
      socket.on('message', async (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (!client && msg.type === 'auth') {
            // Token travels in the first message, never in the URL (keeps it out of logs/history).
            const user = await resolveToken(String(msg.token ?? ''), typeof msg.deviceId === 'string' ? msg.deviceId : null);
            if (!user) { socket.close(4401, 'unauthorized'); return; }
            client = { socket, venueId: user.venueId, userId: user.id, alive: true };
            this.clients.add(client);
            socket.send(JSON.stringify({ type: 'ready', serverTime: new Date().toISOString() }));
          } else if (client && msg.type === 'ping') {
            socket.send(JSON.stringify({ type: 'pong', serverTime: new Date().toISOString() }));
          }
        } catch { /* ignore */ }
      });
      socket.on('pong', () => { if (client) client.alive = true; });
      socket.on('close', () => { clearTimeout(authTimer); if (client) this.clients.delete(client); });
      socket.on('error', () => { if (client) this.clients.delete(client); });
    });
  }

  get connectionCount() { return this.clients.size; }

  async stop() {
    this.stopped = true;
    if (this.heartbeat) clearInterval(this.heartbeat);
    for (const c of this.clients) c.socket.close(1001, 'server shutting down');
    this.clients.clear();
    await this.listener?.end().catch(() => {});
    this.listener = null;
  }
}
