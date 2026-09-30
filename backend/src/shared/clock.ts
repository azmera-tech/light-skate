/** Injectable clock so tests (and offline replay) can control time. */
let offsetMs = 0;
let fixed: number | null = null;

export const clock = {
  now(): Date {
    return new Date(fixed ?? Date.now() + offsetMs);
  },
  /** Test helper: freeze time at an instant. */
  freeze(d: Date | string) {
    fixed = new Date(d).getTime();
  },
  /** Test helper: move frozen (or live) time forward. */
  advance(ms: number) {
    if (fixed !== null) fixed += ms;
    else offsetMs += ms;
  },
  reset() {
    fixed = null;
    offsetMs = 0;
  },
};
