/**
 * Canonical phone representation = E.164 (e.g. +251912345678).
 * Ethiopian equivalents all collapse to the same value:
 *   0912345678, +251912345678, 251912345678, 00251912345678, 912345678
 */
export interface NormalizedPhone {
  e164: string;
  valid: true;
}

export function normalizePhone(raw: string | null | undefined, defaultCountry = '251'): string | null {
  if (!raw) return null;
  let s = raw.trim().replace(/[\s\-().]/g, '');
  if (!/^\+?\d+$/.test(s)) return null;
  if (s.startsWith('00')) s = '+' + s.slice(2);
  if (s.startsWith('+')) {
    const digits = s.slice(1);
    if (digits.startsWith('251')) return validEt(digits.slice(3));
    return /^[1-9]\d{7,14}$/.test(digits) ? '+' + digits : null;
  }
  if (s.startsWith('251') && s.length === 12) return validEt(s.slice(3));
  if (s.startsWith('0')) return validEt(s.slice(1));
  if (s.length === 9) return validEt(s);
  return null;
}

function validEt(national: string): string | null {
  // 9 digits. Mobile numbers start with 9 (Ethio Telecom) or 7 (Safaricom Ethiopia); landlines 1-5.
  if (!/^[1-579]\d{8}$/.test(national)) return null;
  return '+251' + national;
}

/** Mask for low-privilege displays: +251 9** *** 678 */
export function maskPhone(e164: string | null): string | null {
  if (!e164) return null;
  return e164.slice(0, -3).replace(/\d/g, (c, i) => (i > 5 ? '*' : c)) + e164.slice(-3);
}
