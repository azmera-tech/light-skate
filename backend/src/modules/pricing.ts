import type { Ctx } from '../shared/ctx.js';
import { assertCan } from '../shared/ctx.js';
import { E } from '../shared/errors.js';
import { audit } from '../shared/audit.js';
import { getSettings, getVenue, type Settings } from '../settings.js';
import { many, one, type Queryable } from '../db.js';
import { toCamel, toCamelAll } from './util.js';
import { localDateIn, localWeekdayIn } from '../shared/time.js';
import { isMinor } from './customers.js';

export function dayKind(settings: Settings, tz: string, at: Date): 'HOLIDAY' | 'WEEKEND' | 'WEEKDAY' {
  if (settings.holidays.includes(localDateIn(tz, at))) return 'HOLIDAY';
  return settings.weekendDays.includes(localWeekdayIn(tz, at)) ? 'WEEKEND' : 'WEEKDAY';
}

export function ruleApplies(rule: { day_type: string; customer_type: string }, kind: string, customerIsChild: boolean | null) {
  if (rule.day_type !== 'ANY' && rule.day_type !== kind) return false;
  if (customerIsChild === null || rule.customer_type === 'ANY') return true;
  return rule.customer_type === (customerIsChild ? 'CHILD' : 'ADULT');
}

export async function listApplicableProducts(q: Queryable, venueId: string, at: Date, customerId?: string | null) {
  const settings = await getSettings(q, venueId);
  const venue = await getVenue(q, venueId);
  let child: boolean | null = null;
  if (customerId) {
    const c = await one<any>(q, 'SELECT date_of_birth FROM customers WHERE id=$1 AND venue_id=$2', [customerId, venueId]);
    if (c) child = isMinor(c.date_of_birth, settings.minorAgeYears, at);
  }
  const kind = dayKind(settings, venue.timezone, at);
  const rows = await many<any>(q, `SELECT * FROM pricing_rules WHERE venue_id=$1 AND kind='SESSION' AND active ORDER BY sort_order, duration_minutes`, [venueId]);
  return rows.filter((r) => ruleApplies(r, kind, child)).map(toCamel);
}

export async function listPricingRules(q: Queryable, venueId: string) {
  return toCamelAll(await many(q, `SELECT * FROM pricing_rules WHERE venue_id=$1 ORDER BY kind, sort_order, duration_minutes`, [venueId]));
}

export interface PricingInput {
  kind: 'SESSION' | 'EXTENSION'; name: string; durationMinutes: number; priceMinor: number;
  dayType?: 'ANY' | 'WEEKDAY' | 'WEEKEND' | 'HOLIDAY'; customerType?: 'ANY' | 'ADULT' | 'CHILD'; active?: boolean; sortOrder?: number;
}

export async function createPricingRule(ctx: Ctx, i: PricingInput) {
  assertCan(ctx, 'pricing.manage');
  const venue = await getVenue(ctx.db, ctx.venueId);
  const r = await ctx.db.query(
    `INSERT INTO pricing_rules (venue_id, kind, name, duration_minutes, price_minor, currency, day_type, customer_type, active, sort_order, created_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$11) RETURNING *`,
    [ctx.venueId, i.kind, i.name, i.durationMinutes, i.priceMinor, venue.currency, i.dayType ?? 'ANY', i.customerType ?? 'ANY', i.active ?? true, i.sortOrder ?? 0, ctx.now]);
  await audit(ctx, { action: 'pricing.created', entityType: 'pricing_rule', entityId: r.rows[0].id, after: i });
  return toCamel(r.rows[0]);
}

export async function updatePricingRule(ctx: Ctx, id: string, patch: Partial<PricingInput>) {
  assertCan(ctx, 'pricing.manage');
  const before = (await ctx.db.query('SELECT * FROM pricing_rules WHERE id=$1 AND venue_id=$2 FOR NO KEY UPDATE', [id, ctx.venueId])).rows[0];
  if (!before) throw E.notFound('Pricing rule');
  const map: Record<string, string> = { name: 'name', durationMinutes: 'duration_minutes', priceMinor: 'price_minor', dayType: 'day_type', customerType: 'customer_type', active: 'active', sortOrder: 'sort_order' };
  const set: string[] = []; const params: unknown[] = [id];
  for (const [k, col] of Object.entries(map)) if ((patch as any)[k] !== undefined) { params.push((patch as any)[k]); set.push(`${col}=$${params.length}`); }
  if (!set.length) return toCamel(before);
  params.push(ctx.now); set.push(`updated_at=$${params.length}`);
  const after = (await ctx.db.query(`UPDATE pricing_rules SET ${set.join(',')} WHERE id=$1 RETURNING *`, params)).rows[0];
  // Existing sessions keep the price snapshotted at creation; only future sales use the new price.
  await audit(ctx, { action: 'pricing.changed', entityType: 'pricing_rule', entityId: id,
    before: { name: before.name, durationMinutes: before.duration_minutes, priceMinor: before.price_minor, active: before.active },
    after: { name: after.name, durationMinutes: after.duration_minutes, priceMinor: after.price_minor, active: after.active } });
  return toCamel(after);
}
