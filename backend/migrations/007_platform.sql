-- 007_platform: audit, outbox, idempotency, day close, immutability guards
CREATE TABLE audit_logs (
  id             bigserial PRIMARY KEY,
  venue_id       uuid REFERENCES venues(id),
  actor_user_id  uuid REFERENCES users(id),
  action         text NOT NULL,
  entity_type    text NOT NULL,
  entity_id      text,
  before_data    jsonb,
  after_data     jsonb,
  reason         text,
  device_id      uuid,
  request_id     text,
  ip             text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_venue_time_idx ON audit_logs (venue_id, created_at DESC);
CREATE INDEX audit_logs_entity_idx ON audit_logs (entity_type, entity_id);
CREATE INDEX audit_logs_actor_idx ON audit_logs (actor_user_id, created_at DESC);

CREATE TABLE outbox_events (
  id             bigserial PRIMARY KEY,
  venue_id       uuid NOT NULL REFERENCES venues(id),
  event_type     text NOT NULL,
  aggregate_type text NOT NULL,
  aggregate_id   uuid,
  payload        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  available_at   timestamptz NOT NULL DEFAULT now(),
  processed_at   timestamptz,
  attempt_count  integer NOT NULL DEFAULT 0,
  last_error     text
);
CREATE INDEX outbox_pending_idx ON outbox_events (available_at, id) WHERE processed_at IS NULL;

-- Idempotency record commits atomically with the business change it protects.
CREATE TABLE idempotency_keys (
  venue_id        uuid NOT NULL REFERENCES venues(id),
  user_id         uuid NOT NULL REFERENCES users(id),
  key             text NOT NULL,
  operation       text NOT NULL,
  request_hash    text NOT NULL,
  response_status integer,
  response_body   jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  PRIMARY KEY (venue_id, user_id, key)
);
CREATE INDEX idempotency_expiry_idx ON idempotency_keys (expires_at);

CREATE TABLE day_closes (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id             uuid NOT NULL REFERENCES venues(id),
  local_date           date NOT NULL,
  status               text NOT NULL DEFAULT 'CLOSED' CHECK (status IN ('CLOSED')),
  expected_cash_minor  bigint NOT NULL,
  counted_cash_minor   bigint NOT NULL,
  difference_minor     bigint NOT NULL,
  checks               jsonb NOT NULL,
  notes                text,
  closed_by            uuid NOT NULL REFERENCES users(id),
  closed_at            timestamptz NOT NULL,
  UNIQUE (venue_id, local_date)
);

-- Immutability: history tables reject UPDATE and DELETE at the database level.
CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only (% not permitted)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'restrict_violation';
END $$;

CREATE TRIGGER audit_logs_immutable BEFORE UPDATE OR DELETE ON audit_logs FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER session_events_immutable BEFORE UPDATE OR DELETE ON session_events FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER payment_events_immutable BEFORE UPDATE OR DELETE ON payment_events FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER payment_transactions_immutable BEFORE UPDATE OR DELETE ON payment_transactions FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER equipment_events_immutable BEFORE UPDATE OR DELETE ON equipment_events FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER incident_events_immutable BEFORE UPDATE OR DELETE ON incident_events FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER day_closes_immutable BEFORE UPDATE OR DELETE ON day_closes FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- Waiver text can never change once published; only is_current may flip.
CREATE FUNCTION waiver_versions_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'waiver_versions cannot be deleted' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.body IS DISTINCT FROM OLD.body OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.version IS DISTINCT FROM OLD.version OR NEW.waiver_id IS DISTINCT FROM OLD.waiver_id THEN
    RAISE EXCEPTION 'published waiver versions are immutable' USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER waiver_versions_immutable BEFORE UPDATE OR DELETE ON waiver_versions FOR EACH ROW EXECUTE FUNCTION waiver_versions_guard();
