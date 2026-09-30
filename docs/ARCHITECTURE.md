# Light Skate — Architecture

Light Skate is a real-time skating-venue operating system. It controls the complete flow

```
Customer → Check-in → Photo → Waiver → Payment → Session → Timer → Warnings → Equipment → End → Return → History → Reporting
```

and treats the **backend + PostgreSQL as the only source of truth**. The React app displays state and requests
actions; it never decides payment success, capacity, authorisation, session validity or equipment availability.

## 1. Assessment of the starting point

The repository was empty (no code, no commits), so there was nothing to preserve or migrate. Nothing conflicted with the
requirements. Choices made, and why:

| Decision | Why |
| --- | --- |
| **Modular monolith** (one Node/TypeScript process, domain modules) | The brief forbids microservices without need. One deploy, one DB, transactional integrity across customer/visit/session/payment/equipment. |
| **PostgreSQL** with SQL-file migrations | Highly relational data; needs transactions, row locks, partial unique indexes, `LISTEN/NOTIFY`, `SKIP LOCKED`. |
| **Fastify + zod** | Small, fast, typed request validation, good WebSocket support. |
| **Local private file storage behind a driver interface** | One object-storage system, swappable for S3/R2 without touching domain code (see DEPLOYMENT). |
| **WebSocket realtime fed by `LISTEN/NOTIFY`** | No Redis needed. Worker and API can be separate processes. |
| **No Redis / Kafka / Kubernetes / Elasticsearch** | No demonstrated need. Rate limiting is in-process; see "Scaling later". |
| **React + Vite SPA, same origin** | Staff tablet + admin desktop in one app; served by the API process, no CORS surface. |

## 2. Component diagram

```
 Staff tablets / desktop (React SPA)                     Manager / admin (same SPA, /admin)
        │  HTTPS  REST /api/v1  (Bearer token, X-Device-Id, Idempotency-Key)        │
        │  WebSocket /api/v1/realtime  (auth in first message, never in the URL)    │
        ▼                                                                           ▼
 ┌───────────────────────────────── API process (Fastify) ─────────────────────────────────┐
 │ routes.ts ── validation (zod) ── permission check ── execute(): ONE DB transaction      │
 │                                   │                                                     │
 │   modules/  customers · visits · sessions(+state machine) · payments(+providers)        │
 │             equipment · incidents · waivers · pricing · reports · dashboard · dayclose   │
 │             admin(staff/devices/settings/capacity/audit) · sync(offline replay) · photos│
 │   shared/   ctx · audit · events (session/payment/equipment/incident events + outbox)   │
 │             command (idempotency) · errors · ratelimit · phone · money · time           │
 │   realtime/hub.ts  ◄── LISTEN ls_realtime ──────────────────────────────┐              │
 └──────────────┬──────────────────────────────────────────────────────────│──────────────┘
                │                                                          │
                ▼                                                          │
        PostgreSQL (source of truth)                              pg_notify (on commit)
  business tables · immutable event tables · outbox_events · idempotency_keys · audit_logs
                ▲                                                          │
                │                                                          │
 ┌──────────────┴───────── Worker (embedded in API or standalone `npm run worker`) ─────────┐
 │ every tick: session timers (warnings/expiring/expired/no-show) · outbox delivery          │
 │ every 10 min: photo retention · idempotency/auth-session housekeeping                     │
 └───────────────────────────────────────────────────────────────────────────────────────────┘
        Private object storage (customer/incident/maintenance photos) — never a public path
```

## 3. The core model

```
CUSTOMER  (persistent person)
   └─ VISIT  (one trip; LS-YYYYMMDD-00421)
        └─ SESSION  (the skating activity; state machine)
             ├─ SESSION EVENTS (immutable history)
             ├─ PAYMENTS → payment_transactions (append-only ledger) → refunds
             ├─ EQUIPMENT ASSIGNMENTS → equipment_events
             └─ EXTENSIONS / PAUSES
```

* A customer is **never duplicated per visit**. Phones are normalised to E.164 (`0912345678`, `+251912345678`,
  `251912345678`, `00251…`, `912345678` → `+251912345678`). Registering a number that already exists returns
  `409 POSSIBLE_DUPLICATE` ("Possible existing customer found.") and staff confirm *same person* or *different person*
  (a parent may register several children on one number, so phones are deliberately not `UNIQUE`; a per-phone advisory
  lock closes the race between two tablets).
* Customer history, daily history, revenue, reports are **views over the real records** — there is no separately
  maintained history table and no hand-edited aggregate.

## 4. Session state machine (`modules/sessions-machine.ts`)

```
CREATED → PAYMENT_PENDING → READY → CHECKED_IN → ACTIVE ⇄ PAUSED
                                                   │  └→ EXPIRING → (COMPLETED | EARLY_EXIT | EXPIRED)
   READY/PAYMENT_PENDING/CREATED/CHECKED_IN → CANCELLED        READY → NO_SHOW
   ACTIVE/PAUSED/EXPIRING → COMPLETED | EARLY_EXIT | EXPIRED   EXPIRED → COMPLETED | ACTIVE (extended)
```

* `EXPIRED` = paid time ran out but the customer is still on the floor (still counts toward capacity and stays on the
  dashboard in red until staff end it).
* Terminal states (`COMPLETED, EARLY_EXIT, CANCELLED, NO_SHOW`) have **no outgoing transitions**. The only exit is the
  explicit, permissioned, reason-required `REOPEN` correction, which re-checks capacity and the one-live-session rule and
  writes `SESSION_REOPENED` + an audit row.
* There is **no generic `PUT /sessions/:id`**. Only business commands exist: create, start, pause, resume, extend, end,
  cancel, correct. Each authenticates, authorises, validates, re-checks state under a row lock, writes events + outbox +
  audit in the same transaction.

## 5. Timers

* Authoritative fields: `started_at`, `scheduled_end_at`, `actual_end_at`, `original_duration_seconds`,
  `current_duration_seconds`, `paused_at`, `total_paused_seconds`. **No `remaining_seconds` column exists.**
* Clients compute `remaining = scheduled_end_at − serverNow()`; `serverNow` is the local clock corrected by the offset
  learned from every response's `serverTime`. Refresh, tablet restart, another device, offline — same answer.
* **No per-second writes.** The worker does one indexed scan (`sessions(venue_id, status, scheduled_end_at)`) each tick
  for sessions whose end is near/past and performs only meaningful transitions:
  `ACTIVE → EXPIRING` (configurable minutes), `→ EXPIRED`, and warning events `WARNING_15_MIN / 5 / 1` (configurable).
  Warnings are de-duplicated by `(session, type, end-time)` with a partial unique index, so they fire once, and **re-arm
  automatically after an extension** (new end time). A late worker only emits the tightest crossed threshold.
* **Pause policy is configurable** (`pause.countsTowardTime`, snapshotted on the session at start). Default: the clock
  freezes while paused and the end time moves out by the pause length on resume.
* Extension adds to the end time and records `original_end_at`, `added_seconds`, `new_end_at`, actor, device, reason and
  any payment in `session_extensions` + an immutable `SESSION_EXTENDED` event. The original duration is never overwritten.

## 6. Concurrency design

| Risk | Mechanism |
| --- | --- |
| Two starts, one space left | `SELECT … FROM venues FOR NO KEY UPDATE` serialises capacity decisions; occupancy is **derived** (`count(*)` of live sessions) inside the lock — no counter to drift. |
| Two staff issue the same skate | Row lock on the equipment unit + **partial unique index** `equipment_assignments(equipment_id) WHERE returned_at IS NULL`. Loser gets `"SKATE-034 is no longer available."` |
| Customer on two sessions | **Partial unique index** `sessions(customer_id) WHERE status IN (live states)` backs the application check. |
| Double refund / overpay | Row lock on the payment + recomputed refundable amount; overpay check sums paid + pending under the session lock. |
| Two devices end/extend the same session | Session row lock; the loser re-reads the new state and gets a precise conflict ("already ended early…"). |
| Duplicate request after timeout | Idempotency (below). |

**Lock order is fixed everywhere: session → venue → customer → equipment.** All row locks are
`FOR NO KEY UPDATE`, never `FOR UPDATE`: almost every table has a foreign key to `venues/sessions/customers`, and each
`INSERT` takes a `FOR KEY SHARE` lock on the referenced row; a plain `FOR UPDATE` conflicts with that and two
transactions deadlock. (This was found by the concurrency tests: 10 simultaneous starts took 27 s and mostly failed
with deadlocks; with `NO KEY UPDATE` they finish in ~1 s with exactly the right winners.) The command runner also retries
the whole transaction on `40P01/40001`.

## 7. Idempotency

`Idempotency-Key` (8–128 chars) is **required** for: create customer, start/end/extend/correct session, record payment,
refund, assign/return equipment, close day, create staff. The key row is inserted **in the same transaction** as the
business change (`INSERT … ON CONFLICT DO NOTHING`), so:

* a crash can never leave a half-recorded command (both commit or neither),
* concurrent duplicates serialise on the unique key; the loser returns the stored response with `Idempotent-Replay: true`,
* the same key with a different body is rejected (`422 IDEMPOTENCY_KEY_REUSED`),
* keys are scoped per `(venue, user, key)`, so one user's key can never replay another's response,
* failed commands roll back the key, so a corrected retry is allowed.

## 8. Transactions, events, outbox

Every command runs in one transaction: authorise → (idempotency) → lock → validate → write business rows →
**immutable event row** → **audit row** → **outbox row** → commit.

* `session_events`, `payment_events`, `payment_transactions`, `equipment_events`, `incident_events`, `audit_logs`,
  `day_closes` are **append-only at the database level** (trigger rejects `UPDATE`/`DELETE`). Published
  `waiver_versions` text is immutable too.
* The **outbox worker** (`worker/outbox.ts`) claims rows with `FOR NO KEY UPDATE SKIP LOCKED`, creates durable
  notifications, resolves stale alerts, and `pg_notify`s the realtime channel — all inside one transaction, so the
  notification and the "processed" mark commit together (effectively exactly-once for DB effects, at-least-once
  delivery). Failures back off exponentially (`available_at`), are recorded (`attempt_count`, `last_error`), never block
  other events, and **never affect the already-committed business state** — a session stays `COMPLETED` if the worker is
  down; the event is delivered when it returns.

## 9. Realtime

* The DB is truth; the socket is a hint. Messages are tiny operational events
  (`SESSION_STARTED`, `SESSION_EXTENDED`, `SESSION_ENDED`, `EQUIPMENT_ASSIGNED`, `EQUIPMENT_RETURNED`,
  `CAPACITY_CHANGED`, …) whitelisted to ids/timestamps/counters — **no names, phones, photos or money**. Clients refetch the
  authorised data they need.
* Auth is sent in the first message (5 s deadline), never in the URL. Venue scoping is enforced on broadcast.
* On any event, on every (re)connect, when the tab becomes visible, and every 30 s as a safety net, the client refetches.
  Missing every event still yields correct screens. The client has a heartbeat with a pong deadline and reacts to the
  browser `offline` event.

## 10. Offline behaviour (what is and is not supported)

Supported with **command-based sync**, not last-write-wins:

* viewing the last synchronised dashboard/customers, **timers keep running** from authoritative timestamps,
* queueing `END_SESSION`, `PAUSE_SESSION`, `RESUME_SESSION`, `EXTEND_SESSION`, `RETURN_EQUIPMENT` in `localStorage`.

On reconnect the queue is posted in order to `POST /sync/commands`. Each command reuses its `requestId` as the
idempotency key (so a replay whose first attempt actually reached the server is `DUPLICATE`, not applied twice), goes
through the **same validated code path and permissions** as a live request, and gets an outcome:
`ACCEPTED | DUPLICATE | CONFLICT | REJECTED` with a readable message ("Session has already been ended early."). The
client's `issuedAt` is honoured for `actual_end_at` only within sane bounds (clamped to `[started_at, now]`) and stored
as `clientIssuedAt`.

**Deliberately not offline:** starting sessions (capacity), payments, refunds, permission/staff/settings/pricing changes,
customer creation, day close. The backend rejects them in the replay endpoint (`OFFLINE_NOT_ALLOWED`). We do not
pretend otherwise.

## 11. Security model

* **AuthN:** scrypt password hashes, opaque random 256-bit bearer tokens (only the SHA-256 is stored), 12 h expiry,
  revoked on logout / disable / password reset, lockout after 5 failures (15 min), identical errors and timing for unknown
  users, login rate limits (per IP and per IP+email). *PIN quick-unlock and MFA are not implemented (TODO).*
* **AuthZ:** permissions are derived **server-side** from the authenticated user's role on every request; nothing
  from the client (`role`, headers) is trusted. Every route declares its permission; every query is scoped by
  `venue_id`, so another venue's object is indistinguishable from "not found" (BOLA). Sensitive fields are redacted by
  permission (incident details, payment amounts, photo ids, revenue).
* **Privilege escalation guards:** `staff.manage` holders cannot grant a role with permissions they lack, cannot edit an
  account more powerful than their own, and cannot change their own role/status.
* **Denied attempts are audited** (`security.permission_denied`) *before* the 403 is returned.
* **Photos:** validated from bytes (magic numbers, parsed dimensions, size/pixel caps; the `Content-Type` header is
  ignored), EXIF/XMP/text metadata stripped (no GPS leak), server-generated keys, stored outside any public path with
  `0600` permissions, served only through an authenticated endpoint (or a 60 s HMAC-signed URL), `nosniff` + restrictive CSP
  headers, access audited (deduplicated), retention enforced by a worker.
* **Rate limits:** login, search, upload, payments, refunds, sync, signed URLs, global cap. In-process store (see scaling).
* **Headers:** helmet CSP (`default-src 'self'`), `frame-ancestors 'none'`, camera permission only for self.
* **Injection:** all SQL is parameterised; `LIKE` inputs are escaped.
* **Errors:** readable messages, stable codes, request id; internals never leak.

## 12. Data protection (Ethiopian Personal Data Protection Proclamation No. 1321/2016 E.C.)

This is engineering groundwork, **not legal advice** — have counsel review before launch.

* Purpose-limited photo capture with configurable retention (`profilePhotoDays`, `visitPhotoDays`,
  `incidentAttachmentDays`) and a worker that deletes expired files.
* Minors: DOB-driven minor detection, guardian contact capture, guardian-required waiver acceptance, child pricing.
* Waiver acceptances record version, time, staff, device, signature, guardian; old versions are immutable.
* Erasure is a **policy layer**: `POST /customers/:id/erase` (owner/admin) anonymises the profile, deletes photos and
  guardian/signature data, and **retains** visits, sessions, payments and audit rows needed for financial/legal duties.
* Least privilege, object-level checks, audit of personal-data access, no PII on the realtime channel.
* Not yet built: data-subject *export*, consent record beyond the waiver, breach-notification workflow (TODO).

## 13. Reporting, time zones, money

* All timestamps are `timestamptz` (UTC). Every venue has a timezone (`Africa/Addis_Ababa`); "today", history dates and
  report days use the **venue-local** date (`visits.local_date` is stamped at creation; day bounds are computed in SQL
  with `AT TIME ZONE`). The staff member's device timezone is irrelevant.
* Money is **integer minor units** (`bigint`; 1 ETB = 100) in the database, API and UI; parsing/formatting uses string
  math — no floating point anywhere in financial paths.
* Reports are read-only queries (repeatable-read snapshots); they never mutate transactional data.

## 14. What is intentionally not built (clearly marked TODO in code/docs)

Memberships, reservations, customer portal, multi-location UI (schema carries `venue_id` everywhere), automated payment
providers (Telebirr/bank/card — the `PaymentProvider` interface exists, only the manual provider is implemented), manager
approval workflow for refunds/discounts (permission-gated today), QR check-in, push/SMS delivery channels
(`notification_deliveries` only implements `IN_APP`), PIN/MFA, payment reconciliation and maintenance-reminder jobs,
Amharic localisation, data-subject export.

## 15. Scaling later (only when justified)

Single API+worker+Postgres handles a venue comfortably. If needed: run the worker as its own process (already
supported), move the rate-limit store and ephemeral state to Redis, put photos on S3/R2 (swap `StorageDriver`), add a read
replica for reporting, then an analytics store fed by the outbox. The module boundaries and the outbox make each of these
incremental.
