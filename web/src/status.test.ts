import { describe, it, expect } from 'vitest';
import { levelFor, remainingFor } from './components/ui';

const W = [{ minutes: 15, level: 'YELLOW' }, { minutes: 5, level: 'ORANGE' }, { minutes: 1, level: 'RED' }];
const s = (over: object) => ({ status: 'ACTIVE', scheduledEndAt: '2026-09-30T18:00:00Z', pausedAt: null, pauseCountsTowardTime: false, ...over });

describe('remaining time is derived from timestamps (same rule as the backend)', () => {
  const now = Date.parse('2026-09-30T17:30:00Z');
  it('active: end - now', () => expect(remainingFor(s({}), now)).toBe(1800));
  it('overtime is negative', () => expect(remainingFor(s({}), Date.parse('2026-09-30T18:07:05Z'))).toBe(-425));
  it('paused (clock frozen): end - pausedAt, independent of now', () => {
    const p = s({ status: 'PAUSED', pausedAt: '2026-09-30T17:10:00Z' });
    expect(remainingFor(p, now)).toBe(3000);
    expect(remainingFor(p, now + 3_600_000)).toBe(3000);
  });
  it('paused but counting toward time: keeps running', () => {
    expect(remainingFor(s({ status: 'PAUSED', pausedAt: '2026-09-30T17:10:00Z', pauseCountsTowardTime: true }), now)).toBe(1800);
  });
  it('not started: null', () => expect(remainingFor(s({ scheduledEndAt: null }), now)).toBeNull());
});

describe('warning levels follow configurable thresholds', () => {
  it('normal > 15 min', () => expect(levelFor(16 * 60, 'ACTIVE', W)).toBe('normal'));
  it('yellow at 15, orange at 5, red at 1', () => {
    expect(levelFor(15 * 60, 'ACTIVE', W)).toBe('yellow');
    expect(levelFor(5 * 60, 'EXPIRING', W)).toBe('orange');
    expect(levelFor(60, 'EXPIRING', W)).toBe('red');
  });
  it('expired at or past zero, paused is its own state', () => {
    expect(levelFor(0, 'ACTIVE', W)).toBe('expired');
    expect(levelFor(-5, 'EXPIRED', W)).toBe('expired');
    expect(levelFor(100, 'PAUSED', W)).toBe('paused');
  });
  it('respects a venue that uses different thresholds', () => {
    expect(levelFor(9 * 60, 'ACTIVE', [{ minutes: 10, level: 'YELLOW' }])).toBe('yellow');
    expect(levelFor(11 * 60, 'ACTIVE', [{ minutes: 10, level: 'YELLOW' }])).toBe('normal');
  });
});
