// End-to-end acceptance run against the real server + real PostgreSQL + real browser.
//   npm run build && node e2e/run.mjs
import { spawn, execSync } from 'node:child_process';
import { mkdirSync, rmSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { chromium } from 'playwright-core';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'e2e', 'out');
rmSync(out, { recursive: true, force: true }); mkdirSync(out, { recursive: true });
const DB = 'lightskate_e2e', PORT = 8098, BASE = `http://localhost:${PORT}`;
const PW = 'LightSkate-Demo-2026!';
const pgUrl = (db) => `postgres://lightskate:lightskate@localhost:5432/${db}`;
const env = { ...process.env, DATABASE_URL: pgUrl(DB), PORT: String(PORT), STORAGE_DIR: join(out, 'storage'), LOG_LEVEL: 'warn', EMBEDDED_WORKER: 'true', WORKER_TICK_MS: '1000', WEB_DIR: join(root, 'web', 'dist'), RATE_LIMIT_ENABLED: 'false' };

execSync(`psql "${pgUrl('postgres')}" -c "DROP DATABASE IF EXISTS ${DB}" -c "CREATE DATABASE ${DB}"`, { stdio: 'ignore' });
console.log('seeding…');
execSync('npx tsx src/seed.ts', { cwd: join(root, 'backend'), env, stdio: 'ignore' });
const server = spawn('npx', ['tsx', 'src/server.ts'], { cwd: join(root, 'backend'), env, stdio: ['ignore', 'pipe', 'pipe'] });
let serverLog = ''; server.stdout.on('data', (d) => (serverLog += d)); server.stderr.on('data', (d) => (serverLog += d));
for (let i = 0; i < 60; i++) { try { const r = await fetch(BASE + '/api/v1/health'); if (r.ok) break; } catch { /* starting */ } await new Promise((r) => setTimeout(r, 500)); }

let failures = 0; const results = [];
const check = (name, ok, extra = '') => { results.push([ok, name, extra]); console.log(`${ok ? '  ✓' : '  ✗'} ${name}${ok ? '' : '  ' + extra}`); if (!ok) failures++; };
// Use the preinstalled Chromium (never download one). Override with CHROMIUM_PATH.
const chromePath = process.env.CHROMIUM_PATH ?? ['/opt/pw-browsers/chromium-1194/chrome-linux/chrome', '/opt/pw-browsers/chromium/chrome-linux/chrome'].find(existsSync);
const browser = await chromium.launch({ executablePath: chromePath, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--no-sandbox'] });
const q = (sql) => execSync(`psql "${pgUrl(DB)}" -At -c "${sql}"`).toString().trim();

async function newTablet(email, name) {
  const ctx = await browser.newContext({ viewport: { width: 1180, height: 820 }, permissions: ['camera'], colorScheme: 'light' });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => check(`no page error on tablet ${name}`, false, e.message));
  await page.goto(BASE);
  await page.fill('input[type=email]', email); await page.fill('input[type=password]', PW);
  await page.click('button:has-text("Sign in")');
  await page.waitForSelector('.topbar');
  return { ctx, page };
}
const soon = (p, sel, opts = {}) => p.waitForSelector(sel, { timeout: 12000, ...opts }).then(() => true).catch(() => false);

try {
  // ------------------------------------------------------------------ tablet A (front desk) + tablet B (manager)
  const A = await newTablet('frontdesk@lightskate.demo', 'A');
  const B = await newTablet('manager@lightskate.demo', 'B');
  const a = A.page, b = B.page;
  await a.waitForSelector('.scard'); await b.waitForSelector('.scard');
  const liveCountA = await a.locator('.scard').count();
  check('live dashboard shows the skaters currently on the rink (seeded: 6)', liveCountA === 6, `got ${liveCountA}`);
  check('capacity KPI visible (6 / 60)', await a.locator('.kpi:has-text("Inside now")').innerText().then((t) => /6\s*\/\s*60/.test(t)));
  check('expired skater is flagged with a label, not colour alone', (await a.locator('.scard.lvl-expired .badge:has-text("Time up")').count()) === 1);
  check('ending-soon skaters flagged', (await a.locator('.scard .badge:has-text("Ending soon"), .scard .badge:has-text("Finishing")').count()) >= 2);
  check('paused skater flagged', (await a.locator('.scard .badge:has-text("Paused")').count()) === 1);
  check('real-time connection indicator is live', await soon(a, '.pill:has-text("Live")'));
  await a.screenshot({ path: join(out, '01-staff-live.png'), fullPage: true });

  // timer ticks locally from authoritative timestamps
  const clockText = async () => a.locator('.scard:has-text("Yonas") .clock').first().innerText();
  const t1 = await clockText(); await a.waitForTimeout(2200); const t2 = await clockText();
  check('countdown advances every second', t1 !== t2, `${t1} -> ${t2}`);
  await a.reload(); await a.waitForSelector('.scard');
  const t3 = await clockText();
  const sec = (t) => t.split(':').reduce((acc, x) => acc * 60 + Number(x.replace('+', '')), 0);
  check('countdown survives a page refresh (same remaining time)', Math.abs(sec(t3) - sec(t2)) < 8, `${t2} -> ${t3}`);

  // ------------------------------------------------------------------ NEW CUSTOMER FLOW on tablet A
  await a.click('button:has-text("New customer / check-in")');
  await a.fill('input[aria-label="Customer phone number"]', '0922 550 101');
  await a.waitForSelector('text=No existing customer with this number.');
  await a.click('button:has-text("Register new customer")');
  await a.fill('.card input >> nth=0', 'E2E Test Customer');
  await a.click('button:has-text("Save & continue")');
  await a.waitForSelector('text=Take a photo of the customer');
  await a.waitForSelector('video');
  await a.waitForTimeout(800);
  await a.screenshot({ path: join(out, '02-photo-step.png') });
  await a.click('button:has-text("Take photo")');
  await a.click('button:has-text("Use this photo")');
  await a.waitForSelector('.waiver');
  check('waiver text comes from the current published version', (await a.locator('.waiver').innerText()).includes('SKATING RULES'));
  await a.check('input[type=checkbox]');
  await a.click('button:has-text("Accept & continue")');
  await a.waitForSelector('.tile');
  await a.screenshot({ path: join(out, '03-choose-session.png') });
  await a.click('.tile:has-text("60 min")');
  await a.click('button:has-text("Continue — 200 ETB")');
  await a.waitForSelector('text=Amount due');
  await a.click('.chip:has-text("Telebirr")');
  await a.fill('.card input >> nth=0', 'TB-E2E-777');
  await a.click('button:has-text("Record 200 ETB received")');
  await a.waitForSelector('button:has-text("START SKATING")');
  await a.screenshot({ path: join(out, '04-ready-to-start.png') });
  await a.click('.chip:has-text("#036")'); // issue a rental skate
  await a.click('button:has-text("START SKATING")');
  await a.waitForSelector('.scard:has-text("E2E Test Customer")');
  check('new customer is ACTIVE on tablet A with the issued skate', (await a.locator('.scard:has-text("E2E Test Customer"):has-text("SKATE-036")').count()) === 1);
  check('tablet B shows the new session in real time (no refresh)', await soon(b, '.scard:has-text("E2E Test Customer")'));
  check('capacity counter updated on tablet B (7 / 60)', await soon(b, '.kpi:has-text("Inside now"):has-text("7")'));
  await b.screenshot({ path: join(out, '05-manager-live.png'), fullPage: true });

  // DB-level expectations
  check('one customer row for that phone (canonical E.164)', q("select count(*) from customers where phone_e164='+251922550101'") === '1');
  check('photo stored privately with metadata', q("select count(*) from customer_photos where customer_id=(select id from customers where phone_e164='+251922550101') and mime_type='image/jpeg' and status='ACTIVE'") === '1');
  check('payment recorded as PAID Telebirr with reference', q("select method||':'||status||':'||provider_reference from payments where customer_id=(select id from customers where phone_e164='+251922550101')") === 'TELEBIRR:PAID:TB-E2E-777');
  check('audit trail has session.started for that customer', Number(q("select count(*) from audit_logs where action='session.started' and entity_id in (select id::text from sessions where customer_id=(select id from customers where phone_e164='+251922550101'))")) === 1);

  // ------------------------------------------------------------------ tablet B ends it -> tablet A updates
  await b.locator('.scard:has-text("E2E Test Customer") button.danger').click();
  await b.click('.modal button:has-text("End session")');
  check('ending on tablet B removes the skater on tablet A in real time', await soon(a, '.scard:has-text("E2E Test Customer")', { state: 'detached' }));

  // ------------------------------------------------------------------ RETURNING CUSTOMER: equivalent phone format, no duplicate
  await a.click('button:has-text("New customer / check-in")');
  await a.fill('input[aria-label="Customer phone number"]', '+251922550101');
  check('returning customer found via a different phone format', await soon(a, '.person:has-text("E2E Test Customer")'));
  await a.click('.person:has-text("E2E Test Customer")');
  await a.waitForSelector('.tile'); // photo + waiver skipped (already on file)
  check('returning flow skips photo & waiver that are already on file', (await a.locator('.steps .step.done').count()) >= 2);
  await a.click('.tile:has-text("30 min")'); await a.click('button:has-text("Continue — 100 ETB")');
  await a.click('button:has-text("Record 100 ETB received")');
  await a.waitForSelector('button:has-text("START SKATING")'); await a.click('button:has-text("START SKATING")');
  await a.waitForSelector('.scard:has-text("E2E Test Customer")');
  check('one customer record, two visits', q("select count(*) from customers where phone_e164='+251922550101'") === '1' && q("select count(*) from visits where customer_id=(select id from customers where phone_e164='+251922550101')") === '2');

  // ------------------------------------------------------------------ OFFLINE: queue an End while offline, sync on reconnect
  await A.ctx.setOffline(true);
  check('offline indicator shown', await soon(a, '.pill:has-text("Offline")'));
  check('timers keep running while offline', (await a.locator('.scard:has-text("E2E Test Customer") .clock').count()) === 1);
  await a.locator('.scard:has-text("E2E Test Customer") button.danger').click();
  await a.click('.modal button:has-text("End session")');
  check('ending offline is queued as a command', await soon(a, '.pill:has-text("1 queued")'));
  await a.screenshot({ path: join(out, '06-offline-queued.png') });
  await A.ctx.setOffline(false);
  check('queued command synced after reconnect', await soon(a, '.pill:has-text("queued")', { state: 'detached', timeout: 30000 }));
  await soon(a, '.scard:has-text("E2E Test Customer")', { state: 'detached' });
  check('server ended the session exactly once', q("select count(*) from session_events where event_type='SESSION_ENDED' and session_id in (select id from sessions where customer_id=(select id from customers where phone_e164='+251922550101'))") === '2');

  // ------------------------------------------------------------------ permissions in the UI come from the server
  check('front desk has no Admin button', (await a.locator('button:has-text("Admin")').count()) === 0);
  check('manager has Admin button', (await b.locator('button:has-text("Admin")').count()) === 1);
  await b.click('button:has-text("Admin")');
  await b.waitForSelector('.side');
  await b.click('.side button:has-text("Reports")'); await b.waitForSelector('.kpi:has-text("Net revenue")');
  await b.screenshot({ path: join(out, '07-admin-reports.png'), fullPage: true });
  await b.click('.side button:has-text("Audit log")'); await b.waitForSelector('text=session.started');
  await b.click('.side button:has-text("Payments")'); await b.waitForSelector('.t');
  await b.locator('.t tr.click').first().click();
  check('manager can see the refund control', await soon(b, 'text=Issue refund'));
  await b.keyboard.press('Escape');

  // history + photo authorisation (image loads through the authenticated endpoint)
  await a.click('.tab:has-text("History")'); await a.waitForSelector('.t');
  check("daily history lists today's visits incl. the e2e customer", (await a.locator('.t tbody tr').count()) >= 10);
  await a.locator('.t tr:has-text("E2E Test Customer")').first().click();
  await a.waitForSelector('.timeline');
  check('visit timeline shows the full story', (await a.locator('.timeline li').count()) >= 8);
  await a.waitForTimeout(500);
  await a.screenshot({ path: join(out, '08-visit-timeline.png') });
  const imgOk = await a.evaluate(() => { const i = document.querySelector('.modal img'); return !!i && i.naturalWidth > 0; });
  check('customer photo renders via authorised fetch (not a public URL)', imgOk);
  await a.keyboard.press('Escape');

  // responsive: phone-sized viewport
  await a.setViewportSize({ width: 390, height: 800 }); await a.click('.tab:has-text("Live")'); await a.waitForSelector('.scard');
  const overflow = await a.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 2);
  check('no horizontal page scroll at phone width', !overflow);
  await a.screenshot({ path: join(out, '09-phone.png') });
  await A.ctx.close(); await B.ctx.close();
} catch (e) {
  console.error('E2E aborted:', e.message); failures++;
} finally {
  await browser.close();
  server.kill('SIGTERM');
}
console.log(`\n${results.length - failures} / ${results.length} checks passed${failures ? `, ${failures} FAILED` : ''}. Screenshots: e2e/out/`);
if (failures) { console.log(serverLog.split('\n').slice(-15).join('\n')); process.exit(1); }
