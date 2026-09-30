/** Business errors carry a stable machine code and a human-readable message safe to show staff. */
export class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
  }
}

export const E = {
  badRequest: (code: string, msg: string, details?: unknown) => new AppError(400, code, msg, details),
  unauthorized: (msg = 'Please sign in to continue.') => new AppError(401, 'UNAUTHENTICATED', msg),
  forbidden: (msg: string, code = 'FORBIDDEN') => new AppError(403, code, msg),
  notFound: (what: string) => new AppError(404, 'NOT_FOUND', `${what} was not found.`),
  conflict: (code: string, msg: string, details?: unknown) => new AppError(409, code, msg, details),
  unprocessable: (code: string, msg: string, details?: unknown) => new AppError(422, code, msg, details),
  tooMany: (msg = 'Too many requests. Please slow down and try again shortly.') => new AppError(429, 'RATE_LIMITED', msg),
};

export function permissionDeniedMessage(perm: string): string {
  const friendly: Record<string, string> = {
    'payment.refund': "You don't have permission to issue refunds.",
    'settings.manage': "You don't have permission to change venue settings.",
    'staff.manage': "You don't have permission to manage staff accounts.",
    'pricing.manage': "You don't have permission to change pricing.",
    'session.extend': "You don't have permission to extend sessions.",
    'session.correct': "You don't have permission to correct sessions.",
    'audit.read': "You don't have permission to view the audit log.",
    'reports.read': "You don't have permission to view reports.",
    'customer.read': "You don't have permission to view customers.",
    'customer.delete': "You don't have permission to erase customer data.",
  };
  return friendly[perm] ?? `You don't have permission to do this (${perm}).`;
}
