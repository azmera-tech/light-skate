/**
 * Money is always an integer count of minor units (ETB santim: 1 ETB = 100).
 * No floating point is used for stored or computed amounts. Parsing/formatting
 * operate on strings and integer arithmetic only.
 */
export type Minor = number; // safe-integer; int8 values from pg are parsed to Number (see db.ts)

export function parseMajorToMinor(input: string): Minor {
  const s = input.trim();
  const m = /^(\d{1,12})(?:\.(\d{1,2}))?$/.exec(s);
  if (!m) throw new Error(`Invalid money amount: ${input}`);
  const whole = m[1];
  const frac = (m[2] ?? '').padEnd(2, '0');
  return Number(whole) * 100 + Number(frac);
}

export function formatMinor(minor: Minor, currency = 'ETB'): string {
  const neg = minor < 0;
  const abs = Math.abs(minor);
  const whole = Math.trunc(abs / 100).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const frac = (abs % 100).toString().padStart(2, '0');
  return `${neg ? '-' : ''}${whole}${frac === '00' ? '' : '.' + frac} ${currency}`;
}

export function assertMinor(n: unknown, label = 'amount'): asserts n is Minor {
  if (typeof n !== 'number' || !Number.isSafeInteger(n) || n < 0) {
    throw new Error(`${label} must be a non-negative integer number of minor units`);
  }
}
