-- 005_equipment: rental inventory, assignments, events, maintenance
CREATE TABLE equipment (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id         uuid NOT NULL REFERENCES venues(id),
  code             text NOT NULL,                 -- SKATE-034
  category         text NOT NULL DEFAULT 'SKATE',
  size             text,
  status           text NOT NULL DEFAULT 'AVAILABLE' CHECK (status IN (
    'AVAILABLE','RESERVED','ISSUED','IN_USE','RETURNED','DAMAGED','MAINTENANCE','OUT_OF_SERVICE')),
  condition        text NOT NULL DEFAULT 'GOOD' CHECK (condition IN ('NEW','GOOD','FAIR','POOR')),
  location         text,
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (venue_id, code)
);
CREATE INDEX equipment_status_idx ON equipment (venue_id, status);

CREATE TABLE equipment_assignments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  equipment_id    uuid NOT NULL REFERENCES equipment(id),
  session_id      uuid NOT NULL REFERENCES sessions(id),
  customer_id     uuid NOT NULL REFERENCES customers(id),
  assigned_by     uuid REFERENCES users(id),
  assigned_at     timestamptz NOT NULL,
  returned_at     timestamptz,
  returned_by     uuid REFERENCES users(id),
  return_condition text CHECK (return_condition IN ('GOOD','DAMAGED')),
  device_id       uuid REFERENCES devices(id)
);
-- Hard guarantee: one unit can be out with at most one customer at a time.
CREATE UNIQUE INDEX equipment_one_open_assignment ON equipment_assignments (equipment_id) WHERE returned_at IS NULL;
CREATE INDEX equipment_assignments_session_idx ON equipment_assignments (session_id);

CREATE TABLE equipment_events (
  id             bigserial PRIMARY KEY,
  venue_id       uuid NOT NULL REFERENCES venues(id),
  equipment_id   uuid NOT NULL REFERENCES equipment(id),
  event_type     text NOT NULL,
  from_status    text,
  to_status      text,
  session_id     uuid REFERENCES sessions(id),
  actor_user_id  uuid REFERENCES users(id),
  device_id      uuid REFERENCES devices(id),
  occurred_at    timestamptz NOT NULL,
  metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_id     text
);
CREATE INDEX equipment_events_equipment_idx ON equipment_events (equipment_id, id);

CREATE TABLE maintenance_records (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id       uuid NOT NULL REFERENCES venues(id),
  equipment_id   uuid NOT NULL REFERENCES equipment(id),
  issue          text NOT NULL,
  status         text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_PROGRESS','COMPLETED')),
  reported_by    uuid REFERENCES users(id),
  reported_at    timestamptz NOT NULL,
  started_at     timestamptz,
  completed_at   timestamptz,
  completed_by   uuid REFERENCES users(id),
  resolution     text,
  photo_key      text,
  photo_mime     text
);
CREATE INDEX maintenance_equipment_idx ON maintenance_records (equipment_id, reported_at DESC);
