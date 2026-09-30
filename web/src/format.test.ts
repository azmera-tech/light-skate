import { describe, it, expect } from 'vitest';
import { formatMoney, toMinor, fmtClock, fmtDuration, phoneDisplay, shiftDate, setVenueTimezone, fmtTime, initials } from './format';

describe('money (exact integer minor units)', () => {
  it('formats without floats', () => {
    expect(formatMoney(20000)).toBe('200 ETB');
    expect(formatMoney(2450000)).toBe('24,500 ETB');
    expect(formatMoney(10050)).toBe('100.50 ETB');
    expect(formatMoney(-5000)).toBe('-50 ETB');
    expect(formatMoney(null)).toBe('—');
  });
  it('parses typed amounts exactly', () => {
    expect(toMinor('200')).toBe(20000);
    expect(toMinor('0.1')).toBe(10);
    expect(toMinor('19.99')).toBe(1999);
    expect(toMinor('1.999')).toBeNull();
    expect(toMinor('abc')).toBeNull();
    expect(toMinor('-5')).toBeNull();
    expect((toMinor('0.1') ?? 0) + (toMinor('0.2') ?? 0)).toBe(30);
  });
});

describe('countdown display', () => {
  it('formats m:ss, h:mm:ss and overtime', () => {
    expect(fmtClock(59)).toBe('0:59');
    expect(fmtClock(60 * 25 + 5)).toBe('25:05');
    expect(fmtClock(3600 + 16 * 60)).toBe('1:16:00');
    expect(fmtClock(-425)).toBe('+7:05');
    expect(fmtDuration(3600)).toBe('60 min'.replace('60 min', '1 h'));
    expect(fmtDuration(1800)).toBe('30 min');
  });
});

describe('venue-local time', () => {
  it('renders times in the venue timezone regardless of device timezone', () => {
    setVenueTimezone('Africa/Addis_Ababa');
    expect(fmtTime('2026-09-30T17:00:00Z')).toBe('20:00');
    setVenueTimezone('UTC');
    expect(fmtTime('2026-09-30T17:00:00Z')).toBe('17:00');
    setVenueTimezone('Africa/Addis_Ababa');
  });
  it('shifts dates without timezone drift', () => {
    expect(shiftDate('2026-09-30', 1)).toBe('2026-10-01');
    expect(shiftDate('2026-03-01', -1)).toBe('2026-02-28');
  });
});

describe('misc', () => {
  it('shows Ethiopian numbers in local grouping', () => {
    expect(phoneDisplay('+251912345678')).toBe('091 234 5678');
    expect(phoneDisplay(null)).toBe('—');
    expect(initials('Demo Hana Tesfaye')).toBe('HT');
  });
});
