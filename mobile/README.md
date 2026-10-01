# Light Skate — Flutter mobile app

A native Flutter client for the same Light Skate backend as the web app (`../backend`) — same API,
same permissions, same database, same business rules. This is not a reskin of the web app; it's
independent Dart/Flutter code, built against the documented REST API (`../docs/API.md`), and it's a
full staff-operations client now, not a login-and-dashboard demo.

## What's built

Every area of the brief, wired to the real backend (no mocking, no second database):

- **Auth & permissions**: sign in/out, session persistence, role-aware navigation driven entirely by
  the `permissions` array from `/auth/me` (never a hardcoded role switch) — `lib/app_shell.dart`.
- **Live dashboard**: capacity, today's visitors/revenue, waiting list, live rink with per-skater
  countdown cards, quick actions, durable alerts with acknowledge/resolve — `lib/screens/dashboard_screen.dart`.
- **Check-in wizard**: customer search (returning) / registration incl. duplicate detection (new),
  photo capture via the device camera, waiver display + checkbox + optional drawn signature, session
  package selection with pricing/discount, payment collection, equipment issue, start — the full
  customer→session pipeline in one flow — `lib/screens/checkin/checkin_flow.dart`.
- **Session management**: extend, pause/resume, end, cancel, correct (reopen/change-duration),
  equipment issue/return, full event timeline — `lib/screens/session_detail_screen.dart`.
- **Customers**: search, profile (stats, waiver status, emergency contacts, visit history), edit,
  erase (privacy) — `lib/screens/customers/`.
- **Equipment**: list/filter by status, assign/return/damage/maintenance workflow, detail sheet with
  history — `lib/screens/equipment_screen.dart`, `lib/screens/equipment/`.
- **Incidents**: report (type/severity/description/photo), list (redacted for staff without full
  read access), status workflow (reported → acknowledged/action-taken/under-review → closed) —
  `lib/screens/incidents/`.
- **Daily history**: date-filtered visit list + per-visit detail (payments, timeline) —
  `lib/screens/history_screen.dart`, `lib/screens/history/`.
- **Admin**: overview, daily/range reports, settings (timers, pausing, check-in rules, payment
  methods, retention, emergency info, waiver publishing), pricing, staff & roles, devices, audit log,
  day close — `lib/screens/admin/`, permission-gated per page.
- **Realtime**: a live WebSocket (`lib/api/realtime_client.dart`) refreshes the dashboard instantly on
  any server event, with reconnect/backoff; other screens poll (5–10s) — see Known limitations below.

Verified end-to-end against a real running backend with real seeded demo data (Flutter web +
Playwright, driving the actual UI, not a mocked harness): sign-in, the full check-in flow for a
returning customer (search → session package → payment → equipment → start), the new session
appearing live on the dashboard, and the dashboard's realtime KPIs/photos/countdowns all confirmed
correct against the server's own data. One real bug was found and fixed this way: several check-in
wizard steps built their "Continue" button outside the state scope that selecting an option actually
rebuilds, so the button never re-enabled after a selection — fixed by restructuring each step so the
whole step (body + actions) rebuilds together.

## Known limitations (intentionally not built, or simplified)

- **Push notifications**: the in-app durable alert feed (dashboard "Alerts" section, ack/resolve)
  exists and is wired up; native push (FCM/APNs, lock-screen alerts) does not exist anywhere in the
  backend yet — there's no device-token registration or push dispatch to build a client for.
- **CSV export**: the backend has no CSV endpoint. The admin Reports screen's range view offers the
  data as copyable CSV text generated client-side from the same JSON the charts use, rather than a
  file download.
- **Offline queueing**: the backend supports a limited offline command queue (end/pause/resume/extend
  session, return equipment — see `POST /sync/commands`) built for the web app; this mobile client
  does not yet detect connectivity loss and queue those commands locally. Starting sessions, payments,
  and refunds are intentionally never queueable (by backend design, to protect capacity/payment
  correctness) on either client.
- **Realtime is dashboard-only**: the WebSocket triggers an instant dashboard refresh on any event;
  other screens (equipment, incidents, history) refresh on their own poll timer or on pull-to-refresh,
  not instantly. Extending this to every screen is mechanical (reuse `RealtimeClient`) but not done.
- **Memberships, real payment-provider integrations (Telebirr/bank/card), multi-location** — not
  implemented in the backend at all (explicit `TODO(phase 2/3)` markers in `backend/src`), so there's
  nothing for the mobile app to call. Payments are "staff attest cash/reference received" only, same
  as the web app.
- **iOS**: builds are untested (no Mac/Xcode available in the environment this was built in). The code
  is plain Flutter with no platform-specific branches beyond the Android manifest, so it should build,
  but `flutter build ipa` has not actually been run.

## Demo credentials

Same seeded venue as the web app (`npm run seed` from `backend/`), password `LightSkate-Demo-2026!`
for every account:

| Email | Role |
| --- | --- |
| `owner@lightskate.demo` | OWNER — every permission |
| `manager@lightskate.demo` | MANAGER — everything except staff/settings/pricing/customer-delete |
| `supervisor@lightskate.demo` | SUPERVISOR — front-desk + discounts/refunds/corrections/maintenance, no admin area |
| `frontdesk@lightskate.demo` | FRONT_DESK — check-in, sessions, payments; no discounts/refunds/corrections |
| `rental@lightskate.demo` | RENTAL_STAFF — equipment + incident reporting only, read-only elsewhere |

Sign in as different roles to see the bottom nav, admin icon, and in-screen action buttons change —
every gate is a permission check against `/auth/me`'s `permissions` array, not a role-name switch.

## Running it

```bash
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080   # or any device/emulator
```
Point `API_BASE_URL` at wherever your `backend` is running (see `../docs/DEPLOYMENT.md`). A native
Android/iOS build needs no CORS configuration (browser-only restriction); only `flutter run -d chrome`
or a separately-hosted Flutter-web build does — set `CORS_ORIGIN` in `backend/.env`, see "CORS" in
`../docs/DEPLOYMENT.md`. The Android release manifest declares `usesCleartextTraffic="true"` so a
plain `http://` backend URL works out of the box; tighten this for a production deployment with a real
HTTPS backend.

## Getting a real .apk file

This project is written and tested in a cloud sandbox that has the Flutter SDK but **not** the Android
SDK (its network policy blocks `dl.google.com`, which the Android SDK installer needs — not a code
issue, a network policy in that one environment). So the actual `.apk` has to be built somewhere with
Android tooling:

1. **Automatic, no install needed:** push this repo to GitHub. The included workflow
   (`.github/workflows/build-mobile-apk.yml`) builds a release APK (arm64-v8a split, to keep the file
   size reasonable) on every push to `mobile/` using GitHub's own hosted runners, and both uploads it
   as a build artifact and pushes it to a dedicated `apk-builds` git branch (for environments that
   can't reach Actions-artifact storage). Trigger it manually from the Actions tab to pass a specific
   backend URL.
2. **On your own machine:** install [Android Studio](https://developer.android.com/studio), then:
   ```bash
   flutter build apk --release --dart-define=API_BASE_URL=https://your-venue.example.com
   # → build/app/outputs/flutter-apk/app-release.apk
   ```

iOS needs a Mac with Xcode regardless (`flutter build ipa`).

## Project layout
```
lib/
  api/
    api_client.dart         REST client: bearer auth, device id, idempotency keys, server-clock sync
    realtime_client.dart    WebSocket client: auth handshake, ping/pong, reconnect+backoff, resync-on-event
  models/                   typed models matching the backend's JSON exactly, one file per domain
  widgets/                  shared UI: session_card, status_badge, authed_photo, camera_capture,
                             signature_pad, reason_dialog, emergency_dialog
  screens/
    login_screen.dart, dashboard_screen.dart
    checkin/                the full check-in wizard
    session_detail_screen.dart
    customers/, history/, equipment/, incidents/, admin/
  app_shell.dart             permission-filtered bottom nav + admin entry + realtime wiring
  theme.dart                 same colour palette as web/src/styles.css, so both clients read as one product
  format.dart                shared money/date/phone formatting helpers
```
