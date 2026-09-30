import { ApiError, post, newKey } from './api';

/**
 * Offline command queue. While the network is down staff can still END / PAUSE / RESUME / EXTEND sessions and
 * RETURN equipment: the *command* (not the new state) is queued with its own request id and replayed in order
 * through POST /sync/commands, where the backend re-validates each one. Conflicts are shown, never overwritten.
 * Starting sessions, payments, refunds and settings are intentionally NOT queueable.
 */
export interface QueuedCommand {
  requestId: string;
  command: 'END_SESSION' | 'PAUSE_SESSION' | 'RESUME_SESSION' | 'EXTEND_SESSION' | 'RETURN_EQUIPMENT';
  sessionId?: string;
  equipmentId?: string;
  params?: Record<string, unknown>;
  issuedAt: string;
  label: string;
}
const KEY = 'ls.queue';
const listeners = new Set<() => void>();
let flushing = false;

const read = (): QueuedCommand[] => { try { return JSON.parse(localStorage.getItem(KEY) ?? '[]'); } catch { return []; } };
const write = (q: QueuedCommand[]) => { try { localStorage.setItem(KEY, JSON.stringify(q)); } catch { /* */ } listeners.forEach((f) => f()); };

export const queue = {
  get length() { return read().length; },
  list: read,
  subscribe(f: () => void) { listeners.add(f); return () => { listeners.delete(f); }; },
  enqueue(c: Omit<QueuedCommand, 'requestId' | 'issuedAt'> & { requestId?: string }) { write([...read(), { ...c, requestId: c.requestId ?? newKey(), issuedAt: new Date().toISOString() }]); },
};

export interface SyncResult { accepted: number; conflicts: { label: string; message: string }[] }

export async function flushQueue(): Promise<SyncResult | null> {
  if (flushing) return null;
  const q = read();
  if (!q.length) return null;
  flushing = true;
  try {
    const r = await post('/sync/commands', { commands: q.map(({ label: _l, ...c }) => c) });
    const byId = new Map(q.map((c) => [c.requestId, c]));
    const conflicts: SyncResult['conflicts'] = [];
    let accepted = 0;
    for (const res of r.results) {
      if (res.outcome === 'ACCEPTED' || res.outcome === 'DUPLICATE') accepted++;
      else conflicts.push({ label: byId.get(res.requestId)?.label ?? res.command, message: res.message ?? 'Rejected' });
    }
    write([]); // every command has a final outcome now
    return { accepted, conflicts };
  } catch (e) {
    if (e instanceof ApiError && e.isNetwork) return null; // still offline; keep the queue
    throw e;
  } finally { flushing = false; }
}

/** Run a command online; if the network is down and the command is allowed offline, queue it. */
export async function runOrQueue<T>(online: (key: string) => Promise<T>, offline: Omit<QueuedCommand, 'requestId' | 'issuedAt'>): Promise<{ queued: boolean; result?: T }> {
  // One key for the live attempt AND the queued replay: if the request reached the server but the answer was lost,
  // the replay is recognised as a duplicate instead of being applied twice.
  const key = newKey();
  try {
    return { queued: false, result: await online(key) };
  } catch (e) {
    if (e instanceof ApiError && e.isNetwork) { queue.enqueue({ ...offline, requestId: key }); return { queued: true }; }
    throw e;
  }
}
