import { describe, it, expect } from 'vitest';
import { normalizePhone, maskPhone } from '../src/shared/phone.js';
import { parseMajorToMinor, formatMinor, assertMinor } from '../src/shared/money.js';
import { localDateIn, localWeekdayIn, addDaysToDate } from '../src/shared/time.js';
import { stableStringify } from '../src/shared/command.js';
import { hashPassword, verifyPassword } from '../src/auth/password.js';
import { validateImage, stripJpegMetadata } from '../src/storage/image.js';
import { makePng, makeJpeg } from './helpers.js';

describe('phone normalisation (Ethiopia)', () => {
  it('collapses equivalent formats to one canonical E.164 value', () => {
    for (const p of ['0912345678', '+251912345678', '251912345678', '00251912345678', '912345678', '09 12-34 56 78', '+251 (91) 234-5678']) {
      expect(normalizePhone(p), p).toBe('+251912345678');
    }
    expect(normalizePhone('0712345678')).toBe('+251712345678'); // Safaricom Ethiopia
    expect(normalizePhone('0111234567')).toBe('+251111234567'); // Addis landline
  });
  it('rejects garbage and keeps other countries in E.164', () => {
    for (const p of ['', '123', 'abc', '09123', '0012', '+251812345678', null, undefined]) expect(normalizePhone(p as any), String(p)).toBeNull();
    expect(normalizePhone('+254712345678')).toBe('+254712345678');
  });
  it('masks numbers for low-privilege views', () => {
    expect(maskPhone('+251912345678')).toBe('+25191****678');
  });
});

describe('money', () => {
  it('parses and formats exact minor units without floats', () => {
    expect(parseMajorToMinor('200')).toBe(20000);
    expect(parseMajorToMinor('0.1')).toBe(10);
    expect(parseMajorToMinor('0.29')).toBe(29);
    expect(parseMajorToMinor('19.99')).toBe(1999);
    expect(() => parseMajorToMinor('1.999')).toThrow();
    expect(() => parseMajorToMinor('-1')).toThrow();
    expect(formatMinor(2450000)).toBe('24,500 ETB');
    expect(formatMinor(10050)).toBe('100.50 ETB');
    expect(() => assertMinor(1.5)).toThrow();
    expect(() => assertMinor(-1)).toThrow();
    // the classic float trap: 0.1 + 0.2
    expect(parseMajorToMinor('0.1') + parseMajorToMinor('0.2')).toBe(30);
  });
});

describe('venue-local time', () => {
  it('computes the local date in the venue timezone, not the server/device timezone', () => {
    expect(localDateIn('Africa/Addis_Ababa', new Date('2026-09-30T21:30:00Z'))).toBe('2026-10-01'); // 00:30 next day in UTC+3
    expect(localDateIn('Africa/Addis_Ababa', new Date('2026-09-30T20:59:59Z'))).toBe('2026-09-30');
    expect(localDateIn('America/New_York', new Date('2026-09-30T02:00:00Z'))).toBe('2026-09-29');
    expect(localWeekdayIn('Africa/Addis_Ababa', new Date('2026-10-03T10:00:00Z'))).toBe(6);
    expect(addDaysToDate('2026-09-30', 1)).toBe('2026-10-01');
  });
});

describe('misc', () => {
  it('stable stringify is key-order independent (idempotency request hashing)', () => {
    expect(stableStringify({ a: 1, b: { c: [1, 2], d: undefined } })).toBe(stableStringify({ b: { d: undefined, c: [1, 2] }, a: 1 }));
    expect(stableStringify({ a: 1 })).not.toBe(stableStringify({ a: 2 }));
  });
  it('password hashing is salted and verifiable', async () => {
    const a = await hashPassword('correct horse battery'), b = await hashPassword('correct horse battery');
    expect(a).not.toBe(b);
    expect(await verifyPassword('correct horse battery', a)).toBe(true);
    expect(await verifyPassword('wrong', a)).toBe(false);
    expect(await verifyPassword('x', 'garbage')).toBe(false);
  });
});

describe('image validation', () => {
  it('parses dimensions for png/jpeg and strips metadata', () => {
    const png = validateImage(makePng(320, 240));
    expect(png).toMatchObject({ mime: 'image/png', ext: 'png', width: 320, height: 240 });
    const exif = makePng(120, 120, []);
    expect(validateImage(exif).width).toBe(120);
    const jpg = validateImage(makeJpeg(640, 480, true));
    expect(jpg).toMatchObject({ mime: 'image/jpeg', width: 640, height: 480 });
    expect(jpg.bytes.includes(Buffer.from('GPS'))).toBe(false);
    expect(stripJpegMetadata(makeJpeg(100, 100, false)).length).toBe(makeJpeg(100, 100, false).length);
  });
  it('rejects non-images whatever they claim to be', () => {
    for (const b of [Buffer.from('hello world, this is not an image at all....'), Buffer.from('%PDF-1.4 ..........................'), Buffer.alloc(100, 0)]) {
      expect(() => validateImage(b)).toThrow();
    }
  });
});
