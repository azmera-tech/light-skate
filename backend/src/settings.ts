import { z } from 'zod';
import type { Queryable } from './db.js';
import { many } from './db.js';

const paymentMethod = z.object({
  code: z.string().regex(/^[A-Z0-9_]{2,24}$/),
  label: z.string().min(1).max(40),
  requiresReference: z.boolean().default(false),
  enabled: z.boolean().default(true),
});

const hours = z.object({ open: z.string().regex(/^\d{2}:\d{2}$/), close: z.string().regex(/^\d{2}:\d{2}$/) }).nullable();

/** Every business policy the venue can tune. The backend reads these; the UI only displays them. */
export const SETTING_SCHEMAS = {
  paymentMethods: z.array(paymentMethod).min(1).default([
    { code: 'CASH', label: 'Cash', requiresReference: false, enabled: true },
    { code: 'BANK_TRANSFER', label: 'Bank transfer', requiresReference: true, enabled: true },
    { code: 'TELEBIRR', label: 'Telebirr', requiresReference: true, enabled: true },
    { code: 'CARD', label: 'Card', requiresReference: true, enabled: true },
    { code: 'OTHER', label: 'Other', requiresReference: false, enabled: true },
  ]),
  warnings: z
    .array(z.object({ minutes: z.number().int().min(1).max(240), level: z.enum(['YELLOW', 'ORANGE', 'RED']) }))
    .default([
      { minutes: 15, level: 'YELLOW' },
      { minutes: 5, level: 'ORANGE' },
      { minutes: 1, level: 'RED' },
    ]),
  expiringMinutes: z.number().int().min(1).max(240).default(15),
  pause: z.object({ enabled: z.boolean(), countsTowardTime: z.boolean() }).default({ enabled: true, countsTowardTime: false }),
  extensionOptionsMinutes: z.array(z.number().int().min(5).max(480)).min(1).default([15, 30, 60]),
  earlyExitGraceSeconds: z.number().int().min(0).max(3600).default(60),
  noShowMinutes: z.number().int().min(0).max(1440).default(180),
  waiverRequired: z.boolean().default(true),
  minorAgeYears: z.number().int().min(1).max(25).default(18),
  photoCapture: z.enum(['NEW_CUSTOMER', 'EVERY_VISIT', 'NEVER']).default('NEW_CUSTOMER'),
  wristbands: z.object({ enabled: z.boolean(), colors: z.array(z.string().min(1).max(20)) }).default({ enabled: false, colors: ['BLUE', 'GREEN', 'ORANGE', 'RED'] }),
  equipmentRequiredForStart: z.boolean().default(false),
  inspectOnReturn: z.boolean().default(false),
  cleaning: z
    .object({
      // Standard rule: every rental skate is cleaned after every customer use before it can be reissued.
      afterUseRequired: z.boolean(),
      deepCleanDays: z.number().int().min(1).max(90),
      inspectionDays: z.number().int().min(1).max(180),
    })
    .default({ afterUseRequired: true, deepCleanDays: 7, inspectionDays: 30 }),
  enforceOperatingHours: z.boolean().default(false),
  operatingHours: z.record(z.string().regex(/^[0-6]$/), hours).default({
    '0': { open: '09:00', close: '22:00' }, '1': { open: '09:00', close: '22:00' }, '2': { open: '09:00', close: '22:00' },
    '3': { open: '09:00', close: '22:00' }, '4': { open: '09:00', close: '22:00' }, '5': { open: '09:00', close: '23:00' },
    '6': { open: '09:00', close: '23:00' },
  }),
  weekendDays: z.array(z.number().int().min(0).max(6)).default([0, 6]),
  holidays: z.array(z.string().regex(/^\d{4}-\d{2}-\d{2}$/)).default([]),
  retention: z
    .object({
      profilePhotoDays: z.number().int().min(1).nullable(),
      visitPhotoDays: z.number().int().min(1).nullable(),
      incidentAttachmentDays: z.number().int().min(1).nullable(),
    })
    .default({ profilePhotoDays: null, visitPhotoDays: 90, incidentAttachmentDays: 1825 }),
  emergency: z
    .object({
      ambulance: z.string(), police: z.string(), fire: z.string(),
      venueContact: z.string(), manager: z.string(), address: z.string(), firstAid: z.string(),
    })
    .default({
      ambulance: '907', police: '991', fire: '939',
      venueContact: '', manager: '', address: '',
      firstAid: 'First aid kit: front desk, under the counter. Trained first-aider on shift: see manager.',
    }),
} as const;

export type SettingKey = keyof typeof SETTING_SCHEMAS;
export type Settings = { [K in SettingKey]: z.infer<(typeof SETTING_SCHEMAS)[K]> };

export function defaultSettings(): Settings {
  const out: any = {};
  for (const k of Object.keys(SETTING_SCHEMAS) as SettingKey[]) out[k] = (SETTING_SCHEMAS[k] as z.ZodTypeAny).parse(undefined);
  return out;
}

export async function getSettings(q: Queryable, venueId: string): Promise<Settings> {
  const rows = await many<{ key: string; value: unknown }>(q, 'SELECT key, value FROM system_settings WHERE venue_id = $1', [venueId]);
  const out: any = defaultSettings();
  for (const r of rows) {
    const schema = (SETTING_SCHEMAS as any)[r.key] as z.ZodTypeAny | undefined;
    if (!schema) continue;
    const parsed = schema.safeParse(r.value);
    if (parsed.success) out[r.key] = parsed.data;
  }
  return out;
}

export async function getVenue(q: Queryable, venueId: string) {
  const rows = await many(q, 'SELECT id, name, timezone, currency FROM venues WHERE id = $1', [venueId]);
  return rows[0] as { id: string; name: string; timezone: string; currency: string };
}
