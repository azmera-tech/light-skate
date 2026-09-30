import { execute, type CommandMeta } from '../shared/command.js';
import { AppError } from '../shared/errors.js';
import { endSession, pauseSession, resumeSession, extendSession } from './sessions.js';
import { returnEquipment } from './equipment.js';

/**
 * Offline command replay. Devices queue *commands* (not state) while offline; on reconnect the backend runs each
 * through the exact same validated path as a live request. Each command's requestId is its idempotency key,
 * so replaying a batch twice is harmless, and a command the venue has already moved past is rejected with a
 * clear conflict instead of silently overwriting newer state.
 *
 * What can run offline is an explicit allow-list. Starting sessions, payments, refunds, permissions and capacity
 * decisions need live backend confirmation and are intentionally NOT replayable.
 */
export const OFFLINE_COMMANDS = ['END_SESSION', 'PAUSE_SESSION', 'RESUME_SESSION', 'EXTEND_SESSION', 'RETURN_EQUIPMENT'] as const;
export type OfflineCommandName = (typeof OFFLINE_COMMANDS)[number];

export interface QueuedCommand {
  requestId: string;
  command: string;
  sessionId?: string;
  equipmentId?: string;
  params?: Record<string, any>;
  issuedAt?: string;
}

export interface CommandOutcome {
  requestId: string;
  command: string;
  outcome: 'ACCEPTED' | 'DUPLICATE' | 'REJECTED' | 'CONFLICT';
  code?: string;
  message?: string;
}

export async function replayCommands(meta: Omit<CommandMeta, 'idempotencyKey'>, commands: QueuedCommand[]): Promise<CommandOutcome[]> {
  const out: CommandOutcome[] = [];
  for (const c of commands) {
    const m: CommandMeta = { ...meta, idempotencyKey: c.requestId };
    try {
      if (!(OFFLINE_COMMANDS as readonly string[]).includes(c.command)) {
        out.push({ requestId: c.requestId, command: c.command, outcome: 'REJECTED', code: 'OFFLINE_NOT_ALLOWED', message: `${c.command} cannot be performed offline; it needs a live connection.` });
        continue;
      }
      const issuedAt = c.issuedAt && !Number.isNaN(Date.parse(c.issuedAt)) ? new Date(c.issuedAt) : null;
      const p = c.params ?? {};
      const run = async () => {
        switch (c.command as OfflineCommandName) {
          case 'END_SESSION':
            return execute(m, { operation: 'session.end', permission: 'session.end', idempotency: 'required' }, { id: c.sessionId, p }, (ctx) => endSession(ctx, c.sessionId!, { issuedAt, reason: p.reason }));
          case 'PAUSE_SESSION':
            return execute(m, { operation: 'session.pause', permission: 'session.pause', idempotency: 'required' }, { id: c.sessionId, p }, (ctx) => pauseSession(ctx, c.sessionId!, { reason: p.reason }));
          case 'RESUME_SESSION':
            return execute(m, { operation: 'session.resume', permission: 'session.pause', idempotency: 'required' }, { id: c.sessionId, p }, (ctx) => resumeSession(ctx, c.sessionId!, { reason: p.reason }));
          case 'EXTEND_SESSION':
            return execute(m, { operation: 'session.extend', permission: 'session.extend', idempotency: 'required' }, { id: c.sessionId, p },
              (ctx) => extendSession(ctx, c.sessionId!, { minutes: Number(p.minutes), reason: p.reason, payment: p.payment ?? null, complimentary: !!p.complimentary }));
          case 'RETURN_EQUIPMENT':
            return execute(m, { operation: 'equipment.return', permission: 'equipment.return', idempotency: 'required' }, { id: c.equipmentId, p },
              (ctx) => returnEquipment(ctx, c.equipmentId!, { condition: p.condition === 'DAMAGED' ? 'DAMAGED' : 'GOOD', note: p.note }));
        }
      };
      if ((c.command.endsWith('SESSION') && !c.sessionId) || (c.command === 'RETURN_EQUIPMENT' && !c.equipmentId)) {
        out.push({ requestId: c.requestId, command: c.command, outcome: 'REJECTED', code: 'INVALID_COMMAND', message: 'The command is missing its target.' });
        continue;
      }
      const r = await run();
      out.push({ requestId: c.requestId, command: c.command, outcome: r!.replay ? 'DUPLICATE' : 'ACCEPTED' });
    } catch (e) {
      if (e instanceof AppError) {
        out.push({ requestId: c.requestId, command: c.command, outcome: e.status === 409 ? 'CONFLICT' : 'REJECTED', code: e.code, message: e.message });
      } else {
        const { translateDbError } = await import('../shared/command.js');
        const t = translateDbError(e);
        out.push({ requestId: c.requestId, command: c.command, outcome: 'REJECTED', code: t?.code ?? 'INTERNAL', message: t?.message ?? 'The command could not be processed.' });
      }
    }
  }
  return out;
}
