# Light Skate — Flutter mobile app

A native Flutter client for the same Light Skate backend as the web app (`../backend`) — same API,
same permissions, same database, same business rules. This is not a reskin of the web app; it's
independent Dart/Flutter code, built against the documented REST API (`../docs/API.md`).

## What's built right now

- **Sign in** (`lib/screens/login_screen.dart`) — same `/auth/login` endpoint, token stored on-device.
- **Live dashboard** (`lib/screens/dashboard_screen.dart`) — the flagship screen: capacity, today's
  visitors/revenue, waiting list, live rink summary, and a card per skater with a live countdown
  (colour + label from the venue's own configured warning thresholds, same rule the backend's worker
  uses — see `lib/widgets/session_level.dart`), a private authenticated photo per customer
  (`lib/widgets/authed_photo.dart`), and durable alerts. Refreshes automatically every 5 seconds and
  on pull-to-refresh.

This was verified against a real running backend with real seeded demo data — not just compiled: real
login, real photo fetches (6/6 succeeded), a real countdown confirmed ticking frame-to-frame, zero
console errors.

## What's not built yet

Everything else the web app has: check-in (phone → photo capture → waiver → payment → start), customer
search/profile/history, equipment, incidents, and the whole admin area (reports, pricing, settings,
staff, audit log, day close). The web app (`../web`) is the complete reference for every screen and
flow — this mobile app is the start of porting that to Flutter, not a finished parallel product.
Realtime is polling (every 5s) for now; the web app also holds a live WebSocket for instant
cross-device updates, which is the natural next addition here (`web_socket_channel` is already a
dependency).

## Running it

```bash
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080   # or any device/emulator
```
Point `API_BASE_URL` at wherever your `backend` is running (see `../docs/DEPLOYMENT.md`). The backend
must either serve this app's origin itself, or allow it via `CORS_ORIGIN` in `backend/.env` — see
"CORS" in `../docs/DEPLOYMENT.md`. A native Android/iOS build needs no CORS configuration at all
(browser-only restriction); only running `flutter run -d chrome` or a separately-hosted Flutter-web
build does.

## Getting a real .apk file

This project was written and tested in a cloud sandbox that has the Flutter SDK but **not** the
Android SDK (its network policy blocks `dl.google.com`, which the Android SDK installer needs — not a
code issue, a network policy in that one environment). So the actual `.apk` has to be built somewhere
with Android tooling. Two ways, in order of effort:

1. **Automatic, no install needed:** push this repo to GitHub. The included workflow
   (`.github/workflows/build-mobile-apk.yml`) builds a release APK on every push to `mobile/` using
   GitHub's own hosted runners (which already have the Android SDK) and uploads it as a downloadable
   build artifact. You can also trigger it manually from the Actions tab and pass the backend URL the
   app should point at.
2. **On your own machine:** install [Android Studio](https://developer.android.com/studio) (it sets up
   the Android SDK for you), then:
   ```bash
   flutter build apk --release --dart-define=API_BASE_URL=https://your-venue.example.com
   # → build/app/outputs/flutter-apk/app-release.apk
   ```

iOS needs a Mac with Xcode regardless of either path above (`flutter build ipa`), which this sandbox
also cannot provide.

## Project layout
```
lib/
  api/api_client.dart       REST client: bearer auth, device id, idempotency keys, server-clock sync
  models/dashboard.dart     typed models matching the backend's JSON exactly
  widgets/                  session_card, status_badge, authed_photo (private photo fetch), theme-aware level logic
  screens/                  login_screen, dashboard_screen
  theme.dart                same colour palette as web/src/styles.css, so both clients read as one product
```
