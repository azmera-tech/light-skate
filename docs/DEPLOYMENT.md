# Deployment

## Requirements
Node.js ≥ 20 (developed on 22), PostgreSQL ≥ 14 (`pg_trgm` extension; `CREATE EXTENSION` is run by the first migration —
on managed databases ensure the migrating role may create trusted extensions), a persistent volume for photos, HTTPS in
front of the app (a reverse proxy such as Caddy/nginx; WebSockets must be proxied — `Upgrade` headers).

## Quick start (development)
```bash
npm install
createdb lightskate                                   # or any DATABASE_URL
export DATABASE_URL=postgres://user:pass@localhost:5432/lightskate
npm run migrate                                        # applies backend/migrations/*.sql in order
npm run seed                                           # demo venue, staff, 36 skates, history (idempotent)
npm run dev:api                                        # API + embedded worker on :8080
npm run dev:web                                        # Vite on :5173 (proxies /api and the WebSocket)
```
Demo logins (`*@lightskate.demo`, password from `DEMO_PASSWORD`, default `LightSkate-Demo-2026!`):
`owner`, `manager`, `supervisor`, `frontdesk`, `rental`. **Never run the seed in production.**

## Production (one node)
```bash
npm ci && npm run build                # compiles backend to backend/dist and web to web/dist
cp .env.example .env                   # set DATABASE_URL, SIGNING_SECRET (openssl rand -hex 32), STORAGE_DIR
cd backend && node dist/server.js      # runs pending migrations at start, serves API + web app
```
or `docker compose up -d --build` (see `docker-compose.yml`; the Dockerfile was not built in the authoring environment).

Create the first venue/owner (production does not seed): run `npm run seed` once on a scratch database to see the
shape, or insert via a one-off script using `bootstrap.createVenue/createUser`. (TODO: interactive `npm run init-venue`.)

### Separate worker
Set `EMBEDDED_WORKER=false` on the API and run `node backend/dist/worker.js` as its own process/container. Several
workers may run at once (`SKIP LOCKED`). The API only *listens* for notifications, so realtime works across processes.

### Health and monitoring
`GET /api/v1/health` → `{status, outbox:{pending, oldest_seconds, failing}, realtimeClients}` (503 if the DB is down).
Alert when `outbox.oldest_seconds` grows (worker down) or `failing > 0`. Logs are structured JSON (pino) with a
`reqId` that also appears in every audit row and error response; `Authorization` headers are redacted. Add uptime
monitoring on `/api/v1/health`, DB monitoring (connections, locks, replication lag), disk monitoring for the photo volume,
and an error tracker of your choice (none bundled).

## Backups (database and files are separate!)
* **PostgreSQL:** nightly base backup **plus WAL archiving for point-in-time recovery** (`pg_basebackup` + `archive_command`,
  or your managed provider's PITR), stored in a *different* account/region. **Restore-test monthly** into a scratch
  instance and run `npm run migrate` + a smoke check; an untested backup is an assumption.
* **Photos (`STORAGE_DIR`):** a database backup does **not** contain them. Snapshot/replicate the volume (or move to S3/R2
  with versioning + lifecycle rules + cross-region replication) and keep the retention policy consistent: when the worker
  deletes an expired photo, backups keep it until *their* retention expires — set backup retention to match your privacy
  policy and document it.
* Consider encrypting the volume and backups at rest.

## Swapping local storage for S3/R2
Implement `StorageDriver` (`put/get/delete/exists`) in `backend/src/storage/` using your S3 SDK, keep keys as generated
(`<venueId>/<kind>/<uuid>.<ext>`), use bucket-private ACLs and server-side encryption, and select it with
`STORAGE_DRIVER`. The download endpoints already authorise every read; if you prefer presigned GET URLs from the bucket,
issue them from `POST /photos/:id/signed-url` after the same permission check. (TODO: bundled S3 driver.)

## Reverse proxy notes
Terminate TLS there; forward `X-Forwarded-For` (the app trusts the proxy for client IPs used in rate limits and audit);
allow WebSocket upgrades on `/api/v1/realtime`; set generous idle timeouts (≥ 60 s); do not cache `/api/*`.

## Upgrades
Deploy the new build; migrations are forward-only SQL files applied under an advisory lock at startup. Never edit an
applied migration; add a new numbered file. Take a backup first.

## Security checklist before go-live
- [ ] `SIGNING_SECRET` set; demo data absent; default passwords changed; owner password long and unique
- [ ] HTTPS only; HSTS at the proxy; firewall exposes only 443
- [ ] DB not publicly reachable; DB role has no superuser (only needs to create the extension once)
- [ ] Photo volume outside any web root, owner-only permissions, backed up, encrypted at rest
- [ ] Register every tablet as a device; disable devices that are lost
- [ ] Waiver text reviewed by local counsel; retention periods set and documented; privacy notice displayed
- [ ] Backup **restore** rehearsed; monitoring on `/api/v1/health`
