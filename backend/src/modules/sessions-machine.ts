import { AppError } from '../shared/errors.js';

export type SessionStatus =
  | 'CREATED' | 'PAYMENT_PENDING' | 'READY' | 'CHECKED_IN' | 'ACTIVE' | 'PAUSED' | 'EXPIRING'
  | 'COMPLETED' | 'EARLY_EXIT' | 'CANCELLED' | 'NO_SHOW' | 'EXPIRED';

/**
 * The single source of truth for legal session transitions. Enforced server-side only.
 * EXPIRED means "paid time has run out but the customer is still on the floor"; staff end it -> COMPLETED.
 */
export const TRANSITIONS: Record<SessionStatus, SessionStatus[]> = {
  CREATED: ['PAYMENT_PENDING', 'READY', 'CANCELLED'],
  PAYMENT_PENDING: ['READY', 'CANCELLED'],
  READY: ['CHECKED_IN', 'CANCELLED', 'NO_SHOW'],
  CHECKED_IN: ['ACTIVE', 'CANCELLED'],
  ACTIVE: ['PAUSED', 'EXPIRING', 'COMPLETED', 'EARLY_EXIT', 'EXPIRED'],
  PAUSED: ['ACTIVE', 'EARLY_EXIT', 'COMPLETED', 'EXPIRED'],
  EXPIRING: ['ACTIVE', 'PAUSED', 'COMPLETED', 'EARLY_EXIT', 'EXPIRED'],
  EXPIRED: ['ACTIVE', 'COMPLETED'],
  COMPLETED: [],
  EARLY_EXIT: [],
  CANCELLED: [],
  NO_SHOW: [],
};

/** Statuses where the customer is physically in the venue and counts toward capacity. */
export const OCCUPANCY_STATUSES: SessionStatus[] = ['ACTIVE', 'PAUSED', 'EXPIRING', 'EXPIRED'];
/** Statuses that block a second session for the same customer (also enforced by a unique index). */
export const LIVE_STATUSES: SessionStatus[] = ['CHECKED_IN', 'ACTIVE', 'PAUSED', 'EXPIRING', 'EXPIRED'];
export const TERMINAL_STATUSES: SessionStatus[] = ['COMPLETED', 'EARLY_EXIT', 'CANCELLED', 'NO_SHOW'];
/** Statuses in which the customer may hold equipment. */
export const EQUIPMENT_HOLDING_STATUSES: SessionStatus[] = ['CHECKED_IN', 'ACTIVE', 'PAUSED', 'EXPIRING', 'EXPIRED'];

export const STATUS_PHRASE: Record<SessionStatus, string> = {
  CREATED: 'just created', PAYMENT_PENDING: 'waiting for payment', READY: 'ready to start', CHECKED_IN: 'checked in',
  ACTIVE: 'active', PAUSED: 'paused', EXPIRING: 'about to finish', COMPLETED: 'completed', EARLY_EXIT: 'already ended early',
  CANCELLED: 'cancelled', NO_SHOW: 'marked as a no-show', EXPIRED: 'past its end time',
};

export function canTransition(from: SessionStatus, to: SessionStatus) {
  return TRANSITIONS[from]?.includes(to) ?? false;
}

export function assertTransition(from: SessionStatus, to: SessionStatus, action: string) {
  if (!canTransition(from, to)) {
    const ended = TERMINAL_STATUSES.includes(from);
    const msg = ended
      ? `Session cannot ${action} because it has already been ${from === 'COMPLETED' ? 'completed' : STATUS_PHRASE[from]}.`
      : `Session cannot ${action} while it is ${STATUS_PHRASE[from] ?? from.toLowerCase()}.`;
    throw new AppError(409, 'SESSION_INVALID_TRANSITION', msg, { from, to });
  }
}
