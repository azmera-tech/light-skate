-- 003_operations: pricing, capacity, visits, sessions, session events
CREATE TABLE pricing_rules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  kind            text NOT NULL DEFAULT 'SESSION' CHECK (kind IN ('SESSION','EXTENSION')),
  name            text NOT NULL,
  duration_minutes integer NOT NULL CHECK (duration_minutes > 0),
  price_minor     bigint NOT NULL CHECK (price_minor >= 0),
  currency        text NOT NULL DEFAULT 'ETB',
  day_type        text NOT NULL DEFAULT 'ANY' CHECK (day_type IN ('ANY','WEEKDAY','WEEKEND','HOLIDAY')),
  customer_type   text NOT NULL DEFAULT 'ANY' CHECK (customer_type IN ('ANY','ADULT','CHILD')),
  active          boolean NOT NULL DEFAULT true,
  sort_order      integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pricing_rules_venue_idx ON pricing_rules (venue_id, kind, active);

CREATE TABLE capacity_rules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  max_capacity    integer NOT NULL CHECK (max_capacity >= 0),
  effective_from  timestamptz NOT NULL DEFAULT now(),
  created_by      uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX capacity_rules_idx ON capacity_rules (venue_id, effective_from DESC);

-- Per-venue, per-scope monotonic counters (visit numbers, receipt numbers, ...).
CREATE TABLE counters (
  venue_id  uuid NOT NULL REFERENCES venues(id),
  scope     text NOT NULL,
  n         integer NOT NULL DEFAULT 0,
  PRIMARY KEY (venue_id, scope)
);

CREATE TABLE visits (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id      uuid NOT NULL REFERENCES venues(id),
  visit_number  text NOT NULL,                 -- LS-YYYYMMDD-00421
  customer_id   uuid NOT NULL REFERENCES customers(id),
  local_date    date NOT NULL,                 -- venue-local date at creation
  status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','COMPLETED','CANCELLED')),
  checked_in_at timestamptz,
  closed_at     timestamptz,
  created_by    uuid REFERENCES users(id),
  device_id     uuid REFERENCES devices(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (venue_id, visit_number)
);
CREATE INDEX visits_day_idx ON visits (venue_id, local_date, created_at);
CREATE INDEX visits_customer_idx ON visits (customer_id, created_at DESC);

ALTER TABLE customer_photos ADD CONSTRAINT customer_photos_visit_fk FOREIGN KEY (visit_id) REFERENCES visits(id);
ALTER TABLE waiver_acceptances ADD CONSTRAINT waiver_acceptances_visit_fk FOREIGN KEY (visit_id) REFERENCES visits(id);

CREATE TABLE sessions (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id                    uuid NOT NULL REFERENCES venues(id),
  visit_id                    uuid NOT NULL REFERENCES visits(id),
  customer_id                 uuid NOT NULL REFERENCES customers(id),
  status                      text NOT NULL CHECK (status IN (
    'CREATED','PAYMENT_PENDING','READY','CHECKED_IN','ACTIVE','PAUSED','EXPIRING',
    'COMPLETED','EARLY_EXIT','CANCELLED','NO_SHOW','EXPIRED')),
  pricing_rule_id             uuid REFERENCES pricing_rules(id),
  product_name                text NOT NULL,           -- snapshot
  price_minor                 bigint NOT NULL CHECK (price_minor >= 0),
  discount_minor              bigint NOT NULL DEFAULT 0 CHECK (discount_minor >= 0),
  discount_reason             text,
  currency                    text NOT NULL,
  -- Authoritative timing: timestamps, never a decrementing counter.
  original_duration_seconds   integer NOT NULL CHECK (original_duration_seconds > 0),
  current_duration_seconds    integer NOT NULL CHECK (current_duration_seconds > 0),
  started_at                  timestamptz,
  scheduled_end_at            timestamptz,
  actual_end_at               timestamptz,
  paused_at                   timestamptz,             -- set while PAUSED
  total_paused_seconds        integer NOT NULL DEFAULT 0,
  pause_counts_toward_time    boolean NOT NULL DEFAULT false, -- policy snapshot at start
  wristband                   text,
  created_by                  uuid REFERENCES users(id),
  started_by                  uuid REFERENCES users(id),
  ended_by                    uuid REFERENCES users(id),
  device_id                   uuid REFERENCES devices(id),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  version                     integer NOT NULL DEFAULT 1,
  CHECK (discount_minor <= price_minor)
);
-- Hot path: live dashboard / worker scans.
CREATE INDEX sessions_live_idx ON sessions (venue_id, status, scheduled_end_at);
CREATE INDEX sessions_visit_idx ON sessions (visit_id);
CREATE INDEX sessions_customer_idx ON sessions (customer_id, created_at DESC);
CREATE INDEX sessions_started_idx ON sessions (venue_id, started_at);
-- Hard guarantee: a customer can never have two sessions on the floor / in progress.
CREATE UNIQUE INDEX sessions_one_live_per_customer ON sessions (customer_id)
  WHERE status IN ('CHECKED_IN','ACTIVE','PAUSED','EXPIRING','EXPIRED');

CREATE TABLE session_events (
  id             bigserial PRIMARY KEY,
  venue_id       uuid NOT NULL REFERENCES venues(id),
  session_id     uuid NOT NULL REFERENCES sessions(id),
  visit_id       uuid NOT NULL REFERENCES visits(id),
  event_type     text NOT NULL,
  from_status    text,
  to_status      text,
  actor_user_id  uuid REFERENCES users(id),
  device_id      uuid REFERENCES devices(id),
  occurred_at    timestamptz NOT NULL,
  metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_id     text
);
CREATE INDEX session_events_session_idx ON session_events (session_id, id);
-- A warning/expiry for a given end-time fires once; re-arms automatically after an extension.
CREATE UNIQUE INDEX session_events_warning_once ON session_events (session_id, event_type, (metadata->>'for_end_at'))
  WHERE event_type LIKE 'WARNING\_%' OR event_type = 'SESSION_EXPIRED';

CREATE TABLE session_extensions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id            uuid NOT NULL REFERENCES venues(id),
  session_id          uuid NOT NULL REFERENCES sessions(id),
  added_seconds       integer NOT NULL CHECK (added_seconds > 0),
  original_end_at     timestamptz NOT NULL,
  new_end_at          timestamptz NOT NULL,
  price_minor         bigint NOT NULL DEFAULT 0,
  payment_id          uuid,
  reason              text,
  extended_by         uuid REFERENCES users(id),
  device_id           uuid REFERENCES devices(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX session_extensions_session_idx ON session_extensions (session_id);

CREATE TABLE session_pauses (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id          uuid NOT NULL REFERENCES venues(id),
  session_id        uuid NOT NULL REFERENCES sessions(id),
  paused_at         timestamptz NOT NULL,
  resumed_at        timestamptz,
  duration_seconds  integer,
  counted_toward_time boolean NOT NULL,
  reason            text,
  paused_by         uuid REFERENCES users(id),
  resumed_by        uuid REFERENCES users(id),
  device_id         uuid REFERENCES devices(id)
);
CREATE INDEX session_pauses_session_idx ON session_pauses (session_id);
CREATE UNIQUE INDEX session_pauses_one_open ON session_pauses (session_id) WHERE resumed_at IS NULL;
