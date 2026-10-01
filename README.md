# Light Skate

A real-time **skating-venue operating system**: customer → check-in → photo → waiver → payment → session → timer →
warnings → equipment → end → return → history → reporting. The backend and PostgreSQL are the source of truth; the React
app is a fast, touch-friendly view on top of them.

* **Staff app** (`/#/staff`): live rink with photo cards and countdowns, 6-step check-in, customer search, daily history,
  equipment, incident report, one-tap emergency information.
* **Admin** (`/#/admin`, permission-gated): overview, customers, visits, payments + refunds, equipment, incidents, staff &
  roles, reports (daily/range, CSV), pricing, capacity & policies, devices, close-day, audit log.

## Quick start

```bash
npm install
export DATABASE_URL=postgres://user:pass@localhost:5432/lightskate   # an empty PostgreSQL ≥ 14 database
npm run migrate && npm run seed        # schema + clearly-fake demo venue (owner/manager/supervisor/frontdesk/rental @lightskate.demo)
npm run build && npm start             # http://localhost:8080  (API + worker + web app)
# development: npm run dev:api  and  npm run dev:web  (http://localhost:5173)
```
Demo password for every seeded user: `LightSkate-Demo-2026!` (override with `DEMO_PASSWORD`). Details: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Tests

```bash
npm test                 # 122 backend tests (real PostgreSQL) + 15 frontend unit tests
npm run typecheck
npm run build && npm run e2e   # 32 browser checks: real server + DB + Chromium (fake camera), two "tablets"
```
Backend tests need a PostgreSQL reachable at `postgres://lightskate:lightskate@localhost:5432/lightskate_test`
(see `backend/vitest.config.ts`; the suite drops and recreates that database's `public` schema). The e2e script
creates/drops `lightskate_e2e` and expects a Chromium (`CHROMIUM_PATH` to override).

## Documentation
* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — assessment, diagrams, state machine, timers, concurrency, idempotency, outbox, realtime, offline, security, privacy, scaling.
* [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) — every acceptance scenario → the automated test that proves it, plus **what is not built** and known limitations.
* [docs/API.md](docs/API.md) — endpoint reference.
* [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — environment, production, workers, backups, monitoring, go-live checklist.

## Layout
```
backend/src/modules/   domain modules (customers, visits, sessions(+machine), payments, equipment, incidents, waivers, pricing, reports, …)
backend/src/shared/    command runner (tx + idempotency), audit, events/outbox, errors, phone/money/time, rate limit
backend/src/worker/    timer transitions, outbox delivery, retention
backend/migrations/    001…007 SQL (forward-only)
web/src/               React app (staff/, admin/, components/, realtime, offline queue)
e2e/run.mjs            browser acceptance run
```

## Principles (enforced by code and tests)
Timestamps not countdowns · backend decides everything · commands not CRUD · one transaction per command · idempotency on
money and other critical commands · immutable event/audit history · outbox for side effects · realtime is only a hint ·
protected photos · least-privilege + object-level authorisation · integer money · venue-local days.

## Install on a phone/tablet (no app store)
Host the app over **HTTPS** (see docs/DEPLOYMENT.md), open it in Chrome (Android) or Safari (iOS), then
*Menu → Install app / Add to Home screen*. It opens full-screen like a native app. The service worker caches only
the app shell, never API data or photos. (Camera access needs HTTPS or `localhost`.)
