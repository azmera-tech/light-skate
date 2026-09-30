-- 006: incidents + operational notifications
CREATE TABLE incidents (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  incident_number text NOT NULL,
  customer_id     uuid REFERENCES customers(id),
  visit_id        uuid REFERENCES visits(id),
  session_id      uuid REFERENCES sessions(id),
  occurred_at     timestamptz NOT NULL,
  location        text,
  incident_type   text NOT NULL,
  severity        text NOT NULL CHECK (severity IN ('MINOR','MODERATE','SERIOUS','CRITICAL')),
  description     text NOT NULL,
  action_taken    text,
  manager_notified boolean NOT NULL DEFAULT false,
  status          text NOT NULL DEFAULT 'REPORTED' CHECK (status IN (
    'REPORTED','ACKNOWLEDGED','ACTION_TAKEN','UNDER_REVIEW','CLOSED')),
  reported_by     uuid NOT NULL REFERENCES users(id),
  device_id       uuid REFERENCES devices(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (venue_id, incident_number)
);
CREATE INDEX incidents_venue_idx ON incidents (venue_id, status, occurred_at DESC);

CREATE TABLE incident_events (
  id             bigserial PRIMARY KEY,
  venue_id       uuid NOT NULL REFERENCES venues(id),
  incident_id    uuid NOT NULL REFERENCES incidents(id),
  event_type     text NOT NULL,
  from_status    text,
  to_status      text,
  actor_user_id  uuid REFERENCES users(id),
  device_id      uuid REFERENCES devices(id),
  occurred_at    timestamptz NOT NULL,
  metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_id     text
);
CREATE INDEX incident_events_idx ON incident_events (incident_id, id);

CREATE TABLE incident_attachments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id      uuid NOT NULL REFERENCES venues(id),
  incident_id   uuid NOT NULL REFERENCES incidents(id),
  storage_key   text NOT NULL UNIQUE,
  mime_type     text NOT NULL,
  size_bytes    integer NOT NULL,
  width         integer NOT NULL,
  height        integer NOT NULL,
  sha256        text NOT NULL,
  uploaded_by   uuid REFERENCES users(id),
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DELETED'))
);

-- Operational alerts that stay visible until resolved (not fire-and-forget pushes).
CREATE TABLE notifications (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id         uuid NOT NULL REFERENCES venues(id),
  outbox_event_id  bigint UNIQUE,            -- idempotent creation per outbox event
  type             text NOT NULL,
  severity         text NOT NULL DEFAULT 'INFO' CHECK (severity IN ('INFO','WARNING','CRITICAL')),
  title            text NOT NULL,
  body             text,
  entity_type      text,
  entity_id        uuid,
  status           text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  acknowledged_by  uuid REFERENCES users(id),
  acknowledged_at  timestamptz,
  resolved_at      timestamptz
);
CREATE INDEX notifications_open_idx ON notifications (venue_id, status, created_at DESC);

-- Delivery attempts per channel. Only IN_APP is implemented; PUSH/SMS are TODO (see docs).
CREATE TABLE notification_deliveries (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id  uuid NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  channel          text NOT NULL,
  status           text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','FAILED')),
  attempts         integer NOT NULL DEFAULT 0,
  last_error       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  sent_at          timestamptz
);
