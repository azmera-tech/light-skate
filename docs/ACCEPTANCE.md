# Acceptance mapping, limitations and TODO

All backend tests run against a real PostgreSQL (no mocks). `E2E` = `e2e/run.mjs` (real browser, server, DB).

| # | Scenario (from the brief) | Proven by |
| --- | --- | --- |
| 79 | New customer flow: phone → name → photo → waiver → 60 min → payment → start; customer, visit, payment, ACTIVE, correct start/end, capacity+1, dashboard, realtime, audit, session event | `test/flow.test.ts` "new customer flow"; `E2E` (UI end-to-end incl. DB assertions and realtime on a 2nd tablet) |
| 80 | Returning customer: one customer, two visits, no duplicate; equivalent phone formats | `flow.test.ts` "returning customer", "possible duplicates"; `units.test.ts` phone; `E2E` |
| 81 | Timer: 20:00 + 60 min → 21:00; 20:30 → 30 min; refresh/restart/other device | `flow.test.ts` "timer" (new app instance = restart); `sessions.test.ts` (no per-second writes); `E2E` (ticks, survives reload) |
| 82 | Capacity 2: A, B start, C rejected "VENUE FULL"; not frontend-only | `flow.test.ts` "capacity"; `concurrency.test.ts` (10 simultaneous starts → exactly 3) ; `E2E` |
| 83 | Two staff assign skate #034 simultaneously: one wins, other "…is no longer available" | `concurrency.test.ts` "equipment under simultaneous assignment" (+ unique-index guarantee) |
| 84 | Same payment command twice → one transaction, original result | `payments.test.ts` "idempotency" (sequential, 6 simultaneous, reuse with different body, restart) |
| 85 | Front desk refund rejected; manager permitted; all logged | `payments.test.ts` "refunds" (incl. `security.permission_denied` audit + simultaneous refunds) |
| 86 | Realtime A→B, B→A; disconnect leaves DB correct; reconnect reconciles | `recovery.test.ts` "realtime" (WebSocket client, no-PII check, cross-venue isolation); `E2E` (two tablets, offline→online) |
| 87 | Server restart: session remains, timer correct, no duplicates | `flow.test.ts` timer; `recovery.test.ts` "restarts" (incl. idempotent replay after restart) |
| 88 | Worker failure: session COMPLETED, outbox pending, worker returns, processed once | `recovery.test.ts` "outbox" (down, failing downstream with backoff, dedupe) |
| 89 | Photo security: not public, unauthorised denied, authorised allowed, metadata, audit, retention | `security.test.ts` "customer photo security" (+ EXIF strip, byte-level validation, signed URLs, erasure); `E2E` (renders via authorised fetch) |
| 90 | Daily history from real records | `reports.test.ts` (history filters, timeline, customer profile, daily report, venue-local date) ; `E2E` |
| 60 | Session/concurrency/security/payment/offline/recovery test areas | `sessions`, `concurrency`, `security`, `payments`, `offline`, `recovery` test files |
| 61 | Security testing list (BOLA, BFLA, auth bypass, data exposure, resource consumption, unsafe upload, injection, IDOR, rate-limit, privilege escalation) | `security.test.ts` (all covered; see describe blocks) |

Bugs the tests caught while building (kept as regression tests): foreign-key **deadlocks** under concurrent starts
(switched every row lock to `FOR NO KEY UPDATE`); **un-awaited audit write** for denied attempts; realtime envelope
`type` being overwritten; unused SQL parameters in a report; an **untyped timestamp parameter** making worker
housekeeping silently fail (found by the E2E server log); silent-offline detection on WebSockets; the Admin button
showing for front desk.

## Implemented vs the brief's MVP list (#69)
Authentication ✔ · roles ✔ · customer registration/search/photo ✔ · visits ✔ · waiver (versioned, minors/guardian) ✔ ·
payments (ledger, idempotent, refunds, pending/confirm/fail) ✔ · session create/timer/warnings/extend/pause/end/cancel/
correct ✔ · live dashboard ✔ · capacity ✔ · equipment assignment/return/damage/maintenance ✔ · today's + customer
history ✔ · audit log ✔ · realtime ✔ · reports (daily + range, CSV) ✔. Also built from Phase 2: incidents, emergency
info, wristbands (optional), day close, device registry, offline command queue, notifications (in-app),
pricing rules (day type, child/adult), configurable policies.

## NOT built / known limitations (deliberate, so nothing is pretended)
* **Memberships, reservations, customer portal, loyalty, multi-location UI** — architecture only (`venue_id` on every
  operational row, `membership: null` placeholder on the customer profile).
* **Payment providers:** only the *manual* provider (staff attest receipt of cash/transfer/card-terminal/Telebirr, with a
  reference). The `PaymentProvider` interface + `PENDING→PAID` confirm flow is where Telebirr/bank/card adapters plug in.
* **Manager-approval workflow** for refunds/discounts (PIN approval) — permission-gated only.
* **Auth extras:** no MFA, no PIN quick-unlock, no self-service password reset (admin reset exists). Tokens live in
  `localStorage` (XSS would expose them; CSP is strict and React escapes output). Consider HttpOnly cookies + CSRF
  tokens if you add third-party scripts.
* **Rate limiting is per API process** (in-memory). Fine for one node; use a shared store for several.
* **Uploads:** format/dimension/size validated and metadata stripped, but there is **no antivirus scan or re-encode**.
* **Storage driver:** local disk only (S3/R2 driver is a documented TODO behind the `StorageDriver` interface).
* **Notifications:** in-app durable alerts only; push/SMS channels (`notification_deliveries`) are TODO.
* **Jobs not yet implemented:** payment reconciliation against provider statements, maintenance reminders, scheduled
  report e-mails. Retention/housekeeping/outbox/timers are implemented.
* **Offline scope:** see ARCHITECTURE §10 — starting sessions, payments, refunds, and settings need connectivity.
  The service worker / installable PWA shell is **not** included, so a fully cold offline start depends on the browser
  cache; the app does restore the last known config/user from `localStorage`.
* **Occupancy on the waiting list** counts paid-but-unstarted sessions; walk-up queue management beyond that is not modelled.
* **Localisation:** English only (Amharic TODO); the venue timezone/currency are configurable.
* **Data-subject export** and a breach-response workflow are not built. The waiver text is a *template* requiring legal review.
* **Docker files** are provided but were not built/tested in the authoring environment (no Docker daemon).
* **First-venue bootstrap** in production is manual (no `init-venue` CLI yet).
