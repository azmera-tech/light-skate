# API reference (`/api/v1`)

Auth: `Authorization: Bearer <token>` from `POST /auth/login`. Optional `X-Device-Id` (a registered device).
State-changing calls send `Idempotency-Key` (required where marked ★). Errors:
`{ "error": { "code", "message", "details?", "requestId" } }`. Money is integer minor units (`20000` = 200 ETB).
Times are ISO-8601 UTC; every list response that shows live state carries `serverTime`.

| Method & path | Permission | Notes |
| --- | --- | --- |
| `POST /auth/login` · `POST /auth/logout` · `GET /auth/me` | — | login is rate limited; 423 when locked |
| `GET /config` · `GET /emergency` · `GET /products?customerId=` | authenticated | client-facing settings, pricing applicable now |
| `GET /time` · `GET /health` | public | health reports outbox backlog |
| `GET /customers?q=` · `POST /customers` ★ · `GET/PATCH /customers/:id` · `GET /customers/:id/history` | `customer.read/create/update` | `POST` → `409 POSSIBLE_DUPLICATE` unless `confirmDistinct` |
| `POST /customers/:id/erase` ★ | `customer.delete` | privacy erasure; keeps financial/audit records |
| `POST /customers/:id/photos?purpose=PROFILE\|VISIT&visitId=` | `customer.create/update` | raw image body (JPEG/PNG/WebP), 5 MB |
| `GET /photos/:id/content` · `POST /photos/:id/signed-url` · `GET /photos/:id/signed?exp&sig` | `customer.read` | private; signed URL lives 60 s |
| `GET /waivers/current` · `GET/POST /waivers/versions` · `POST /customers/:id/waiver-acceptance` | `waiver.manage` / `customer.*` | versions immutable |
| `POST /visits` · `GET /visits?date&filter` · `GET /visits/:id` | `session.create` / `visit.read` | filter: all, completed, active, cancelled, expired, payment_issues, incidents |
| `POST /sessions` · `GET /sessions?group=live\|waiting\|expiring` · `GET /sessions/:id` | `session.create` / `session.read` | |
| `POST /sessions/:id/start` ★ · `/pause` · `/resume` · `/extend` ★ · `/end` ★ · `/cancel` · `/correct` ★ | `session.create/pause/extend/end/cancel/correct` | `correct`: `CHANGE_DURATION` or `REOPEN` (reason required) |
| `POST /payments` ★ · `GET /payments` · `GET /payments/:id` · `POST /payments/:id/refund` ★ · `/confirm` `/cancel` `/fail` | `payment.create/read/refund` | |
| `GET /equipment` · `POST /equipment` · `GET /equipment/:id` | `equipment.read/manage` | |
| `POST /equipment/:id/assign` ★ · `/return` ★ · `/inspect` · `/damage` · `/maintenance/start` · `/maintenance/complete` · `/out-of-service` · `/maintenance/photo` | `equipment.assign/return/maintenance` | |
| `POST /incidents` · `GET /incidents` · `GET /incidents/:id` · `POST /incidents/:id/transition` · `POST /incidents/:id/attachments` | `incident.create/read/manage` | redacted for reporters without `incident.read` |
| `GET /dashboard` | `session.read` | one snapshot for the live screen |
| `GET /reports/daily?date` · `GET /reports/range?from&to&group` | `reports.read` | venue-local days |
| `GET /day-close/preview` · `POST /day-close` ★ · `GET /day-closes` | `dayclose.manage` | |
| `GET/POST/PATCH /staff` · `POST /staff/:id/reset-password` · `GET /roles` | `staff.manage` | no privilege escalation |
| `GET/POST/PATCH /devices` | `device.manage` | |
| `GET/PUT /settings` · `PUT /capacity` · `GET/POST/PATCH /pricing` | `settings.manage` / `capacity.manage` / `pricing.manage` | audited before/after |
| `GET /audit` | `audit.read` | filters: action prefix, entityType, entityId, actorId, from, to, before |
| `GET /notifications` · `POST /notifications/:id/ack` | `session.read` | durable alerts |
| `POST /sync/commands` | authenticated | offline replay; allow-list: END/PAUSE/RESUME/EXTEND_SESSION, RETURN_EQUIPMENT |
| `WS /realtime` | authenticated (first message `{type:'auth', token}`) | events: `{type:'event', event, aggregateType, aggregateId, payload}` |
